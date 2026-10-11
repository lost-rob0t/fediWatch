#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
nix build --no-update-lock-file --no-link "$source_root#default" "$source_root#raw"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
unset LD_LIBRARY_PATH FEDIWATCH_RAW_CONFIG
for app in default fediWatch; do
  nix run --no-update-lock-file "$source_root#$app" -- --help >"$app.txt"
  grep -q apiAddress "$app.txt"
done
# The existing raw-only CLI deliberately returns usage status 2 for --help.
status=0
nix run --no-update-lock-file "$source_root#raw" -- --help >raw.txt 2>&1 || status=$?
test "$status" -eq 2
grep -q 'usage: fediWatchRaw --raw-config CONFIG.json' raw.txt
echo 'installed default, fediWatch and raw flake entrypoints PASS'
