#!/usr/bin/env bash
# Regenerate nix/sapling/Cargo.lock (the eden/scm Cargo workspace) for the
# current checkout.
#
# Usage: nix/sapling/update-lockfile.sh [output, default: nix/sapling/Cargo.lock]
#
# Needs network access. Afterwards, update `cargoDeps.hash` in default.nix
# (build once with `hash = lib.fakeHash;` and copy the reported one).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=$(realpath -m "${1:-$here/Cargo.lock}")
# The rust-shed revision the rest of the Meta stack is at (../fb-stack.json).
rust_shed_rev=$(nix eval --raw --impure --expr \
  "(builtins.fromJSON (builtins.readFile $repo/nix/fb-stack.json)).rust-shed.rev")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Same subset of the repository the derivation builds from.
tar -C "$repo" --exclude=eden/scm/tests -cf - eden/scm eden/fs/config \
  eden/fs/service eden/fs/rust/edenfs-asserted-states-client \
  eden/mononoke/common/lfs_protocol configerator/structs/scm/hg \
  common/rust/shed thrift/lib/rust fb303/thrift watchman/rust |
  tar -C "$work" -xf -
ws=$work/eden/scm

# The same manifest edits as postPatch in default.nix: drop the unused
# abomonation git patch, add ours.
grep -q '^abomonation = { git = ' "$ws/Cargo.toml" ||
  { echo "abomonation patch not found; update default.nix too" >&2; exit 1; }
sed -i '/^\[patch\.crates-io\]$/{N;/\nabomonation = { git = /d;}' "$ws/Cargo.toml"
cat "$here/cargo-patches.toml" >>"$ws/Cargo.toml"

# Use the nixpkgs pinned in flake.lock, so the cargo writing the lock is the
# one that builds with it.
nix shell --inputs-from "$repo" nixpkgs#cargo nixpkgs#git -c bash -euo pipefail -c '
  cd "$1"
  export CARGO_HOME=$2/cargo-home CARGO_NET_GIT_FETCH_WITH_CLI=true
  cargo generate-lockfile
  # Pin the rust-shed crates that are not vendored in this repository to the
  # revision getdeps uses. Any of them selects the whole git source.
  cargo update -p sorted_vector_map --precise "$3"
  if grep -q "^\[\[patch.unused\]\]" Cargo.lock; then
    echo "warning: unused [patch] entries; drop them from cargo-patches.toml:" >&2
    grep -A1 "^\[\[patch.unused\]\]" Cargo.lock | grep "^name" >&2
  fi
' _ "$ws" "$work" "$rust_shed_rev"

cp "$ws/Cargo.lock" "$out"
echo "Wrote $out"
