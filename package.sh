#!/bin/bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"
project="$PWD"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
release="$project/Release"
name="G3010 USB Scan $version Intel"
work=$(mktemp -d "${TMPDIR:-/tmp}/g3010-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
volume="$work/volume"
mkdir -p "$volume/Source" "$release"

# An explicit app path packages the tested copy. With no argument, build from source.
app="${1:-$work/build/G3010 USB Scan.app}"
if [[ $# == 0 ]]; then ./build.sh "$app"; fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "local.rejie.g3010usbscan" ]]
codesign --verify --deep --strict "$app"
for binary in "$app/Contents/MacOS/G3010Scan" "$app/Contents/Resources/scanimage"; do
    [[ "$(lipo -archs "$binary")" == "x86_64" ]]
done
(cd Driver/Sources && shasum -a 256 -c SHA256SUMS)
ditto --norsrc --noextattr --noacl "$app" "$volume/G3010 USB Scan.app"
for item in Scanner.swift PageEdges.swift PaperWhitening.swift Config Driver Info.plist build.sh package.sh Install.txt README.md LICENSE; do
    ditto --norsrc --noextattr --noacl "$item" "$volume/Source/$item"
done
cp Install.txt "$volume/Install.txt"
ln -s /Applications "$volume/Applications"
hdiutil create -quiet -srcfolder "$volume" -volname "G3010 USB Scan $version" -fs HFS+ -format UDZO "$work/$name.dmg"
hdiutil verify -quiet "$work/$name.dmg"
mv -f "$work/$name.dmg" "$release/$name.dmg"
(cd "$release" && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
echo "$release/$name.dmg"
