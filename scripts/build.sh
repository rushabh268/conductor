#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 0 ]] || { echo 'Usage: scripts/build.sh' >&2; exit 2; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen before building.' >&2; exit 1; }
[[ "$(xcodegen --version)" == "Version: 2.46.0" ]] || { echo 'XcodeGen 2.46.0 is required.' >&2; exit 1; }
xcodebuild -version >/dev/null
cd "$ROOT/Conductor"
xcodegen generate
mkdir -p Conductor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Conductor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project Conductor.xcodeproj -scheme Conductor -configuration Release -derivedDataPath "$ROOT/build" -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=- build
