import importlib.util
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('distribution', ROOT / 'scripts/distribution.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.temp.name).resolve()
        self.env = patch.dict(os.environ, {'HOME': str(self.home)})
        self.env.start()
        self.source = self.home / 'build/Conductor.app'
        (self.source / 'Contents/MacOS').mkdir(parents=True)
        (self.source / 'Contents/MacOS/Conductor').write_text('fixture')
        (self.source / 'Contents/MacOS/Conductor').chmod(0o755)
        with (self.source / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'com.conductor.app', 'CFBundleExecutable': 'Conductor', 'CFBundlePackageType': 'APPL'}, f)
        self.dest = self.home / 'Applications/Conductor.app'
        self.data = self.home / 'Library/Application Support/Conductor'
        self.native_markers = []
        for relative in ['.claude/settings.json', '.codex/config.toml', '.config/opencode/opencode.json', '.compass/state']:
            marker = self.home / relative
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text('native-owned-fixture')
            self.native_markers.append(marker)
        self.data.mkdir(parents=True)
        (self.data / 'store.db').write_text('keep')
    def tearDown(self):
        for marker in self.native_markers:
            self.assertEqual(marker.read_text(), 'native-owned-fixture')
        self.env.stop()
        self.temp.cleanup()
    def install(self):
        d.main(['install', '--app', str(self.source)])
    def test_install_update_uninstall_preserves_data(self):
        self.install()
        self.install()
        self.assertTrue(self.dest.is_dir())
        d.main(['uninstall'])
        d.main(['uninstall'])
        self.assertEqual((self.data / 'store.db').read_text(), 'keep')
    def test_explicit_purge_is_scoped(self):
        other = self.data.parent / 'Other'
        other.mkdir()
        self.install()
        d.main(['uninstall', '--purge-data'])
        self.assertFalse(self.data.exists())
        self.assertTrue(other.exists())
    def test_invalid_flags_no_mutation(self):
        with self.assertRaises(SystemExit): d.main(['install', '--app', str(self.source), '--wat'])
        self.assertFalse(self.dest.parent.exists())
    def test_bad_identity_preserves_existing(self):
        self.install()
        (self.source / 'Contents/Info.plist').write_text('invalid')
        with self.assertRaises(ValueError): self.install()
        self.assertTrue(self.dest.exists())
    def test_symlink_destination_and_data_rejected(self):
        self.dest.parent.mkdir()
        self.dest.symlink_to(self.source)
        with self.assertRaises(ValueError): self.install()
        self.dest.unlink()
        self.data.rename(self.data.parent / 'saved')
        self.data.symlink_to(self.data.parent / 'saved')
        with self.assertRaises(ValueError): d.main(['uninstall', '--purge-data'])
        self.assertTrue((self.data.parent / 'saved/store.db').exists())
    def test_parent_and_source_symlinks_rejected(self):
        self.dest.parent.symlink_to(self.source.parent)
        with self.assertRaises(ValueError): self.install()
        self.dest.parent.unlink()
        (self.source / 'escape').symlink_to(self.data)
        with self.assertRaises(ValueError): self.install()
    def test_unsafe_destinations_rejected(self):
        for path in ['/Applications/Conductor.app', str(self.home / '../Conductor.app'), str(self.home / '.claude/Conductor.app'), str(self.home / 'Applications/Other.app')]:
            with self.assertRaises(ValueError): d.main(['install', '--app', str(self.source), '--destination', path])
        self.assertFalse(self.dest.parent.exists())
    def test_failed_activation_rolls_back(self):
        self.install()
        (self.dest / 'old').write_text('previous')
        original = os.rename
        def fail_new(source, target):
            if pathlib.Path(source).name == 'new': raise OSError('simulated activation failure')
            original(source, target)
        with patch.object(d.os, 'rename', side_effect=fail_new):
            with self.assertRaises(OSError): self.install()
        self.assertEqual((self.dest / 'old').read_text(), 'previous')
    def test_failed_rollback_retains_previous_bundle(self):
        self.install()
        (self.dest / 'old').write_text('previous')
        original = os.rename
        def fail_moves(source, target):
            if pathlib.Path(source).name in ('new', 'previous'):
                raise OSError('simulated filesystem failure')
            original(source, target)
        with patch.object(d.os, 'rename', side_effect=fail_moves):
            with self.assertRaises(OSError): self.install()
        backups = list(self.dest.parent.glob('.conductor-stage-*/previous/old'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'previous')
    def test_busy_lock_preserves_installation(self):
        self.install()
        lock = self.dest.parent / '.conductor-install-lock'
        lock.mkdir()
        with self.assertRaises(FileExistsError): self.install()
        self.assertTrue(self.dest.exists())
        self.assertTrue(lock.exists())
    def test_shell_wrappers(self):
        custom = self.home / 'Applications/Personal/Conductor.app'
        subprocess.run([str(ROOT / 'install.sh'), '--app', str(self.source), '--destination', str(custom)], check=True, capture_output=True)
        self.assertTrue(custom.exists())
        subprocess.run([str(ROOT / 'uninstall.sh'), '--destination', str(custom)], check=True, capture_output=True)
        self.assertFalse(custom.exists())
        result = subprocess.run([str(ROOT / 'install.sh'), '--bad-flag'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.data.exists())
    def test_unknown_existing_bundle_is_preserved(self):
        self.dest.mkdir(parents=True)
        (self.dest / 'valuable').write_text('keep')
        with self.assertRaises(ValueError): self.install()
        with self.assertRaises(ValueError): d.main(['uninstall'])
        self.assertTrue((self.dest / 'valuable').exists())

if __name__ == '__main__': unittest.main()
