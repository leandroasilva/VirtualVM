#!/bin/zsh
# Runs the unit tests: those of the VirtualVMKit package, then the app's own.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/VirtualVMKit "$@"
swift test "$@"
