# The fbthrift compiler, at the revision this checkout's in-repo fbthrift Rust
# runtime (thrift/lib/rust) was exported with.
#
# The Rust code generator and the Rust runtime must match: the generated
# service code implements traits from the runtime, and their signatures
# change between fbthrift releases (e.g. `ServiceProcessor::handle_method`
# changed after nixpkgs' 2026.07.27.00, and again after v2026.09.28.00).
# thrift/lib/rust here is identical to fbthrift at the revision getdeps pins
# in build/deps/github_hashes/facebook/fbthrift-rev.txt, so build that.
#
# Only the compiler is built (no C++ RPC libraries), so this is quick to
# build and does not need a matching fizz/wangle/mvfst. fbthrift's own
# libraries are linked into it statically; folly, boost, glog etc. are the
# shared ones from nixpkgs.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  folly,
  fmt,
  gflags,
  glog,
  openssl,
  zlib,
  zstd,
  xxhash,
}:

stdenv.mkDerivation {
  pname = "fbthrift-compiler";
  version = "2026.09.29-unstable-526970e";

  src = fetchFromGitHub {
    owner = "facebook";
    repo = "fbthrift";
    rev = "526970ebe60cc3bc4c89f1278fa9e5730d150416";
    hash = "sha256-pHk1sXfAmSx4dAeZVwIVvdatFA77D7YfLYGRot8NER0=";
  };

  nativeBuildInputs = [
    cmake
    ninja
  ];

  buildInputs = [
    folly
    fmt
    gflags
    glog
    openssl
    zlib
    zstd
    xxhash
  ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_SHARED_LIBS" false)
    (lib.cmakeBool "THRIFT_RPC" false)
    (lib.cmakeBool "THRIFT_BENCHMARKS" false)
    (lib.cmakeBool "THRIFT_TESTS" false)
    (lib.cmakeBool "THRIFT_PY_DEPRECATED" false)
    (lib.cmakeBool "THRIFT_PYTHON" false)
  ];

  # Only the compiler executable.
  ninjaFlags = [ "thrift" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/thrift $out/bin/thrift1
    runHook postInstall
  '';

  meta = {
    description = "Facebook's branch of Apache Thrift (compiler only)";
    homepage = "https://github.com/facebook/fbthrift";
    license = lib.licenses.asl20;
    mainProgram = "thrift1";
    platforms = lib.platforms.unix;
  };
}
