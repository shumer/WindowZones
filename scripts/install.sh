#!/bin/zsh
# Build with the existing Developer ID and replace only the installed WindowZones bundle.
set -euo pipefail
cd "${0:A:h:h}"

app_name="WindowZones"
bundle_id="com.shumer.WindowZones"
team_id="MW9955TT6R"
installed="/Applications/$app_name.app"
built="$PWD/build/$app_name.app"

# Resolve the team's current certificate, including after certificate renewal.
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
  CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v team="($team_id)" '/Developer ID Application/ && index($0, team) { print $2; exit }')"
fi
[[ -n "$CODE_SIGN_IDENTITY" && "$CODE_SIGN_IDENTITY" != - ]] \
  || { print -u2 "No Developer ID Application identity for team $team_id. Not building an ad-hoc copy."; exit 1; }
export CODE_SIGN_IDENTITY

[[ "${SKIP_TESTS:-0}" == 1 ]] || ./scripts/test.sh
./scripts/build.sh

# Verify the completed source before changing any installed files.
codesign --verify --deep --strict "$built"
built_team="$(codesign -dv "$built" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$built_team" == "$team_id" ]] \
  || { print -u2 "Built app is signed by team '$built_team', expected $team_id. Not installing."; exit 1; }
built_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$built/Contents/Info.plist")"
[[ "$built_id" == "$bundle_id" ]] \
  || { print -u2 "Unexpected built bundle ID '$built_id'. Not installing."; exit 1; }
[[ -d "$installed" && ! -L "$installed" ]] \
  || { print -u2 "$installed must exist as an application directory. The first install is done by hand."; exit 1; }
installed_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed/Contents/Info.plist")"
[[ "$installed_id" == "$bundle_id" ]] \
  || { print -u2 "Unexpected installed bundle ID '$installed_id'. Not installing."; exit 1; }

# Probe App Management access before stopping the app or replacing its contents.
probe="$installed/Contents/.install-probe"
if ! touch "$probe" 2>/dev/null; then
  print -u2 "Cannot write into $installed. Turn on System Settings > Privacy & Security > App Management for the app running this script, then run it again."
  exit 1
fi
rm -f "$probe"

# Preserve the previous bundle in the workspace for recovery after a copy failure.
backup="$PWD/.build/install-backup/WindowZones.app"
mkdir -p "${backup:h}"
if [[ -e "$backup" ]]; then rm -rf "$backup"; fi
ditto "$installed" "$backup"
codesign --verify --deep --strict "$backup"

# Quit only WindowZones and allow its cancellation handlers to finish.
osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || true
for _ in {1..50}; do
  pgrep -x "$app_name" >/dev/null || break
  sleep 0.1
done
pkill -x "$app_name" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x "$app_name" >/dev/null || break
  sleep 0.1
done
if pgrep -x "$app_name" >/dev/null; then
  print -u2 "WindowZones is still running. Not replacing its executable."
  exit 1
fi

# Keep the bundle path and replace contents with fresh inodes for code signature caches.
rm -rf "$installed/Contents"
if ! ditto "$built/Contents" "$installed/Contents" || ! codesign --verify --deep --strict "$installed"; then
  print -u2 "Install failed. Previous bundle is saved at $backup. Not launching the incomplete app."
  exit 1
fi
open "$installed" --args "$@"
print "Installed $installed, signed by team $team_id."
