#!/bin/bash
# Compatibility entry point: packaging now produces a portable ZIP archive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/scripts/package.sh" "$@"
