#!/usr/bin/env bash
# Regenerates nix/fb-stack.json from the revisions of Meta's libraries that
# this checkout records for its own (getdeps) builds, in
# build/deps/github_hashes/<owner>/<repo>-rev.txt, and prefetches their hashes.
#
# Usage: nix/update-fb-stack.sh
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
hashes=$repo/build/deps/github_hashes
out=$repo/nix/fb-stack.json

entries=()
for f in "$hashes"/*/*-rev.txt; do
  owner=$(basename "$(dirname "$f")")
  name=$(basename "$f" -rev.txt)
  rev=$(sed -n 's/^Subproject commit \([0-9a-f]\{40\}\)$/\1/p' "$f")
  [[ -n $rev ]] || {
    echo "cannot parse $f" >&2
    exit 1
  }
  echo "prefetching $owner/$name at $rev" >&2
  prefetch=$(nix flake prefetch --json "github:$owner/$name/$rev")
  entries+=("$(jq -n \
    --arg name "$name" --arg owner "$owner" --arg rev "$rev" \
    --argjson prefetch "$prefetch" \
    '{($name): {
        owner: $owner,
        repo: $name,
        rev: $rev,
        hash: $prefetch.hash,
        date: ($prefetch.locked.lastModified | strftime("%Y-%m-%d"))
      }}')")
done

printf '%s\n' "${entries[@]}" | jq -s 'add' >"$out"
echo "wrote $out" >&2
