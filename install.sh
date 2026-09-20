#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ $# == 0 ]]; then
    "$ROOT/scripts/build.sh"
    exec python3 "$ROOT/scripts/distribution.py" install --app "$ROOT/build/Build/Products/Release/Conductor.app"
fi
exec python3 "$ROOT/scripts/distribution.py" install "$@"
