#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BUILD_ROOT="${AUDITOR_BUILD_ROOT:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_ROOT/module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
swift test --scratch-path "$BUILD_ROOT/spm" --cache-path "$BUILD_ROOT/cache" "$@"
