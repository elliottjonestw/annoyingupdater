#!/bin/zsh
# Run once after creating the GitHub repository. Requires GitHub CLI authentication.
set -euo pipefail
cd "${0:A:h:h}"
command -v gh >/dev/null || { print -u2 'Install GitHub CLI and run gh auth login first.'; exit 1; }
key_tool="$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
[[ -x "$key_tool" ]] || { print -u2 'Run swift package resolve first.'; exit 1; }
# Require the original Keychain key. Never silently generate a replacement.
public_key="$("$key_tool" --account com.annoyingupdater.release -p)"
expected="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
[[ "$public_key" == "$expected" ]] || { print -u2 'The original update-signing key is not in this Mac’s Keychain.'; exit 1; }
umask 077
key_dir="$(mktemp -d)"
trap 'rm -rf "$key_dir"' EXIT
"$key_tool" --account com.annoyingupdater.release -x "$key_dir/private-key" >/dev/null
gh secret set SPARKLE_PRIVATE_KEY --repo elliottjonestw/annoyingupdater < "$key_dir/private-key"
print 'Configured SPARKLE_PRIVATE_KEY for elliottjonestw/annoyingupdater.'
