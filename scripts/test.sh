#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 0 ]] || { echo 'Usage: scripts/test.sh' >&2; exit 2; }
[[ "$(xcodegen --version)" == "Version: 2.46.0" ]] || { echo 'XcodeGen 2.46.0 is required.' >&2; exit 1; }
cd "$ROOT"
python3 -m unittest discover -s scripts/tests
cd Conductor
xcodegen generate
mkdir -p Conductor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Conductor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
CONDUCTOR_TEST_MODE=1 xcodebuild -project Conductor.xcodeproj -scheme Conductor -destination 'platform=macOS' -derivedDataPath "$ROOT/build-tests" -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=- test
