# Nix packaging

The flake at the repository root builds three packages from this checkout,
using nixpkgs for everything it can: compilers, Rust and Python, the libraries
and the Meta C++ stack.

| Output | What it is | Main binaries |
| --- | --- | --- |
| `packages.<system>.sapling` (also `default`) | The Sapling CLI, with the Interactive Smartlog web UI | `sl` |
| `packages.<system>.mononoke` | The Mononoke server and its tools (output `benchmarks` holds the benchmark and example programs) | `mononoke`, `admin`, `gitimport`, `lfs_server`, `git_server`, `walker`, ... |
| `packages.<system>.edenfs` | The EdenFS daemon, its privilege helper and the CLI, bundled with an EdenFS-enabled `sl` | `edenfs`, `edenfsctl` / `eden`, `libexec/eden/edenfs_privhelper` |
| `checks.<system>.*` | The three packages, a smoke test for each (`*-smoke`) and `nix-formatting` | |
| `devShells.<system>.{default,sapling,mononoke,edenfs}` | Build environments, see below | |
| `overlays.default` | Adds `sapling`, `mononoke` and `edenfs` to a nixpkgs package set | |
| `formatter.<system>` | `nixfmt-tree` | |

Systems are `x86_64-linux` and `aarch64-linux`. Only x86_64-linux has been
built and tested; aarch64-linux evaluates.

## Building

```sh
nix build .#sapling          # ./result/bin/sl
nix build .#mononoke         # ./result/bin/{mononoke,admin,...}
nix build .#edenfs           # ./result/bin/{edenfs,edenfsctl,eden}
nix run .#sapling -- version
nix flake check -L           # all packages and smoke tests
```

The builds are large: each Rust workspace has about 1000 crates, and EdenFS
also builds the C++ stack from `fb-stack.nix`, since that is not in the binary
cache. Use `--max-jobs`/`--cores` to limit how much of the machine they use.

Each package builds from a `lib.fileset` source that holds only the paths it
reads. Edits elsewhere in the repository, including Sapling's `.t` tests and
docs, do not trigger a rebuild.

### Using the overlay

```nix
{
  inputs.sapling.url = "github:facebook/sapling";
  outputs = { nixpkgs, sapling, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ sapling.overlays.default ];
          environment.systemPackages = [ pkgs.sapling pkgs.edenfs ];
        })
      ];
    };
  };
}
```

The packages take a few overridable arguments:

- `sapling.override { withIsl = false; }` drops the web UI and Node.js.
- `sapling.override { withEdenfs = false; }` builds without the `eden` Cargo
  feature, like upstream's `build.py --oss` releases. That build no longer
  needs a Thrift compiler, but `sl` then refuses to work in EdenFS checkouts.

### EdenFS at runtime

You need root to mount, or a setuid privhelper. On NixOS, install
`libexec/eden/edenfs_privhelper` through `security.wrappers`, and point
`EDENFS_PRIVHELPER_PATH` at the wrapper.

The CLIs run the bundled `sl` (`edenfs.passthru.sapling`) as `hg`, so it does
not matter which `hg` or `sl` is on `PATH`.

Keep the EdenFS state directory path short. A socket path longer than 108
bytes makes the Python CLI abort, which is upstream behaviour.

## Development shells

```sh
nix develop               # Sapling + Mononoke workspaces, rust-analyzer, clippy, nixfmt
nix develop .#sapling     # e.g. cd eden/scm && cargo build -p hgmain --features sl_oss,eden
nix develop .#mononoke    # e.g. cd eden/mononoke && cargo build -p mononoke
nix develop .#edenfs      # the C++ stack, cmake/ninja, cxxbridge, the CLI's Python
```

The shells set `THRIFT` to the matching Rust Thrift compiler (see below), along
with the `*_NO_VENDOR` variables that make Cargo link against the nixpkgs
libraries.

Upstream does not commit a `Cargo.lock`, and the manifests point at
`branch = "main"` git dependencies. For an offline-reproducible build, copy the
lock file and append the `[patch]` table, as the derivations do:

- **sapling** (eden/scm): drop the `[patch.crates-io] abomonation` block, append
  `nix/sapling/cargo-patches.toml`, and copy `nix/sapling/Cargo.lock`.
- **mononoke** (eden/mononoke): append `nix/mononoke/cargo-patch.toml`, and copy
  `nix/mononoke/Cargo.lock`.
- **edenfs** (eden/fs): the shell sets up the dependencies only. Configure the
  build with cmake as `nix/edenfs/default.nix` does.

## Layout

| File | Purpose |
| --- | --- |
| `overlay.nix` | Defines the three packages |
| `fb-stack.nix` | The Meta C++ stack and the Rust Thrift compiler the packages build against (see Pins) |
| `thrift-rust-compiler.nix` | The fbthrift compiler that generates Rust code |
| `src.nix` | Helper that builds a `lib.fileset` source |
| `<pkg>/default.nix` | The package |
| `<pkg>/Cargo.lock`, `<pkg>/cargo-patch*.toml` | The lock file and the `[patch]` entries that redirect the Meta git crates to the in-repo copies |
| `<pkg>/update-lockfile.sh` | Regenerates the lock file |
| `<pkg>/smoke-test.sh` | The `passthru.tests.smoke` / `checks.*-smoke` script |
| `edenfs/oss-build-fixes.patch` | Fixes for the bit-rotted open source CMake/Cargo build of EdenFS (see its header) |
| `edenfs/python-runtime.nix`, `edenfs/python-deps.cmake` | thrift-python and folly's Python bindings for the Python CLI (`edenfsctl.real`) |
| `edenfs/upstream-patches.toml` | The subset of upstream's eden/fs `[patch]` table that the dependency graph uses |
| `mononoke/strip-unused-patches.py` | Removes `[patch]` entries that the Mononoke lock does not use |

## Updating when the repository moves forward

1. **Lock files.** Run `nix/sapling/update-lockfile.sh`,
   `nix/mononoke/update-lockfile.sh` and `nix/edenfs/update-lockfile.sh`. They
   need network access.

   Each script copies the subset of the tree its package builds from, applies
   the same manifest edits as the derivation, and runs `cargo generate-lockfile`
   with the flake's pinned cargo. It then pins the rust-shed crates that are
   not vendored here to the revision in
   `build/deps/github_hashes/facebookexperimental/rust-shed-rev.txt`. The
   edenfs script also pins `cxx` to the nixpkgs `cxx-rs` version.

   The scripts warn about `[[patch.unused]]` entries. Delete those from the
   patch files.

2. **Vendor hashes.** After any change to a `Cargo.lock`, set the package's
   `cargoDeps.hash` to `lib.fakeHash` and run
   `nix build .#<pkg>.cargoDeps`. Copy the `got:` hash into the file. This step
   is required: the vendored directory contains the lock file.

3. **Rust Thrift compiler.** Set `rev`/`hash` in `thrift-rust-compiler.nix` to
   `build/deps/github_hashes/facebook/fbthrift-rev.txt`. Build errors in
   generated `*_thrift` crates mean this step was skipped.

4. **C++ stack (EdenFS).** If EdenFS needs newer folly/fbthrift/edencommon
   APIs, bump `release` and the hashes in `fb-stack.nix`. Use the edencommon
   revision from `build/deps/github_hashes/facebookexperimental/edencommon-rev.txt`.
   Drop the bump once nixpkgs catches up.

5. **Versions.** The version strings hard-code the checkout date
   (`*-unstable-2026-09-30`) in the three `default.nix` files.

6. **Upstream patches.** The `substituteInPlace --replace-fail` edits and
   `edenfs/oss-build-fixes.patch` fail loudly when upstream changes the code
   they touch. Rebase them, or drop the ones that are no longer needed.

## Pins and why

- **Python 3.12 for Sapling.** nixpkgs defaults to 3.14. Upstream builds and
  releases Sapling with 3.12, and its rust-cpython 0.7 bindings predate 3.13.
  nixpkgs' own `sapling` also pins 3.12. EdenFS's Python CLI uses the nixpkgs
  default Python.
- **The Meta C++ stack for EdenFS** (`fb-stack.nix`). folly, fizz, mvfst,
  wangle, fbthrift and fb303 are bumped from nixpkgs' 2026.07.27.00 to the
  v2026.09.28.00 release, and edencommon to getdeps' revision `6cc6d3ca`. These
  libraries are released in lock-step, and EdenFS here uses newer APIs,
  especially from edencommon. The bump reuses the nixpkgs derivations and
  affects only these packages, not the rest of nixpkgs. Sapling and Mononoke
  link none of it.
- **The Rust Thrift compiler** (`thrift-rust-compiler.nix`). This is fbthrift
  at getdeps' revision `526970eb`, compiler only, built against nixpkgs' cached
  folly. Generated Rust code implements traits of the in-repo runtime
  (`thrift/lib/rust`), and those traits change between fbthrift releases. Code
  generated by any released fbthrift, nixpkgs' or v2026.09.28.00, fails to
  compile against it. All three packages use this compiler. C++ and Python
  code generation in EdenFS uses `fbStack.fbthrift` to match its C++
  libraries.
- **Meta git crates.** fbthrift, fb303, watchman and most rust-shed crates come
  from the in-repo copies (`thrift/lib/rust`, `fb303/thrift`, `watchman/rust`,
  `common/rust/shed`) through `[patch."https://github.com/..."]`, as getdeps
  does with `crate.pathmap`. The remaining rust-shed crates are pinned to
  getdeps' rust-shed revision `cf631aa8`.
- **`cxx` 1.0.194 in EdenFS.** nixpkgs' `cxxbridge` (cxx-rs) generates the C++
  side of the bridges and must be the same version as the crate; an
  evaluation-time assertion checks this. Mononoke builds its cxx bridges
  entirely through Cargo, with upstream's facebookexperimental/cxx fork, so it
  needs no matching tool.
- **Unstable Rust features.** Mononoke builds with `RUSTC_BOOTSTRAP=1` like
  getdeps, because some dependencies use unstable features. The rest of the
  toolchain is the nixpkgs default (rustc 1.98).

## Known limitations

- Test suites are disabled (`doCheck = false`); the smoke tests replace them.
  The EdenFS smoke test cannot mount anything, since the Nix sandbox has no
  FUSE. An end-to-end run (clone, status, commit, goto) was done manually
  under `unshare`.
- Mononoke: `scs_server`, `derived_data_service` and a few others are not
  built, because the open source Cargo workspace has no manifests for them.
  The same is true upstream. Some tools have generic names (`import`,
  `worker`, ...).
- EdenFS: the Meta-internal pieces (telemetry, Manifold upload, the lmdb
  benchmark) are stubbed out by `oss-build-fixes.patch`. `eden du` needs
  `remotefilelog.cachepath` set. `eden clone` of a Git-backed Sapling repo
  fails; native Sapling repos work.
- Sapling installs only `sl`, without an `hg` alias or `scm_daemon`.
