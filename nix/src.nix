# Source filtering helper: builds a store path containing only the given
# repository-relative paths, so unrelated edits do not trigger rebuilds.
{ lib }:
paths:
lib.fileset.toSource {
  root = ../.;
  fileset = lib.fileset.unions (map (p: ../. + "/${p}") paths);
}
