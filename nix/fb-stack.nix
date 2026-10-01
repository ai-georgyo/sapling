# The Meta libraries the packages in this repository build against.
#
# All of them are at the revisions this checkout itself records for its
# getdeps builds (build/deps/github_hashes/<owner>/<repo>-rev.txt), which
# fb-stack.json mirrors; run ./update-fb-stack.sh to resync it. That keeps
# every Meta component consistent with each other and with this checkout:
#
# - the C++ stack below (folly, fizz, mvfst, wangle, fbthrift, fb303,
#   edencommon), which EdenFS links against;
# - fbthrift's compiler, which generates the C++, Python *and* Rust Thrift
#   code of all three packages (`thrift1` below). The Rust code is compiled
#   against the in-repo fbthrift Rust runtime (thrift/lib/rust), which is
#   exported from this same fbthrift revision;
# - rust-shed, whose crates that are not vendored in this repository are
#   locked to the same revision in the packages' Cargo.lock files
#   (see the update-lockfile.sh scripts; checked by the `fb-stack` check).
#
# nixpkgs ships the 2026.07.27.00 release of the C++ stack, which is too old
# for this checkout (EdenFS uses newer APIs, and the Rust code generator has
# to match the in-repo runtime). The nixpkgs derivations are reused, only
# swapping versions and sources. The returned packages are only used by the
# packages in this repository; the rest of nixpkgs keeps its own versions.
{ pkgs }:
let
  inherit (pkgs) lib fetchFromGitHub;

  revs = lib.importJSON ./fb-stack.json;

  bump =
    pkg: name: extraAttrs:
    let
      info = revs.${name};
    in
    pkg.overrideAttrs (
      old:
      {
        version = "0-unstable-${info.date}";
        src = fetchFromGitHub {
          inherit (info)
            owner
            repo
            rev
            hash
            ;
        };
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

  # folly's CMake files were reformatted/restructured since 2026.07.27, so the
  # nixpkgs patches no longer apply. Of the two aarch64 build fixes, the one
  # wiring the assembly memcpy/memset into memcpy-impl/memset-impl is still
  # needed and is re-applied below; the other one (an ASM shared-library rule
  # for folly/external/aor) is obsolete, since those sources are now object
  # libraries of the monolithic libfolly. The third patch only relocated test
  # certificates for `folly_test_util`, which nothing here uses.
  folly = bump pkgs.folly "folly" (old: {
    patches = [ ];
    postPatch = old.postPatch + ''
      # https://github.com/facebook/folly/pull/2561
      substituteInPlace folly/CMakeLists.txt \
        --replace-fail \
          $'  NAME memcpy-impl\n  SRCS FollyMemcpy.cpp\n)' \
          $'  NAME memcpy-impl\n  SRCS FollyMemcpy.cpp $<$<BOOL:''${IS_AARCH64_ARCH}>:memcpy_select_aarch64.cpp>\n  DEPS $<$<BOOL:''${IS_AARCH64_ARCH}>:folly_memcpy_aarch64>\n)' \
        --replace-fail \
          $'  NAME memset-impl\n  SRCS FollyMemset.cpp\n)' \
          $'  NAME memset-impl\n  SRCS FollyMemset.cpp $<$<BOOL:''${IS_AARCH64_ARCH}>:memset_select_aarch64.cpp>\n  DEPS $<$<BOOL:''${IS_AARCH64_ARCH}>:folly_memset_aarch64>\n)'
    '';
  });

  fizz = bump (pkgs.fizz.override { inherit folly; }) "fizz" (old: { });

  mvfst = bump (pkgs.mvfst.override { inherit folly fizz; }) "mvfst" (old: { });

  wangle = bump (pkgs.wangle.override { inherit folly fizz; }) "wangle" (old: { });

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
      "fbthrift"
      # fbthrift's CMake build was overhauled (GNUInstallDirs, relative
      # RPATHs, the deprecated Python "py" library now built by default).
      (
        old: {
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
        }
      );

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
      "fb303"
      (old: {
        buildInputs = old.buildInputs ++ cmakeConfigDeps;
      });

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
      "edencommon"
      (old: {
        buildInputs = old.buildInputs ++ cmakeConfigDeps;
      });

  # The Thrift compiler (C++, Python and Rust code generation).
  thrift1 = lib.getExe' fbthrift "thrift";
in
{
  inherit
    thrift1
    folly
    fizz
    mvfst
    wangle
    fbthrift
    fb303
    edencommon
    ;
}
