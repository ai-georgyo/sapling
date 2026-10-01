# Smoke test for the EdenFS package that does not need FUSE or root (which
# the Nix sandbox does not provide): both CLIs (the Rust `edenfsctl` and the
# Python `edenfsctl.real`, which loads the thrift-python runtime), the
# daemon's flag parsing, and the bundled Sapling.
#
# Usage: smoke-test.sh <edenfs out>
set -euxo pipefail
out=$1

# Keep the state dir (and thus its socket path) short.
export HOME=$PWD/h USER=nixbld
mkdir -p "$HOME"
eden="$out/bin/eden --config-dir $PWD/s --etc-eden-dir $PWD/e --home-dir $HOME"
realctl="$out/bin/edenfsctl.real --config-dir $PWD/s --etc-eden-dir $PWD/e --home-dir $HOME"

[[ $($eden version) == Installed:\ 2* ]]
[[ $($realctl version) == Installed:\ 2* ]]
$eden --help >/dev/null
$eden list
[[ $($eden config) == *"[core]"* ]]
# Not running: both CLIs connect to the daemon's Thrift socket and say so.
if $eden status; then exit 1; fi
[[ $($realctl status 2>&1 || true) == *"EdenFS not running"* ]]

# (gflags' --help exits with status 1.)
"$out/bin/edenfs" --help >help.txt 2>/dev/null || true
grep -q 'Flags from' help.txt
test -x "$out/libexec/eden/edenfs_privhelper"

# The Sapling the CLIs run (as `hg`) for checkouts.
[[ $("$out/libexec/eden/bin/hg" version) == Sapling\ * ]]
