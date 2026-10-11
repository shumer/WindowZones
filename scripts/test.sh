#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-localizations.py
compiler_dir="$(dirname "$(xcrun --find swift)")"
plugin_path="$compiler_dir/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
./scripts/swift.sh test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$plugin_path"
