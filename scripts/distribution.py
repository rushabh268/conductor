#!/usr/bin/env python3
"""Install only a validated app bundle; never launch it or configure native tools."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import tempfile


def safe_path(value):
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Paths must be absolute without parent traversal')
    for part in [*reversed(path.parents), path]:
        if part.is_symlink():
            raise ValueError('Symlinks are not accepted: ' + str(part))
    return path


def validate_bundle(path):
    safe_path(path)
    if not path.is_dir():
        raise ValueError('Not an app directory: ' + str(path))
    for entry in path.rglob('*'):
        if entry.is_symlink():
            raise ValueError('Bundle symlinks are not supported')
    try:
        with (path / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
    except Exception as error:
        raise ValueError('Cannot read app identity') from error
    if info.get('CFBundleIdentifier') != 'com.conductor.app' or info.get('CFBundlePackageType') != 'APPL':
        raise ValueError('Expected com.conductor.app application bundle')
    executable = info.get('CFBundleExecutable')
    if executable != 'Conductor' or not os.access(path / 'Contents/MacOS/Conductor', os.X_OK):
        raise ValueError('Missing Conductor executable')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'uninstall'])
    parser.add_argument('--destination', help='Absolute path under ~/Applications ending in Conductor.app')
    parser.add_argument('--app', help='Prebuilt Conductor.app (install only)')
    parser.add_argument('--purge-data', action='store_true', help='Remove only ~/Library/Application Support/Conductor (uninstall only)')
    args = parser.parse_args(argv)
    if (args.action == 'install' and (not args.app or args.purge_data)) or (args.action == 'uninstall' and args.app):
        parser.error('Install requires --app; --purge-data is uninstall-only')
    home = safe_path(os.environ['HOME'])
    applications = home / 'Applications'
    destination = safe_path(args.destination or applications / 'Conductor.app')
    if destination.name != 'Conductor.app' or applications not in destination.parents:
        raise ValueError('Destination must be below ~/Applications and named Conductor.app')
    data = home / 'Library/Application Support/Conductor'
    if args.purge_data:
        safe_path(data)
        if data.exists() and not data.is_dir():
            raise ValueError('App data must be a directory')
        if data.exists():
            for entry in data.rglob('*'):
                if entry.is_symlink():
                    raise ValueError('Refusing to purge data containing symlinks')
    source = None
    if args.action == 'install':
        source = safe_path(args.app)
        validate_bundle(source)
        if source == destination or destination in source.parents or source in destination.parents:
            raise ValueError('Source and destination must be separate')
    if destination.exists():
        validate_bundle(destination)
    if args.action == 'uninstall' and not destination.exists() and not args.purge_data:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.parent / '.conductor-install-lock'
    # Exclusive directory creation prevents concurrent cooperating installers.
    lock.mkdir(mode=0o700)
    try:
        stage = Path(tempfile.mkdtemp(prefix='.conductor-stage-', dir=destination.parent))
        backup = stage / 'previous'
        completed = False
        try:
            if source:
                shutil.copytree(source, stage / 'new')
                validate_bundle(stage / 'new')
            if destination.exists():
                os.rename(destination, backup)
            try:
                if source:
                    os.rename(stage / 'new', destination)
                elif args.purge_data and data.exists():
                    shutil.rmtree(data)
            except BaseException:
                if backup.exists():
                    try:
                        os.rename(backup, destination)
                    except OSError as error:
                        raise OSError('Rollback failed; previous app retained at ' + str(backup)) from error
                raise
            completed = True
        finally:
            # Never erase the only old copy when the filesystem rejects rollback.
            if completed or not backup.exists():
                shutil.rmtree(stage)
    finally:
        lock.rmdir()
    print(('Installed ' if source else 'Uninstalled ') + str(destination))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
