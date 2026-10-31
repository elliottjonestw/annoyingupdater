#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="$(<VERSION)"
app_path="$PWD/build/upd8er.app"
if [[ ! -d "$app_path" ]]; then
    print -u2 'Build the app first: scripts/build.sh release universal'
    exit 1
fi
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ "$actual_version" != "$version" ]]; then
    print -u2 'The built app does not match VERSION. Rebuild before packaging.'
    exit 1
fi
lipo "$app_path/Contents/MacOS/upd8er" -verify_arch arm64
lipo "$app_path/Contents/MacOS/upd8er" -verify_arch x86_64
codesign --verify --deep --strict "$app_path"
if [[ ! -x .build/dmg-venv/bin/dmgbuild ]]; then
    python3 -m venv .build/dmg-venv
    .build/dmg-venv/bin/python -m pip install --disable-pip-version-check -r scripts/dmg-requirements.txt
fi
mkdir -p dist
swift scripts/make-dmg-background.swift build/dmg-background.png
image_path="$PWD/dist/upd8er-$version-universal.dmg"
.build/dmg-venv/bin/dmgbuild -s scripts/dmg-settings.py \
    -D "app=$app_path" -D "background=$PWD/build/dmg-background.png" \
    "upd8er $version" "$image_path"
hdiutil verify "$image_path"
# A rebuilt DMG needs new signatures and checksums, even at the same version.
rm -f dist/appcast.xml dist/SHA256SUMS.txt
print "Packaged: $image_path"
