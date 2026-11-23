#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-$PWD/build/G3010 USB Scan.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -target x86_64-apple-macos14.0 -parse-as-library -warnings-as-errors -O Scanner.swift PageEdges.swift PaperWhitening.swift -o "$app/Contents/MacOS/G3010Scan"
cp -R Config Driver/Licenses "$app/Contents/Resources/"
cp Driver/scanimage "$app/Contents/Resources/scanimage"
cp Info.plist "$app/Contents/"
codesign --force --sign - "$app/Contents/Resources/scanimage"
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
