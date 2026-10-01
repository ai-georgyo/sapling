{
  description = "Sapling SCM, EdenFS and Mononoke";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      pkgsFor = lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        }
      );

      forAllSystems = f: lib.genAttrs systems (system: f pkgsFor.${system});
    in
    {
      # Adds `sapling`, `mononoke` and `edenfs` to a nixpkgs package set.
      overlays.default = import ./nix/overlay.nix;

      packages = forAllSystems (pkgs: {
        inherit (pkgs) sapling mononoke edenfs;
        default = pkgs.sapling;
      });

      checks = forAllSystems (pkgs: {
        inherit (pkgs) sapling mononoke edenfs;
        sapling-smoke = pkgs.sapling.tests.smoke;
        mononoke-smoke = pkgs.mononoke.tests.smoke;
        edenfs-smoke = pkgs.edenfs.tests.smoke;
        fb-stack = pkgs.callPackage ./nix/fb-stack-check.nix { };
        nix-formatting = pkgs.runCommand "nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          nixfmt --check ${./flake.nix} $(find ${./nix} -name '*.nix')
          touch $out
        '';
      });

      # Shells with each package's build environment, for working on the
      # code with cargo/cmake directly, e.g. `nix develop .#mononoke -c
      # cargo build --manifest-path eden/mononoke/Cargo.toml -p mononoke`.
      devShells = forAllSystems (
        pkgs:
        let
          inherit (pkgs.edenfs) fbStack;

          # Rust tooling shared by all shells (cargo and rustc come from the
          # packages' build inputs).
          rustTools = [
            pkgs.rust-analyzer
            pkgs.clippy
            pkgs.rustfmt
          ];

          commonEnv = {
            # Rust Thrift code generation (see nix/fb-stack.nix).
            THRIFT = fbStack.thrift1;
            # Link against the nixpkgs libraries, like the packages do.
            OPENSSL_NO_VENDOR = "1";
            LIBGIT2_NO_VENDOR = "1";
            LIBSSH2_SYS_USE_PKG_CONFIG = "1";
          };

          saplingEnv = commonEnv // {
            PYTHON_SYS_EXECUTABLE = pkgs.sapling.python.interpreter;
            PYO3_PYTHON = pkgs.sapling.python.interpreter;
          };

          mononokeEnv = commonEnv // {
            # As getdeps builds Mononoke: some dependencies use unstable
            # features.
            RUSTC_BOOTSTRAP = "1";
            ZSTD_SYS_USE_PKG_CONFIG = "1";
          };
        in
        {
          sapling = pkgs.mkShell {
            name = "sapling-dev";
            inputsFrom = [ pkgs.sapling ];
            packages = rustTools;
            env = saplingEnv;
          };

          mononoke = pkgs.mkShell {
            name = "mononoke-dev";
            inputsFrom = [ pkgs.mononoke ];
            packages = rustTools;
            env = mononokeEnv;
          };

          edenfs = pkgs.mkShell {
            name = "edenfs-dev";
            # The C++ stack (from nix/fb-stack.nix), cmake, ninja, cargo,
            # cxxbridge and the Python environment of the CLI.
            inputsFrom = [ pkgs.edenfs ];
            packages = rustTools;
            env = commonEnv;
          };

          # The Sapling and Mononoke Cargo workspaces (the bulk of the Rust
          # code), plus the formatter for the Nix files.
          default = pkgs.mkShell {
            name = "sapling-mononoke-dev";
            # Sapling first, so that its Python (3.12) is the `python3` on PATH.
            inputsFrom = [
              pkgs.sapling
              pkgs.mononoke
            ];
            packages = rustTools ++ [ pkgs.nixfmt-tree ];
            env = saplingEnv // mononokeEnv;
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
