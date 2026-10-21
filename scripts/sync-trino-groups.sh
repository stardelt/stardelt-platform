#!/usr/bin/env bash
# Write the Trino file group-provider's membership from the live Keycloak realm
# (platform#125: query visibility is owner-only, admins exempted).
#
#   NAMESPACE=stardelt bash scripts/sync-trino-groups.sh
#   GROUP_PRINCIPAL=username NAMESPACE=stardelt bash scripts/sync-trino-groups.sh
#
# Why this exists: Trino enforces query visibility itself (file-based system
# access control in helm-values/trino-identity.yaml), but it cannot read groups
# from the OIDC token — the group provider reads a file instead. This script is
# the bridge: it reads the members of group `stardelt-admins` from the live
# realm and writes/refreshes ConfigMap `trino-group-file` with one line
# `stardelt-admins:<user1>,<user2>` (the file group-provider format: one
# `group:user,...` line per group).
#
# GROUP_PRINCIPAL is the Trino principal the file has to match, because the
# file is compared against `current_user` — a string from the token, whichever
# claim Trino was told to use:
#
#   * `sub` (default, platform#311): the Keycloak user `id`, a UUID. This is the
#     principal with `http-server.authentication.oauth2.principal-field=sub`,
#     i.e. once the catalog enforces permissions (`make catalog-enforce`). It is
#     also what the OPA bridge needs (`oidc~<sub>`), and what the bridge's
#     `adminUsers` list compares against.
#   * `username`: the `preferred_username` claim. The principal before that
#     switch (`make catalog-enforce-rollback` passes this).
#
# A group file whose strings do not match the configured principal fails
# silently and *open*: Trino simply finds no group for anyone, so admins lose
# the query visibility and the table rules they had. Keep the two in step —
# `make catalog-enforce` and its rollback both write this file themselves.
#
# Idempotent: byte-identical content means no write (no-op, like
# scripts/sync-oidc-clients.sh). `make trino` runs this before the helm upgrade
# so membership changes land on the next apply; `file.refresh-period=30s` in
# the group-provider properties picks the remounted file up with no restart.
# Membership changes therefore take effect on the next sync, not instantly —
# continuous sync is a follow-up, not this script.
#
# Reaches Keycloak through svc/keycloak (port-forward) because the public
# `/admin` API is closed. Secrets are read into files under a mode-0700 temp
# dir and never printed. The ConfigMap content is never committed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
REALM="${REALM:-stardelt}"
ADMIN_GROUP="${ADMIN_GROUP:-stardelt-admins}"
GROUP_CONFIGMAP="${GROUP_CONFIGMAP:-trino-group-file}"
MASTER_SECRET="${MASTER_SECRET:-keycloak-admin}"
# Which claim names the user: `sub` (UUID, the principal with
# http-server.authentication.oauth2.principal-field=sub) or `username`
# (preferred_username). See the header.
GROUP_PRINCIPAL="${GROUP_PRINCIPAL:-sub}"

CURL=(curl --fail-with-body --silent --show-error --max-time 30)
CURL_SOFT=(curl --silent --show-error --max-time 30)

for tool in kubectl curl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "sync-trino-groups: $tool not found" >&2; exit 1; }
done

umask 077
tmp="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "sync-trino-groups: $*" >&2; exit 1; }

case "$GROUP_PRINCIPAL" in
  sub|username) ;;
  *) fail "GROUP_PRINCIPAL must be 'sub' or 'username', not '$GROUP_PRINCIPAL'" ;;
esac

# 1. Reach the admin API on loopback, through the Service.
local_port=18220
while (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; do
  local_port=$((local_port + 1))
done
kubectl -n "$NAMESPACE" port-forward svc/keycloak "$local_port:8080" >"$tmp/port-forward.log" 2>&1 &
pf_pid=$!
ready=""
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$local_port") 2>/dev/null; then ready=1; break; fi
  sleep 0.5
done
[ -n "$ready" ] || fail "port-forward to svc/keycloak never came up — is Keycloak installed in namespace $NAMESPACE?"
KC="http://127.0.0.1:$local_port"

# Keycloak in production mode answers on its public hostname (KC_HOSTNAME), so a
# request to 127.0.0.1 has to say which host it is meant for.
strip_scheme() { printf '%s' "$1" | sed -E 's|https?://||; s|/.*||'; }
KC_HOST="$(strip_scheme "$(kubectl -n "$NAMESPACE" get configmap keycloak-env -o jsonpath='{.data.KC_HOSTNAME}' 2>/dev/null || true)")"
[ -n "$KC_HOST" ] || fail "ConfigMap keycloak-env has no KC_HOSTNAME — run 'make install-identity'"
HEAD=(-H "X-Forwarded-Host: $KC_HOST" -H 'X-Forwarded-Proto: https')

# 2. Master-realm token. Retry: the Service can accept a connection while Keycloak
#    is still finishing its boot.
kubectl -n "$NAMESPACE" get secret "$MASTER_SECRET" -o jsonpath='{.data.password}' | base64 -d > "$tmp/master-pw" \
  || fail "cannot read Secret $MASTER_SECRET — run 'make install-identity'"
master_token=""
for _ in $(seq 1 20); do
  master_token="$("${CURL_SOFT[@]}" "${HEAD[@]}" -X POST "$KC/realms/master/protocol/openid-connect/token" \
    --data-urlencode "username=admin" --data-urlencode "password@$tmp/master-pw" \
    --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token") or "")
except Exception: print("")' 2>/dev/null || true)"
  [ -n "$master_token" ] && break
  sleep 2
done
[ -n "$master_token" ] || fail "the master realm refused the $MASTER_SECRET credential — is Keycloak reachable through svc/keycloak?"
AUTH=(-H "Authorization: Bearer $master_token")
API="$KC/admin/realms/$REALM"

for _ in $(seq 1 30); do
  status="$("${CURL_SOFT[@]}" -o /dev/null -w '%{http_code}' "${HEAD[@]}" "${AUTH[@]}" "$API" || true)"
  [ "$status" = 200 ] && break
  sleep 2
done
[ "$status" = 200 ] || fail "realm $REALM does not exist after 60s — check 'kubectl -n $NAMESPACE logs deploy/keycloak' for the import"

# 3. Resolve the group, then list its members. `briefRepresentation=true` keeps
#    the payload to what the group file needs: the id and the username.
group_json="$("${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/group-by-path/$ADMIN_GROUP")" \
  || fail "realm $REALM has no group '$ADMIN_GROUP' (re-apply the realm import / create it in the console)"
group_id="$(printf '%s' "$group_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
"${CURL[@]}" "${HEAD[@]}" "${AUTH[@]}" "$API/groups/$group_id/members?briefRepresentation=true" > "$tmp/members.json" \
  || fail "cannot list members of group '$ADMIN_GROUP'"

# The principals only (id for `sub`, username for `username`), sorted for stable
# output. Prints the member count (the only thing the operator sees — principals
# stay out of the log, like the other sync scripts, which never print values).
count="$(python3 - "$tmp/members.json" "$tmp/groups.txt" "$ADMIN_GROUP" "$GROUP_PRINCIPAL" <<'PY'
import json, sys
members_path, out_path, group, principal = sys.argv[1:]
field = "id" if principal == "sub" else "username"
members = json.load(open(members_path))
names = set()
for user in members:
    value = user.get(field)
    if not value:
        sys.exit("sync-trino-groups: a member of %s has no %r in the realm" % (group, field))
    names.add(value)
with open(out_path, "w") as handle:
    handle.write("%s:%s\n" % (group, ",".join(sorted(names))))
print(len(names))
PY
)"
[ -n "$count" ] || fail "cannot build the group file from the members of $ADMIN_GROUP"

# 4. Converge the ConfigMap. Byte-identical content means no write — the data
#    fans out through a mounted volume, so a no-op write would still bounce the
#    kubelet's file timestamp for nothing. Comparison ignores the trailing
#    newline (jsonpath drops it; the file on disk has one).
desired="$tmp/groups.txt"
live="$tmp/groups-live.txt"
if kubectl -n "$NAMESPACE" get configmap "$GROUP_CONFIGMAP" -o jsonpath='{.data.groups\.txt}' > "$live" 2>/dev/null; then
  if python3 - "$desired" "$live" <<'PY'; then
import sys
desired, live = (open(path).read().rstrip("\n") for path in sys.argv[1:])
sys.exit(0 if desired == live else 1)
PY
    echo "› ConfigMap $GROUP_CONFIGMAP: already holds the $count principal(s) of $ADMIN_GROUP by $GROUP_PRINCIPAL — nothing to do"
    echo "sync-trino-groups: OK — $ADMIN_GROUP ($count member(s), principals by $GROUP_PRINCIPAL) in ConfigMap $GROUP_CONFIGMAP, unchanged"
    exit 0
  fi
  kubectl -n "$NAMESPACE" create configmap "$GROUP_CONFIGMAP" --from-file=groups.txt="$desired" \
    --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null \
    || fail "cannot update ConfigMap $GROUP_CONFIGMAP"
  echo "› ConfigMap $GROUP_CONFIGMAP: updated ($count principal(s) of $ADMIN_GROUP by $GROUP_PRINCIPAL)"
else
  kubectl -n "$NAMESPACE" create configmap "$GROUP_CONFIGMAP" --from-file=groups.txt="$desired" >/dev/null \
    || fail "cannot create ConfigMap $GROUP_CONFIGMAP"
  echo "› ConfigMap $GROUP_CONFIGMAP: created ($count principal(s) of $ADMIN_GROUP by $GROUP_PRINCIPAL)"
fi

# 5. Prove it: read back and compare bytes, not intentions.
kubectl -n "$NAMESPACE" get configmap "$GROUP_CONFIGMAP" -o jsonpath='{.data.groups\.txt}' > "$tmp/groups-readback.txt" \
  || fail "cannot read ConfigMap $GROUP_CONFIGMAP back after the write"
python3 - "$desired" "$tmp/groups-readback.txt" <<'PY' \
  || fail "ConfigMap $GROUP_CONFIGMAP reads back different content than written"
import sys
desired, live = (open(path).read().rstrip("\n") for path in sys.argv[1:])
sys.exit(0 if desired == live else 1)
PY
echo "sync-trino-groups: OK — $ADMIN_GROUP ($count member(s), principals by $GROUP_PRINCIPAL) in ConfigMap $GROUP_CONFIGMAP, verified"
