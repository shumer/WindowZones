#!/bin/bash
set -euo pipefail
app_path="${1:?Usage: sign-app.sh path/to/WindowZones.app}"
identity="${CODE_SIGN_IDENTITY:--}"
sign_flags=(--force --sign "$identity")
if [[ "$identity" == - ]]; then
  sign_flags+=(--timestamp=none)
else
  sign_flags+=(--options runtime --timestamp)
fi
framework="$app_path/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework/Versions/B" ]] || { echo 'Sparkle.framework is missing.' >&2; exit 1; }
# Sign nested code before its enclosing bundle.
codesign "${sign_flags[@]}" "$framework/Versions/B/XPCServices/Installer.xpc"
codesign "${sign_flags[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign "${sign_flags[@]}" "$framework/Versions/B/Autoupdate"
codesign "${sign_flags[@]}" "$framework/Versions/B/Updater.app"
codesign "${sign_flags[@]}" "$framework"
codesign "${sign_flags[@]}" "$app_path"
codesign --verify --deep --strict "$app_path"
