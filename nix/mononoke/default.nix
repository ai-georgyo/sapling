# Mononoke, the source control server behind Sapling, built from the Cargo
# workspace in eden/mononoke.
#
# This follows what getdeps does for the `mononoke` manifest (see
# build/fbcode_builder/manifests/mononoke and getdeps/cargo.py): build the
# whole workspace in release mode with RUSTC_BOOTSTRAP=1, with the fbthrift /
# rust-shed git dependencies redirected to local sources.
{
  lib,
  rustPlatform,
  # ../fb-stack.nix; Mononoke only needs the Thrift compiler from it.
  fbStack,
  runCommand,
  python3,
  pkg-config,
  openssl,
  zstd,
  zlib,
  libgit2,
  libssh2,
  gitMinimal,
  curl,
}:

let
  src = import ../src.nix { inherit lib; } [
    "eden/mononoke"
    # Workspace members and path dependencies shared with the Sapling client.
    "eden/scm/lib"
    # In-repo copies of the fbthrift Rust runtime and Thrift annotations, and
    # of part of rust-shed; see ./cargo-patch.toml.
    "thrift"
    "common/rust"
    "fb303/thrift"
    # Thrift structs for configs Mononoke reads.
    "configerator/structs/scm"
  ];

in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "mononoke";
  version = "0-unstable-2026-10-01";

  inherit src;

  # Upstream does not commit Cargo.lock files. Ours was generated against the
  # workspace with ./cargo-patch.toml applied; the rust-shed crates that are
  # not vendored in this repo are pinned to the revision getdeps uses
  # (build/deps/github_hashes/facebookexperimental/rust-shed-rev.txt).
  # Regenerate it with ./update-lockfile.sh.
  #
  # Only the lock file is needed to vendor the dependencies, so fetch them
  # from a source containing just that; unrelated edits to the repository do
  # not invalidate the vendored crates.
  cargoDeps = rustPlatform.fetchCargoVendor {
    name = "mononoke-${finalAttrs.version}";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = ./Cargo.lock;
    };
    hash = "sha256-0vuvSnhFEHCho7pgC9KwYYy1DtkaQdp0n5BoxCreLX4=";
  };

  cargoRoot = "eden/mononoke";
  buildAndTestSubdir = "eden/mononoke";

  prePatch = ''
    cp ${./Cargo.lock} eden/mononoke/Cargo.lock
    cat ${./cargo-patch.toml} >> eden/mononoke/Cargo.toml
    python3 ${./strip-unused-patches.py} eden/mononoke/Cargo.toml eden/mononoke/Cargo.lock
  '';

  # Besides the git path below: rust-shed's just_knobs_struct (fetched from
  # git) generates its Thrift code with the rust-shed checkout as include
  # root, relative to its own location, which does not hold inside the vendor
  # directory. Compile its .thrift file from the matching path in this tree
  # instead, where thrift/annotation/*.thrift (which it includes) is available.
  postPatch = ''
    # gitimport and repo_import run git from a Meta-specific path by default
    # (overridable with --git-command-path); use git from nixpkgs instead. They
    # only need plumbing commands, so the minimal build (smaller closure) does.
    substituteInPlace eden/mononoke/git/import_tools/src/gitimport_objects.rs \
      --replace-fail '"/usr/bin/git.real"' '"${lib.getExe gitMinimal}"'

    jk=(''${cargoDepsCopy:?}/source-git-*/just_knobs_struct-*)
    jkThrift=common/rust/shed/justknobs_stub/cached_config_thrift_struct/just_knobs.thrift
    install -Dm644 "$jk/just_knobs.thrift" "$jkThrift"
    substituteInPlace "$jk/thrift_build.rs" \
      --replace-fail '.base_path("../../../../..")' ".base_path(\"$PWD\")" \
      --replace-fail '.run(["just_knobs.thrift"])' ".run([\"$PWD/$jkThrift\"])"

    # The cxx fork used via [patch.crates-io] is fetched from git, where
    # several crates' build.rs `include!` ../tools/cargo/build.rs, outside of
    # the vendored crate directory. Inline that (self-contained) file.
    cxxBuildRs=(''${cargoDepsCopy}/source-git-*/cxx-[0-9]*/tools/cargo/build.rs)
    for f in ''${cargoDepsCopy}/source-git-*/cxx*/build.rs; do
      if grep -q 'include!(".*tools/cargo/build.rs")' "$f"; then
        cp "$cxxBuildRs" "$f"
      fi
    done
  '';

  nativeBuildInputs = [
    python3
    pkg-config
    # For crates generating bindings at build time (libsqlite3-sys, ...).
    rustPlatform.bindgenHook
  ];

  # Other native dependencies (SQLite, curl, lz4, ...) are built from the
  # sources bundled in their -sys crates, as the crates' enabled features
  # request.
  buildInputs = [
    openssl
    zstd
    zlib
    libgit2
    libssh2
  ];

  env = {
    # Rust Thrift code generation (common/rust/shed/thrift_compiler) runs the
    # fbthrift compiler found here; see ../fb-stack.nix.
    THRIFT = fbStack.thrift1;
    # getdeps builds with this too: some dependencies (smallvec's
    # `specialization` feature, ...) use unstable features.
    RUSTC_BOOTSTRAP = "1";
    # Link against the libraries from nixpkgs instead of vendored copies.
    # (openssl-sys has its `vendored` feature enabled by a dependency.)
    OPENSSL_NO_VENDOR = "1";
    LIBGIT2_NO_VENDOR = "1";
    LIBSSH2_SYS_USE_PKG_CONFIG = "1";
    ZSTD_SYS_USE_PKG_CONFIG = "1";
  };

  cargoBuildFlags = [ "--workspace" ];

  # Benchmarks and example programs go to a separate output, so they are not
  # installed (and their generic names do not end up in profiles) by default.
  outputs = [
    "out"
    "benchmarks"
  ];

  postInstall = ''
    mkdir -p $benchmarks/bin
    mv $out/bin/benchmark* $out/bin/example $out/bin/tokio_v2 $benchmarks/bin/
  '';

  # The binaries are large (40 of up to ~180 MB); dropping their symbol
  # tables saves about a third of that, at the cost of function names in
  # panic backtraces.
  stripAllList = [ "bin" ];

  # The test suites need a large amount of infrastructure (and the
  # integration tests a Sapling client); not run here.
  doCheck = false;

  passthru = {
    inherit fbStack;

    # Imports a git repository into a fileblob/SQLite-backed repo, reads the
    # bookmark back with `admin`, and starts the server and queries its
    # health check. Uses the fixtures of the integration tests.
    tests.smoke =
      runCommand "mononoke-smoke-test"
        {
          nativeBuildInputs = [
            gitMinimal
            curl
          ];
        }
        ''
          bash ${./smoke-test.sh} ${finalAttrs.finalPackage}/bin \
            ${src}/eden/mononoke/common/mononoke_macros/test_just_knobs/just_knobs.json \
            ${src}/eden/mononoke/tests/integration/certs
          touch $out
        '';
  };

  meta = {
    description = "Scalable source control server for Sapling";
    homepage = "https://sapling-scm.com";
    downloadPage = "https://github.com/facebook/sapling/tree/main/eden/mononoke";
    license = lib.licenses.gpl2Only;
    mainProgram = "mononoke";
    platforms = lib.platforms.linux;
  };
})
