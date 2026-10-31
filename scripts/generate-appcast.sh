#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="$(<VERSION)"
image_path="$PWD/dist/upd8er-$version-universal.dmg"
[[ -f "$image_path" ]] || { print -u2 'Run scripts/package.sh first.'; exit 1; }
# One archive per generated feed. Old DMGs in dist must never leak into a new release.
feed_dir="$(mktemp -d "$PWD/build/appcast.XXXXXX")"
trap 'rm -rf "$feed_dir"' EXIT
ditto "$image_path" "$feed_dir/${image_path:t}"
args=(--download-url-prefix "https://github.com/elliottjonestw/annoyingupdater/releases/download/v$version/"
      --link "https://github.com/elliottjonestw/annoyingupdater/releases/tag/v$version"
      --maximum-deltas 0 -o "$feed_dir/appcast.xml")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # No secret appears in command arguments or logs.
    print -rn -- "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file - "${args[@]}" "$feed_dir"
else
    .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account com.annoyingupdater.release "${args[@]}" "$feed_dir"
fi
swift scripts/verify-update.swift "$feed_dir/appcast.xml" "$image_path" Resources/Info.plist "$version"
cp "$feed_dir/appcast.xml" dist/appcast.xml
(cd dist && shasum -a 256 "${image_path:t}" appcast.xml > SHA256SUMS.txt)
