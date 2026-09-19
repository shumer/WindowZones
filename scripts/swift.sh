#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" .build/cache .build/config .build/security
command_name="$1"
shift
swift "$command_name" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
