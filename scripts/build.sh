#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
expected_sdk="${EXPECTED_SDK:-27.0}"
actual_sdk="$(xcrun --show-sdk-version)"
if [[ "$actual_sdk" != "$expected_sdk" ]]; then
  print -u2 "Expected macOS SDK $expected_sdk, found $actual_sdk. Review the SDK pin before building."
  exit 1
fi
./scripts/swift.sh build -c release
bin_path="$(./scripts/swift.sh build -c release --show-bin-path)"
app_path="$PWD/build/WindowZones.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
cp "$bin_path/WindowZones" "$app_path/Contents/MacOS/WindowZones"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
framework_path="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework_path" ]] || { print -u2 'Sparkle artifact missing.'; exit 1; }
ditto "$framework_path" "$app_path/Contents/Frameworks/Sparkle.framework"
export WZ_APP_PLIST="$app_path/Contents/Info.plist"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
p = Path(os.environ['WZ_APP_PLIST'])
data = plistlib.loads(p.read_bytes())
for env, key in [('VERSION', 'CFBundleShortVersionString'), ('BUILD_NUMBER', 'CFBundleVersion'), ('BUNDLE_ID', 'CFBundleIdentifier'), ('SU_FEED_URL', 'SUFeedURL'), ('SU_PUBLIC_ED_KEY', 'SUPublicEDKey')]:
    if os.environ.get(env): data[key] = os.environ[env]
p.write_bytes(plistlib.dumps(data))
PY
./scripts/sign-app.sh "$app_path"
print "$app_path"
