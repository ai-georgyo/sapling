# Nix packaging

The flake at the repository root builds three packages from this checkout,
using nixpkgs for everything it can: compilers, Rust and Python and the
libraries. Meta's own libraries (folly, fbthrift, ...) reuse the nixpkgs
derivations, at the revisions this checkout records for them.

| Output | What it is | Main binaries |
| --- | --- | --- |
| `packages.<system>.sapling` (also `default`) | The Sapling CLI, with the Interactive Smartlog web UI | `sl` |
| `packages.<system>.mononoke` | The Mononoke server and its tools (output `benchmarks` holds the benchmark and example programs) | `mononoke`, `admin`, `gitimport`, `lfs_server`, `git_server`, `walker`, ... |
| `packages.<system>.edenfs` | The EdenFS daemon, its privilege helper and the CLI, bundled with an EdenFS-enabled `sl` | `edenfs`, `edenfsctl` / `eden`, `libexec/eden/edenfs_privhelper` |
| `checks.<system>.*` | The three packages, a smoke test for each (`*-smoke`) and `nix-formatting` | |
| `devShells.<system>.{default,sapling,mononoke,edenfs}` | Build environments, see below | |
| `legacyPackages.<system>.fbStack` | The Meta libraries the packages build against, as a package scope (see below) | `thrift` (fbthrift) |
| `overlays.default` | Adds `sapling`, `mononoke`, `edenfs` and `fbStack` to a nixpkgs package set | |
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

The builds are large: each Rust workspace has about 1000 crates, and all
three packages need the Meta C++ stack from `fb-stack.nix` (for its Thrift
compiler at least), which is not in the binary cache. Use `--max-jobs`/`--cores` to limit how much of the machine they use.

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

### The Meta libraries (`fbStack`)

`fbStack` is a package scope (`lib.makeScope`) with the Meta libraries at
this checkout's revisions (see Pins): `folly`, `fizz`, `mvfst`, `wangle`,
`fbthrift`, `fb303` and `edencommon`, the Python bindings `folly-python`,
`fbthrift-python` and `thrift-python`, and `thrift1`, the path of fbthrift's
Thrift compiler.

```sh
nix build .#fbStack.folly
nix build .#fbStack.fbthrift   # ./result/bin/thrift
```

Each library is built against the others in the scope, and the three
packages take theirs from `fbStack`, so `overrideScope` changes all of them:

```nix
final: prev: {
  fbStack = prev.fbStack.overrideScope (
    fbFinal: fbPrev: {
      folly = fbPrev.folly.overrideAttrs { /* ... */ };
    }
  );
}
```

Only these packages and the scope use them; the rest of nixpkgs keeps the
nixpkgs versions of the same libraries.

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
| `fb-stack.nix` | The `fbStack` scope: the Meta libraries (C++ stack and Thrift compiler) the packages build against (see Pins) |
| `fb-stack-python.nix` | thrift-python and folly's Python bindings (in `fbStack`), for the EdenFS Python CLI (`edenfsctl.real`) |
| `fb-stack.json` | Their revisions and hashes, mirrored from `build/deps/github_hashes` |
| `update-fb-stack.sh` | Regenerates `fb-stack.json` |
| `fb-stack-check.nix` | The `checks.*.fb-stack` consistency check |
| `src.nix` | Helper that builds a `lib.fileset` source |
| `<pkg>/default.nix` | The package |
| `<pkg>/Cargo.lock`, `<pkg>/cargo-patch*.toml` | The lock file and the `[patch]` entries that redirect the Meta git crates to the in-repo copies |
| `<pkg>/update-lockfile.sh` | Regenerates the lock file |
| `<pkg>/smoke-test.sh` | The `passthru.tests.smoke` / `checks.*-smoke` script |
| `edenfs/oss-build-fixes.patch` | Fixes for the bit-rotted open source CMake/Cargo build of EdenFS (see its header) |
| `edenfs/python-deps.cmake` | The thrift-python modules the EdenFS Python CLI generates |
| `edenfs/upstream-patches.toml` | The subset of upstream's eden/fs `[patch]` table that the dependency graph uses |
| `mononoke/strip-unused-patches.py` | Removes `[patch]` entries that the Mononoke lock does not use |

## Updating when the repository moves forward

1. **Meta libraries.** Run `nix/update-fb-stack.sh` (needs network). It reads
   the revisions this checkout records for its getdeps builds
   (`build/deps/github_hashes/<owner>/<repo>-rev.txt`) and writes them, with
   their hashes, to `fb-stack.json`. Everything Meta-made follows from that
   file: the C++ stack, the Thrift compiler and the rust-shed revision the lock
   files pin. `nix flake check` (the `fb-stack` check) fails while
   `fb-stack.json` or a `Cargo.lock` is out of sync.

2. **Lock files.** Run `nix/sapling/update-lockfile.sh`,
   `nix/mononoke/update-lockfile.sh` and `nix/edenfs/update-lockfile.sh`. They
   need network access.

   Each script copies the subset of the tree its package builds from, applies
   the same manifest edits as the derivation, and runs `cargo generate-lockfile`
   with the flake's pinned cargo. It then pins the rust-shed crates that are
   not vendored here to the revision in `fb-stack.json`. The edenfs script also
   pins `cxx` to the nixpkgs `cxx-rs` version.

   The scripts warn about `[[patch.unused]]` entries. Delete those from the
   patch files.

3. **Vendor hashes.** After any change to a `Cargo.lock`, set the package's
   `cargoDeps.hash` to `lib.fakeHash` and run
   `nix build .#<pkg>.cargoDeps`. Copy the `got:` hash into the file. This step
   is required: the vendored directory contains the lock file.

4. **Versions.** The version strings hard-code the checkout date
   (`*-unstable-2026-10-01`) in the three `default.nix` files.

5. **Upstream patches.** The `substituteInPlace --replace-fail` edits and
   `edenfs/oss-build-fixes.patch` fail loudly when upstream changes the code
   they touch. Rebase them, or drop the ones that are no longer needed.

## Pins and why

- **Python 3.12 for Sapling.** nixpkgs defaults to 3.14. Upstream builds and
  releases Sapling with 3.12, and its rust-cpython 0.7 bindings predate 3.13.
  nixpkgs' own `sapling` also pins 3.12. EdenFS's Python CLI uses the nixpkgs
  default Python.
- **All Meta libraries at this checkout's getdeps revisions** (`fb-stack.nix`,
  `fb-stack.json`). folly, fizz, mvfst, wangle, fbthrift, fb303, edencommon and
  rust-shed are at the revisions in `build/deps/github_hashes`, the same ones
  upstream CI builds this checkout against, instead of nixpkgs' 2026.07.27.00.
  These libraries are developed in lock-step: EdenFS uses APIs newer than
  any release (especially from edencommon), and the Rust code fbthrift's
  compiler generates implements traits of the in-repo runtime
  (`thrift/lib/rust`), which change between releases and is exported from that
  same fbthrift revision. So a single fbthrift (`fbStack.fbthrift`, compiler
  `fbStack.thrift1`) generates the C++, Python and Rust Thrift code of all
  three packages. The nixpkgs derivations are reused with only the source
  swapped, and the rest of nixpkgs keeps its own versions. The cost is that
  every package, not just EdenFS, needs the stack built from source (it is not
  in the binary cache).
- **Meta git crates.** fbthrift, fb303, watchman and most rust-shed crates come
  from the in-repo copies (`thrift/lib/rust`, `fb303/thrift`, `watchman/rust`,
  `common/rust/shed`) through `[patch."https://github.com/..."]`, as getdeps
  does with `crate.pathmap`. The remaining rust-shed crates are pinned to
  the rust-shed revision in `fb-stack.json`.
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
