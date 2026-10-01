# Overlay adding the packages built from this repository.
#
# Everything comes from nixpkgs where possible. `fb-stack.nix` decides which
# versions of the Meta C++ stack (folly, fbthrift, fb303, edencommon, ...) and
# which Rust Thrift compiler these packages are built with, without replacing
# them for the rest of nixpkgs.
final: prev:
let
  fbStack = import ./fb-stack.nix { pkgs = final; };
in
{
  sapling = final.callPackage ./sapling { inherit fbStack; };
  mononoke = final.callPackage ./mononoke { inherit fbStack; };
  edenfs = final.callPackage ./edenfs { inherit fbStack; };
}
