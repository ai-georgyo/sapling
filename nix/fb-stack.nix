# The Meta C++ libraries the packages in this repository build against.
#
# nixpkgs currently ships the 2026.07.27.00 release of this stack, but EdenFS
# at this revision of the repository needs newer APIs (most visibly from
# edencommon: `PathComponent::storage_type`/`intoStorage()`,
# `RelativePath::intoString()`, `ProcessAttribution`, ...). Since these
# libraries are released in lock-step and must be built against each other,
# bump all of them together to the latest release before this checkout,
# reusing the nixpkgs derivations and only swapping versions/sources (plus
# edencommon, which needs a couple of days' newer revision, see below).
#
# The returned packages are only used by the packages in this repository; the
# rest of nixpkgs keeps using its own versions. Only EdenFS links against the
# C++ libraries; all three packages use `thrift-rust-compiler` (bottom).
{ pkgs }:
let
  inherit (pkgs) lib fetchFromGitHub;

  release = "2026.09.28.00";

  bump =
    pkg:
    {
      owner,
      repo,
      hash,
      rev ? null,
      version ? release,
      extraAttrs ? old: { },
    }:
    pkg.overrideAttrs (
      old:
      {
        inherit version;
        src = fetchFromGitHub (
          {
            inherit owner repo hash;
          }
          // (if rev != null then { inherit rev; } else { tag = "v${release}"; })
        );
        # The upstream test suites of these libraries are huge (folly alone
        # takes longer to test than to build) and already run in nixpkgs.
        doCheck = false;
      }
      // extraAttrs old
    );

  # The CMake package configs of the new folly and fbthrift releases look up
  # a few more of their dependencies (folly: OpenSSL; fbthrift: zstd) that
  # the nixpkgs derivations do not propagate, so consumers need them as inputs.
  cmakeConfigDeps = [
    pkgs.openssl
    pkgs.zstd
  ];

  folly = bump pkgs.folly {
    owner = "facebook";
    repo = "folly";
    hash = "sha256-l+Jw8yb4mpOciTy5dizJ0IfU+5dcMmUJ6FNWoemac6M=";
    # folly's CMake files were reformatted/restructured since 2026.07.27, so
    # the nixpkgs patches no longer apply. The two aarch64 build fixes are
    # still needed and are re-applied below; the third one only relocated
    # test certificates for `folly_test_util`, which nothing here uses.
    extraAttrs = old: {
      patches = [ ];
      postPatch = old.postPatch + ''
        # https://github.com/facebook/folly/pull/2561
        substituteInPlace folly/CMakeLists.txt \
          --replace-fail \
            'folly_add_library(NAME memcpy-impl SRCS FollyMemcpy.cpp)' \
            'folly_add_library(NAME memcpy-impl SRCS FollyMemcpy.cpp $<$<BOOL:''${IS_AARCH64_ARCH}>:memcpy_select_aarch64.cpp> DEPS $<$<BOOL:''${IS_AARCH64_ARCH}>:folly_external_aor_memcpy_aarch64>)' \
          --replace-fail \
            'folly_add_library(NAME memset-impl SRCS FollyMemset.cpp)' \
            'folly_add_library(NAME memset-impl SRCS FollyMemset.cpp $<$<BOOL:''${IS_AARCH64_ARCH}>:memset_select_aarch64.cpp> DEPS $<$<BOOL:''${IS_AARCH64_ARCH}>:folly_external_aor_memset_aarch64>)'
        # Assemble the aarch64 sources with the C shared-library rule.
        substituteInPlace folly/external/aor/CMakeLists.txt \
          --replace-fail \
            'if (IS_AARCH64_ARCH)' \
            $'if (IS_AARCH64_ARCH)\n  if (BUILD_SHARED_LIBS)\n    set(CMAKE_ASM_CREATE_SHARED_LIBRARY ''${CMAKE_C_CREATE_SHARED_LIBRARY})\n  endif ()'
      '';
    };
  };

  fizz = bump (pkgs.fizz.override { inherit folly; }) {
    owner = "facebookincubator";
    repo = "fizz";
    hash = "sha256-lGw4/jz8QoHvZytq+yRLX1diHzzvDnSQExuz2SJbuoA=";
  };

  mvfst = bump (pkgs.mvfst.override { inherit folly fizz; }) {
    owner = "facebook";
    repo = "mvfst";
    hash = "sha256-/VdQE5T9Fcc2rAxH5LFVUQlUAfdet+81TYsn2K1SQaI=";
  };

  wangle = bump (pkgs.wangle.override { inherit folly fizz; }) {
    owner = "facebook";
    repo = "wangle";
    hash = "sha256-8dFcmpFdZAYJj9ZmGPHYJUSlEo45MjE1X1uevt59V7c=";
  };

  fbthrift =
    bump
      (pkgs.fbthrift.override {
        inherit
          folly
          fizz
          wangle
          mvfst
          ;
      })
      {
        owner = "facebook";
        repo = "fbthrift";
        hash = "sha256-S9E5bo1jrA45ZUpIRt/+nHSYqRxfNufu02gu6rTD+7s=";
        # fbthrift's CMake build was overhauled (GNUInstallDirs, relative
        # RPATHs, the deprecated Python "py" library now built by default).
        extraAttrs = old: {
          # Obsolete: the absolute CMAKE_INSTALL_RPATH it removed is gone.
          patches = lib.filter (
            p: !lib.hasSuffix "remove-cmake-install-rpath.patch" (toString p)
          ) old.patches;
          # The deprecated thrift-py library (built by default now) needs
          # Python; EdenFS's CMake checks for it (`COMPONENTS cpp2 py`).
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.python3 ];
          # Its libraries and `thrift` now link these (folly's link interface)
          # directly; list them so they end up in the RUNPATH.
          buildInputs = old.buildInputs ++ [
            pkgs.libevent
            pkgs.libunwind
            pkgs.lz4
            pkgs.xz
          ];
          cmakeFlags = old.cmakeFlags ++ [
            # Keep the CMake package next to the compiler (now installed as
            # `bin/thrift`; upstream's `thrift1` compat symlink fails to install
            # with absolute install dirs) and the headers in `out`, instead of
            # following CMAKE_INSTALL_LIBDIR into `lib`.
            (lib.cmakeFeature "THRIFT_INSTALL_CMAKEDIR" "${placeholder "out"}/lib/cmake/fbthrift")
            (lib.cmakeBool "THRIFT_BENCHMARKS" false)
            (lib.cmakeBool "THRIFT_PY_DEPRECATED" true)
          ];
        };
      };

  fb303 =
    bump
      (pkgs.fb303.override {
        inherit
          folly
          fizz
          wangle
          fbthrift
          ;
      })
      {
        owner = "facebook";
        repo = "fb303";
        hash = "sha256-tDiIILZdBUNtrgPqprOP+RO5j8O98MnpaL46SWkQQLM=";
        extraAttrs = old: {
          buildInputs = old.buildInputs ++ cmakeConfigDeps;
        };
      };

  edencommon =
    bump
      (pkgs.edencommon.override {
        inherit
          folly
          wangle
          fbthrift
          fb303
          ;
      })
      {
        owner = "facebookexperimental";
        repo = "edencommon";
        # EdenFS here already uses edencommon APIs that landed after the
        # 2026.09.28.00 release (e.g. `TelemetryStats::errorsRateLimited`), so
        # use the revision this checkout pins for getdeps in
        # build/deps/github_hashes/facebookexperimental/edencommon-rev.txt.
        rev = "6cc6d3caa8df22372fc8482af83b9351cbebcd67";
        version = "${release}-unstable-2026-09-30";
        hash = "sha256-9E0mcPv6tYyY50g19tlvqBAmYFT4e27cVXRxUdEYStU=";
        extraAttrs = old: {
          buildInputs = old.buildInputs ++ cmakeConfigDeps;
        };
      };

  # The fbthrift compiler used for *Rust* code generation by all three
  # packages. Rust Thrift code is generated at build time
  # (common/rust/shed/thrift_compiler, via $THRIFT) and compiled against the
  # in-repo fbthrift Rust runtime (thrift/lib/rust), whose traits change
  # between fbthrift releases; so the generator has to be the fbthrift
  # revision that runtime was exported from, which is newer than the release
  # above. C++ and Python code generation keep using `fbthrift`, which must
  # match the C++ libraries instead.
  #
  # It is only a build-time executable (no C++ library ends up in any of the
  # packages through it), so it is built against nixpkgs' own, cached folly
  # rather than the bumped one above: `sapling` and `mononoke` thus need no
  # part of the bumped C++ stack at all.
  thrift-rust-compiler = pkgs.callPackage ./thrift-rust-compiler.nix { };
in
{
  inherit
    thrift-rust-compiler
    folly
    fizz
    mvfst
    wangle
    fbthrift
    fb303
    edencommon
    ;
}
