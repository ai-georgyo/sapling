# End-to-end smoke test for the Mononoke binaries, modelled on the
# integration test setup (eden/mononoke/tests/integration/library.sh and
# eden/scm/sapling/testing/ext/mononoke.py): a repo backed by a filesystem
# blobstore and SQLite metadata, a small git repository imported with
# gitimport, the resulting bookmark read back with admin, and a mononoke
# server started and queried over mTLS.
#
# Usage: smoke-test.sh <bin dir> <test just_knobs.json> <test certs dir>
set -euo pipefail
BIN=$1
JUST_KNOBS=$2
CERTS=$3
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
mkdir -p cfg/common cfg/repos/repo cfg/repo_definitions/repo monsql blobstore/blobs configerator/scm/mononoke/redaction
echo '{"all_redactions": []}' > configerator/scm/mononoke/redaction/redaction_sets
cp "$JUST_KNOBS" configerator/just_knobs.json
mkdir -p configerator/scm/mononoke/repos/commitsyncmaps
echo '{}' > configerator/scm/mononoke/repos/commitsyncmaps/all
echo '{}' > configerator/scm/mononoke/repos/commitsyncmaps/current
cat > cfg/common/common.toml <<TOML
[internal_identity]
identity_type = "SERVICE_IDENTITY"
identity_data = "proxy"

[redaction_config]
blobstore = "blobstore"
redaction_sets_location = "scm/mononoke/redaction/redaction_sets"
TOML
: > cfg/common/commitsyncmap.toml
cat > cfg/common/storage.toml <<TOML
[blobstore.metadata.local]
local_db_path = "$T/monsql"

[blobstore.blobstore]
blob_files = { path = "$T/blobstore" }

[blobstore.mutable_blobstore]
blob_files = { path = "$T/blobstore" }
TOML
cat > cfg/repo_definitions/repo/server.toml <<TOML
repo_id = 0
repo_name = "repo"
repo_config = "repo"
enabled = true
hipster_acl = "default"
TOML
cat > cfg/repos/repo/server.toml <<TOML
storage_config = "blobstore"

[derived_data_config]
enabled_config_name = "default"

[derived_data_config.available_configs.default]
types = ["blame", "changeset_info", "deleted_manifest", "fastlog", "filenodes", "fsnodes", "git_commits", "git_delta_manifests_v2", "git_delta_manifests_v3", "unodes", "hgchangesets", "hg_augmented_manifests", "skeleton_manifests", "skeleton_manifests_v2", "bssm_v3", "ccsm", "inferred_copy_from", "acl_manifests", "content_manifests", "history_manifests"]
git_delta_manifest_v2_config.max_inlined_object_size = 20
git_delta_manifest_v2_config.max_inlined_delta_size = 20
git_delta_manifest_v2_config.delta_chunk_size = 1000
git_delta_manifest_version = 3
git_delta_manifest_v3_config.max_inlined_object_size = 20
git_delta_manifest_v3_config.max_inlined_delta_size = 20
git_delta_manifest_v3_config.delta_chunk_size = 1000
git_delta_manifest_v3_config.entry_chunk_size = 1000
xdb_mapping_shard_ids.history_manifests = 0
xdb_mapping_shard_ids.blame_v3 = 0
xdb_mapping_shard_ids.fastlog_v2 = 0

[git_configs.git_bundle_uri_config.uri_generator_type.local_fs]

[source_control_service]
permit_writes = true
permit_service_writes = true
permit_commits_without_parents = true
TOML

git init -q -b main src
git -C src -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
echo hello > src/hello.txt
git -C src add hello.txt
git -C src -c user.name=t -c user.email=t@example.com commit -q -m "add hello"

COMMON=(--mononoke-config-path "$T/cfg" --local-configerator-path "$T/configerator" --cache-mode=disabled --just-knobs-config-path just_knobs.json)
# No --git-command-path: the package points the default at nixpkgs git.
"$BIN/gitimport" "${COMMON[@]}" --repo-name repo --generate-bookmarks "$T/src" full-repo
"$BIN/admin" "${COMMON[@]}" bookmarks --repo-name repo list | tee bookmarks
grep -q ' heads/main$' bookmarks

# Start the server and query its health check endpoint over mTLS.
"$BIN/mononoke" "${COMMON[@]}" --listening-host-port 127.0.0.1:0 --bound-address-file "$T/addr" \
  --tls-ca "$CERTS/root-ca.crt" --tls-private-key "$CERTS/localhost.key" --tls-certificate "$CERTS/localhost.crt" \
  --scribe-logging-directory "$T/scribe" --no-default-scuba-dataset --disable-bookmark-cache-warming \
  > "$T/server.log" 2>&1 &
PID=$!
for _ in $(seq 300); do
  [ -s "$T/addr" ] && break
  kill -0 $PID 2>/dev/null || { tail -20 "$T/server.log"; exit 1; }
  sleep 1
done
ADDR=$(cat "$T/addr")
echo "server listening on $ADDR"
curl -sS --fail --resolve "localhost:${ADDR##*:}:127.0.0.1" \
  --cert "$CERTS/proxy.crt" --key "$CERTS/proxy.key" --cacert "$CERTS/root-ca.crt" \
  "https://localhost:${ADDR##*:}/health_check" | tee health
echo
grep -q I_AM_ALIVE health
kill $PID
wait $PID || true
