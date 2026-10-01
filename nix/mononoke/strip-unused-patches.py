"""Drop `[patch.*]` entries from a Cargo.toml that the Cargo.lock does not use.

The Mononoke workspace manifest is shared with other Meta projects and carries
many `[patch]` entries for crates that Mononoke never depends on. Cargo still
tries to load every patch source during resolution, which fails in the Nix
sandbox for git sources that were (rightly) not vendored. Removing the entries
that the lock file does not reference keeps the offline build working without
changing the resolved crate graph.

Usage: strip-unused-patches.py Cargo.toml Cargo.lock
"""

import re
import sys
import tomllib


def main() -> None:
    manifest_path, lock_path = sys.argv[1:]
    with open(lock_path, "rb") as f:
        lock = tomllib.load(f)

    # (name, kind, detail) triples describing what the lock actually contains.
    locked = set()
    for pkg in lock.get("package", []):
        source = pkg.get("source")
        if source is None:
            locked.add((pkg["name"], "path", None))
        elif source.startswith("git+"):
            locked.add((pkg["name"], "git", source[4:].split("#", 1)[0]))
        else:
            locked.add((pkg["name"], "registry", None))

    with open(manifest_path, "rb") as f:
        manifest = tomllib.load(f)

    # Patch entries to drop, keyed by (patched source, entry key).
    drop = set()
    for patched_source, entries in manifest.get("patch", {}).items():
        for key, spec in entries.items():
            if isinstance(spec, str):
                spec = {"version": spec}
            name = spec.get("package", key)
            if "git" in spec:
                ref = next(
                    (f"?{r}={spec[r]}" for r in ("rev", "tag", "branch") if r in spec),
                    "",
                )
                wanted = (name, "git", spec["git"] + ref)
            elif "path" in spec:
                wanted = (name, "path", None)
            else:
                wanted = (name, "registry", None)
            if wanted not in locked:
                drop.add((patched_source, key))

    # Rewrite the manifest textually so everything else stays byte-identical.
    # Every patch entry in these manifests is a single line.
    header = re.compile(r'^\[patch\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]\s*$')
    entry = re.compile(r"^([A-Za-z0-9_-]+)\s*=")
    section = None
    out = []
    removed = 0
    with open(manifest_path) as f:
        for line in f:
            m = header.match(line)
            if m:
                section = m.group(1) or m.group(2)
            elif line.startswith("["):
                section = None
            elif section is not None:
                e = entry.match(line)
                if e and (section, e.group(1)) in drop:
                    removed += 1
                    continue
            out.append(line)

    if removed != len(drop):
        sys.exit(f"expected to remove {len(drop)} patch entries, removed {removed}")
    with open(manifest_path, "w") as f:
        f.writelines(out)
    print(f"strip-unused-patches: removed {removed} unused [patch] entries")


if __name__ == "__main__":
    main()
