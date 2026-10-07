#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
[[ "$(xcrun --show-sdk-version)" == "27.0" ]] || { print -u2 'Expected SDK 27.0.'; exit 1; }
probe_path="$PWD/.build/WindowZonesLifecycleProbe.app"
mkdir -p "$probe_path/Contents/MacOS"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 Tests/Fixtures/WindowLifecycleProbe.swift -o "$probe_path/Contents/MacOS/WindowZonesLifecycleProbe"
cp Tests/Fixtures/LifecycleProbeInfo.plist "$probe_path/Contents/Info.plist"
print "$probe_path"
