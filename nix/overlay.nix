# Overlay adding the packages built from this repository.
#
# Everything comes from nixpkgs where possible. `fbStack` (fb-stack.nix) is
# the package scope of the Meta libraries (folly, fbthrift, fb303,
# edencommon, ...) and the Thrift compiler at the versions these packages are
# built with; it does not replace them for the rest of nixpkgs. Override it
# with `fbStack.overrideScope` to change them for all three packages.
final: prev: {
  fbStack = final.callPackage ./fb-stack.nix { };

  sapling = final.callPackage ./sapling { };
  mononoke = final.callPackage ./mononoke { };
  edenfs = final.callPackage ./edenfs { };
}
