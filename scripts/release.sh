#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER}"
: "${BUNDLE_ID:?Set the permanent BUNDLE_ID}"
: "${CODE_SIGN_IDENTITY:?Set Developer ID Application identity}"
: "${SU_FEED_URL:?Set permanent HTTPS appcast URL}"
: "${SU_PUBLIC_ED_KEY:?Set Sparkle public key}"
: "${DOWNLOAD_BASE_URL:?Set HTTPS download directory for this release}"
: "${NOTARY_PROFILE:?Set notarytool Keychain profile}"
: "${SPARKLE_PRIVATE_KEY:?Set Sparkle private key}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || exit 1
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$CODE_SIGN_IDENTITY" != - ]] || { echo 'Developer ID Application identity required.' >&2; exit 1; }
[[ "$BUNDLE_ID" != local.* ]] || { echo 'Prototype bundle ID cannot be released.' >&2; exit 1; }
[[ "$SU_FEED_URL" == https://* && "$DOWNLOAD_BASE_URL" == https://* ]] || exit 1
xcrun swift -module-cache-path .build/ModuleCache scripts/check-update-key.swift
credentials=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${WINDOWZONES_NOTARY_KEYCHAIN:-}" ]]; then credentials+=(--keychain "$WINDOWZONES_NOTARY_KEYCHAIN"); fi
./scripts/build.sh
app_path="$PWD/build/WindowZones.app"
[[ "$(lipo -archs "$app_path/Contents/MacOS/WindowZones")" == arm64 ]] || { echo 'Release 0.1 requires an arm64 build.' >&2; exit 1; }
codesign -d --verbose=4 "$app_path" 2>&1 | grep -q 'Authority=Developer ID Application:'
out="$PWD/build/release/$VERSION-$BUILD_NUMBER"
[[ ! -e "$out" ]] || { echo 'Release output already exists. Use a new build number.' >&2; exit 1; }
mkdir -p "$out"
notary_zip="$out/notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_zip"
xcrun notarytool submit "$notary_zip" "${credentials[@]}" --wait --timeout 30m --output-format json > "$out/notarization.json"
python3 - "$out/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted. Inspect notarization.json.')
PY
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
archive="$out/WindowZones-$VERSION-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
rm "$notary_zip"
sign_update="${SPARKLE_BIN_DIR:-.build/artifacts/sparkle/Sparkle/bin}/sign_update"
[[ -x "$sign_update" ]] || { echo 'Sparkle sign_update tool is missing.' >&2; exit 1; }
# Pass the signing key through standard input, never as a command argument.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$archive" > "$out/signature.txt"
python3 scripts/release-appcast.py "$app_path" "$archive" "$out/signature.txt" "$out/appcast.xml"
(cd "$out" && shasum -a 256 "$(basename "$archive")" > SHA256SUMS)
python3 - "$out/build-info.json" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"version": os.environ["VERSION"], "build": int(os.environ["BUILD_NUMBER"]), "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()}, indent=2) + "\n")
PY
printf 'Verified release artifacts: %s\n' "$out"
