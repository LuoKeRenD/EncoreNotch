#!/bin/bash
# Packages a built LyricsIsland.app as a DMG, alongside the matching source
# archive that GPL-3.0 and AGPL-3.0 require to accompany distributed binaries.
#
# Usage: scripts/package.sh path/to/LyricsIsland.app [output-directory]
# Set CODESIGN_IDENTITY to sign with something other than "Apple Development".
set -euo pipefail

app="${1:?Usage: scripts/package.sh path/to/LyricsIsland.app [output-directory]}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
output="${2:-$repo/dist}"
identity="${CODESIGN_IDENTITY:-Apple Development}"

[ -d "$app" ] || { echo "No app at $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$output/LyricsIsland-$version.dmg"
source_archive="$output/LyricsIsland-$version-source.zip"

mkdir -p "$output"
rm -f "$dmg" "$source_archive"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

ditto "$app" "$stage/LyricsIsland.app"
ln -s /Applications "$stage/Applications"
cp "$repo/LICENSE" "$stage/LICENSE.txt"
cp "$repo/THIRD_PARTY_LICENSES" "$stage/THIRD_PARTY_LICENSES.txt"

hdiutil create -quiet -volname "LyricsIsland $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
codesign --force --sign "$identity" --timestamp=none "$dmg"
hdiutil verify -quiet "$dmg"

git -C "$repo" archive --format=zip --prefix="LyricsIsland-$version/" -o "$source_archive" HEAD

echo "$dmg"
echo "$source_archive"
