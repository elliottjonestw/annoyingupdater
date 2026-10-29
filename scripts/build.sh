#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
architecture="${2:-native}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]] || [[ "$architecture" != "native" && "$architecture" != "universal" ]]; then
    print -u2 "Usage: scripts/build.sh [release|debug] [native|universal]"
    exit 1
fi
version="$(<VERSION)"
if ! [[ "$version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
    print -u2 'VERSION must be a stable version such as 1.0 or 1.0.1.'
    exit 1
fi
# macOS 14 includes Swift 5.9. Older compatibility shims are unnecessary,
# including when a dependency declares an older deployment target. Some modern
# arm64-only CLT installs no longer ship Intel copies of those legacy shims.
build_args=(-c "$configuration" --product AnnoyingUpdater
            -Xswiftc -runtime-compatibility-version -Xswiftc none)
if [[ "$architecture" == "universal" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
mkdir -p build
staging="$(mktemp -d "$PWD/build/bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app_path="$staging/Annoying Updater.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
cp "$binary_dir/AnnoyingUpdater" "$app_path/Contents/MacOS/AnnoyingUpdater"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app_path/Contents/Info.plist"
cp Resources/ThirdPartyNotices.txt "$app_path/Contents/Resources/ThirdPartyNotices.txt"
swift scripts/make-icon.swift "$app_path/Contents/Resources/AppIcon.icns"
framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
# ditto preserves Sparkle's versioned framework symlinks and helper permissions.
ditto "$framework" "$app_path/Contents/Frameworks/Sparkle.framework"
# Keep Sparkle's vendor-signed helpers intact. Only the outer app is ad hoc signed.
# No Developer ID / notarization is claimed by this build.
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
if [[ "$architecture" == "universal" ]]; then
    lipo "$app_path/Contents/MacOS/AnnoyingUpdater" -verify_arch arm64
    lipo "$app_path/Contents/MacOS/AnnoyingUpdater" -verify_arch x86_64
fi
# Replace the previous output only after the new bundle passes verification.
rm -rf "$PWD/build/Annoying Updater.app"
ditto "$app_path" "$PWD/build/Annoying Updater.app"
print "Built $version ($configuration, $architecture): $PWD/build/Annoying Updater.app"
