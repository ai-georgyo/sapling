# Smoke test for the `sl` binary: a native Sapling repository (commit, diff,
# log, goto, status), a Git-backed clone of a plain git repository, the
# installation self-check, and (with ISL) `sl web` serving the Interactive
# Smartlog.
#
# Usage: smoke-test.sh [--isl]   (with sl, git, curl and jq on PATH)
set -euxo pipefail

export HOME=$PWD/home USER=nixbld
mkdir -p "$HOME"
sl config --user ui.username 'Nix Test <nix@example.com>'

sl init repo
cd repo
echo hello >a.txt
sl add a.txt
sl commit -m first
echo world >>a.txt
[[ $(sl diff) == *$'\n+world'* ]]
sl commit -m second
test "$(sl log -T '{desc} ')" = "second first "
sl goto -q '.^'
test "$(cat a.txt)" = hello
test -z "$(sl status)"

if [ "${1:-}" = --isl ]; then
  # The wrapper must find node without it being on PATH.
  PATH=/nonexistent "$(command -v sl)" web --no-open --port 0 --json >../web.json
  url=$(jq -r .url ../web.json)
  curl -fsS -o ../isl.html "$url"
  grep -q '<title>Interactive Smartlog' ../isl.html
  kill "$(jq -r .pid ../web.json)"
fi
cd ..

git init -q -b main gitrepo
echo one >gitrepo/f
git -C gitrepo add f
git -C gitrepo -c user.name=t -c user.email=t@example.com commit -qm "git commit"
sl clone --git "file://$PWD/gitrepo" slgit
test "$(sl -R slgit log -r . -T '{desc}')" = "git commit"
test "$(cat slgit/f)" = one

sl debuginstall
