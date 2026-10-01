# Sapling CLI (`sl`) built from eden/scm of this checkout.
#
# This mirrors what `eden/scm/build.py` does in getdeps mode (the build used
# by upstream's open source EdenFS/Mononoke CI): a single
# `cargo build -p hgmain --features sl_oss,eden` producing a binary that
# embeds the pure-Python part of Sapling and links against libpython, plus the
# ISL web UI tarball used by `sl web`. (The `--oss` release builds leave out
# `eden`; see withEdenfs.)
{
  lib,
  stdenv,
  rustPlatform,
  python312,
  pkg-config,
  makeWrapper,
  openssl,
  curl,
  zlib,
  libgit2,
  libssh2,
  gitMinimal,
  glibcLocales,
  nodejs,
  nodejs-slim,
  yarn,
  yarnConfigHook,
  fetchYarnDeps,
  applyPatches,
  runCommand,
  jq,
  versionCheckHook,

  # ../fb-stack.nix; only its Rust Thrift compiler is used (withEdenfs).
  fbStack,

  # Build and ship the Interactive Smartlog web UI (`sl web` / `sl isl`).
  withIsl ? true,
  # Support working in EdenFS checkouts (Cargo feature `eden`, which adds
  # Rust Thrift clients for the EdenFS daemon). Without it, every command in
  # an EdenFS checkout fails with "cannot use EdenFS in a non-EdenFS build".
  # It costs a build-time Thrift compiler, but no runtime dependency.
  withEdenfs ? true,
}:

let
  # Upstream builds, tests and releases against Python 3.12 (pick_python.py
  # prefers it, the manylinux release uses cp312), and the bindings use the
  # rust-cpython 0.7 crate, which predates Python 3.13; pin it here rather than
  # following the nixpkgs default python3.
  python = python312;

  # Upstream versions look like "0.2.<date>-<time>+<hash>" (see ci/tag-name.sh);
  # use the base version from SAPLING_VERSION plus the checkout date.
  version = "${lib.fileContents ../../SAPLING_VERSION}-unstable-2026-09-30";

  fs = lib.fileset;
  root = ../..;

  # Everything the Cargo workspace rooted at eden/scm needs: the workspace
  # itself, path dependencies outside of it, and the in-repo copies of the
  # Meta git dependencies that ./cargo-patches.toml points at. The (large,
  # frequently changing) integration tests are left out so that editing them
  # does not rebuild sapling.
  src = fs.toSource {
    inherit root;
    fileset = fs.difference (fs.unions (
      map (p: root + "/${p}") (
        [
          "eden/scm"
          "eden/fs/config"
          "eden/fs/service"
          "eden/fs/rust/edenfs-asserted-states-client"
          "eden/mononoke/common/lfs_protocol"
          "configerator/structs/scm/hg"
          "common/rust/shed"
          "thrift/lib/rust"
          "fb303/thrift"
          "watchman/rust"
        ]
        # Included by the EdenFS service definitions (eden/fs/service).
        ++ lib.optional withEdenfs "thrift/annotation"
      )
    )) (root + "/eden/scm/tests");
  };

  # Some yarn.lock entries resolve to registry.facebook.net, which is not
  # publicly accessible; the same tarballs (checked by the integrity hashes)
  # are on the public npm registry.
  addonsSrc = applyPatches {
    name = "sapling-addons-src";
    src = fs.toSource {
      root = ../../addons;
      fileset = ../../addons;
    };
    postPatch = ''
      substituteInPlace yarn.lock \
        --replace-fail "https://registry.facebook.net/" "https://registry.yarnpkg.com/"
    '';
  };

  # Interactive Smartlog, packaged the way `addons/build-tar.py` does it.
  isl = stdenv.mkDerivation (finalAttrs: {
    pname = "sapling-isl";
    inherit version;
    src = addonsSrc;

    yarnOfflineCache = fetchYarnDeps {
      yarnLock = "${finalAttrs.src}/yarn.lock";
      hash = "sha256-ih/tg299Ob6z1CsWzhKdVCiPDv68czb4nPAHIJs4THs=";
    };

    nativeBuildInputs = [
      nodejs
      yarn
      yarnConfigHook
      python
    ];

    postPatch = ''
      # yarnConfigHook already installed node_modules from the offline cache.
      # Also give the tarball entries fixed mtimes and owners, so that it is
      # reproducible (the pax headers isl.py reads are left alone).
      substituteInPlace build-tar.py \
        --replace-fail 'run(yarn + ["--cwd", src_join(), "install", "--prefer-offline"])' 'pass' \
        --replace-fail 'tar.add(src_join(path), path)' 'tar.add(src_join(path), path, filter=_reproducible)' \
        --replace-fail 'def main():' $'def _reproducible(info):\n    info.mtime = int(os.environ["SOURCE_DATE_EPOCH"])\n    info.uid = info.gid = 0\n    info.uname = info.gname = ""\n    return info\n\n\ndef main():'
    '';

    buildPhase = ''
      runHook preBuild
      patchShebangs --build */node_modules
      python3 build-tar.py --output isl-dist.tar.xz
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 isl-dist.tar.xz $out/isl-dist.tar.xz
      runHook postInstall
    '';

    meta = {
      description = "Interactive Smartlog web UI for Sapling";
      homepage = "https://sapling-scm.com/docs/addons/isl";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  });
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "sapling";
  inherit version src;

  sourceRoot = "${src.name}/eden/scm";

  # Upstream does not commit a Cargo.lock. ./Cargo.lock was generated with
  # `cargo generate-lockfile` in eden/scm after applying the Cargo.toml edits
  # from postPatch below. Only the lock file is needed to vendor the crates,
  # so source edits never invalidate the vendored dependencies.
  #
  # Regenerate it with ./update-lockfile.sh. (EdenFS links some of the same
  # crates, but from its own eden/fs workspace and ../edenfs/Cargo.lock.)
  cargoDeps = rustPlatform.fetchCargoVendor {
    name = "sapling-${version}";
    src = fs.toSource {
      root = ./.;
      fileset = ./Cargo.lock;
    };
    hash = "sha256-AZX27PA2qLgsSL0vO99zIY4ec4k7cZDYA/oiLz6sGko=";
  };

  postPatch = ''
    # The workspace-level `[patch.crates-io] abomonation = { git = ... }` is
    # not used by any crate in this workspace, but offline cargo still tries
    # to fetch it; drop it.
    substituteInPlace Cargo.toml --replace-fail \
      $'[patch.crates-io]\nabomonation = { git = "https://github.com/markbt/abomonation", rev = "0f43346d2afa2aedc64d61f3f4273e8d1e454642" }\n' ""
    cat ${./cargo-patches.toml} >> Cargo.toml
    cp ${./Cargo.lock} Cargo.lock
  ''
  + lib.optionalString withIsl ''
    # Make `sl web` work without nodejs on PATH. The ISL server only needs
    # the node runtime, not npm.
    substituteInPlace lib/config/loader/src/builtin_static/core.rs \
      --replace-fail '"#);' $'[web]\nnode-path=${lib.getExe nodejs-slim}\n"#);'
  '';

  cargoBuildFlags = [
    "--package"
    "hgmain"
  ];
  buildFeatures = [ "sl_oss" ] ++ lib.optional withEdenfs "eden";

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    python
    # curl-sys only uses the system libcurl if `curl-config` reports HTTP/2.
    (lib.getDev curl)
  ];

  buildInputs = [
    python
    openssl
    curl
    zlib
    libgit2
    libssh2
  ];

  env = {
    # Build scripts (python-modules codegen, python-sysconfig, cpython) pick
    # the interpreter from these.
    PYTHON_SYS_EXECUTABLE = python.interpreter;
    PYO3_PYTHON = python.interpreter;
    SAPLING_VERSION = version;
    # Use the system libraries instead of the bundled copies.
    OPENSSL_NO_VENDOR = "1";
    LIBGIT2_NO_VENDOR = "1";
    LIBSSH2_SYS_USE_PKG_CONFIG = "1";
  }
  // lib.optionalAttrs withEdenfs {
    # Rust Thrift code generation for the EdenFS clients; see
    # ../thrift-rust-compiler.nix.
    THRIFT = lib.getExe fbStack.thrift-rust-compiler;
  };

  preBuild = ''
    # Same as version_hash() in build.py (an unsigned 64-bit integer, which
    # does not fit Nix's signed integers).
    export SAPLING_VERSION_HASH=$(${python.interpreter} -c '
    import hashlib, struct, sys
    print(struct.unpack(">Q", hashlib.sha1(sys.argv[1].encode()).digest()[:8])[0])
    ' "$SAPLING_VERSION")
    echo "SAPLING_VERSION=$SAPLING_VERSION SAPLING_VERSION_HASH=$SAPLING_VERSION_HASH"
  '';

  # The Rust and .t test suites are very large and need a full dev setup.
  doCheck = false;

  postInstall = ''
    mv $out/bin/hgmain $out/bin/sl
  ''
  + lib.optionalString withIsl ''
    # `sl web` looks for ../lib/isl-dist.tar.xz relative to the executable.
    install -Dm644 ${isl}/isl-dist.tar.xz $out/lib/isl-dist.tar.xz
  '';

  postFixup = ''
    wrapProgram $out/bin/sl \
      ${lib.optionalString stdenv.hostPlatform.isLinux "--set-default LOCALE_ARCHIVE ${glibcLocales}/lib/locale/locale-archive"} \
      --suffix PATH : ${lib.makeBinPath [ gitMinimal ]}
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "version";
  doInstallCheck = true;

  passthru = {
    inherit isl python;

    tests.smoke =
      runCommand "sapling-smoke-test"
        {
          nativeBuildInputs = [
            finalAttrs.finalPackage
            gitMinimal
            curl
            jq
          ];
        }
        ''
          bash ${./smoke-test.sh} ${lib.optionalString withIsl "--isl"}
          touch $out
        '';
  };

  meta = {
    description = "Scalable, user-friendly source control system";
    homepage = "https://sapling-scm.com";
    changelog = "https://github.com/facebook/sapling/releases";
    license = lib.licenses.gpl2Only;
    mainProgram = "sl";
    platforms = lib.platforms.linux;
  };
})
