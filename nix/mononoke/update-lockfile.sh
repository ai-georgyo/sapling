#!/usr/bin/env bash
# Regenerate nix/mononoke/Cargo.lock for the current checkout.
#
# Usage: nix/mononoke/update-lockfile.sh [output, default: nix/mononoke/Cargo.lock]
#
# Needs network access. Afterwards, update `cargoDeps.hash` in default.nix
# (build once with a fake hash and copy the reported one).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=$(realpath -m "${1:-$here/Cargo.lock}")
rust_shed_rev=$(grep -oE '[0-9a-f]{40}' \
  "$repo/build/deps/github_hashes/facebookexperimental/rust-shed-rev.txt")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Same subset of the repository the derivation builds from.
tar -C "$repo" -cf - eden/mononoke eden/scm/lib thrift common/rust fb303/thrift \
  configerator/structs/scm | tar -C "$work" -xf -
ws=$work/eden/mononoke
cat "$here/cargo-patch.toml" >>"$ws/Cargo.toml"

# Use the nixpkgs pinned in flake.lock, so the cargo writing the lock is the
# one that builds with it.
nix shell --inputs-from "$repo" nixpkgs#cargo nixpkgs#git nixpkgs#python3 -c bash -euo pipefail -c '
  cd "$1"
  export CARGO_HOME=$2/cargo-home CARGO_NET_GIT_FETCH_WITH_CLI=true
  cargo generate-lockfile
  # Pin the rust-shed crates that are not vendored in this repository to the
  # revision getdeps uses. Any of them selects the whole git source.
  cargo update -p abomonable_string --precise "$3"
  # Drop the manifest patches the lock does not use, then let cargo rewrite
  # the lock without its [[patch.unused]] entries.
  python3 "$4/strip-unused-patches.py" Cargo.toml Cargo.lock
  cargo metadata --format-version 1 >/dev/null
' _ "$ws" "$work" "$rust_shed_rev" "$here"

cp "$ws/Cargo.lock" "$out"
echo "Wrote $out"
