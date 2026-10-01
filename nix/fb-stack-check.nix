# Checks that every Meta component is at the same revision everywhere:
# fb-stack.json against the revisions this checkout records for getdeps
# (build/deps/github_hashes), and the rust-shed revision locked in each
# package's Cargo.lock against fb-stack.json.
{ lib, runCommand }:
let
  revs = lib.importJSON ./fb-stack.json;

  recorded = lib.mapAttrs (
    name: info:
    let
      file = ../build/deps/github_hashes + "/${info.owner}/${info.repo}-rev.txt";
    in
    lib.removePrefix "Subproject commit " (lib.trim (builtins.readFile file))
  ) revs;

  staleRevs = lib.filter (name: revs.${name}.rev != recorded.${name}) (lib.attrNames revs);

  lockedRustShedRevs =
    lockFile:
    lib.unique (
      map (p: lib.last (lib.splitString "#" p.source)) (
        lib.filter (
          p: lib.hasPrefix "git+https://github.com/facebookexperimental/rust-shed" (p.source or "")
        ) (lib.importTOML lockFile).package
      )
    );

  lockFiles = {
    sapling = ./sapling/Cargo.lock;
    mononoke = ./mononoke/Cargo.lock;
    edenfs = ./edenfs/Cargo.lock;
  };

  staleLocks = lib.filterAttrs (_: locked: locked != [ revs.rust-shed.rev ]) (
    lib.mapAttrs (_: lockedRustShedRevs) lockFiles
  );

  errors =
    map (
      name:
      "fb-stack.json has ${name} at ${revs.${name}.rev}, but this checkout records ${recorded.${name}}"
      + " (run nix/update-fb-stack.sh)"
    ) staleRevs
    ++ lib.mapAttrsToList (
      pkg: locked:
      "nix/${pkg}/Cargo.lock has rust-shed at ${lib.concatStringsSep ", " locked},"
      + " but fb-stack.json has ${revs.rust-shed.rev} (run nix/${pkg}/update-lockfile.sh)"
    ) staleLocks;
in
runCommand "fb-stack-consistency" { } (
  if errors == [ ] then
    "touch $out"
  else
    ''
      cat >&2 <<'EOF'
      ${lib.concatStringsSep "\n" errors}
      EOF
      exit 1
    ''
)
