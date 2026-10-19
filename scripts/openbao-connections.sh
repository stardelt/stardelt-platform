#!/usr/bin/env bash
# Wire the connection policies into the sandbox secret store (OpenBao, decision D27). Idempotent: it
# only adds or updates groups, aliases and policies, never deletes one; removing an owner group is a
# separate, later step. Run it after scripts/openbao-bootstrap.sh (`make openbao` does).
#
#   NAMESPACE=stardelt bash scripts/openbao-connections.sh analytics finance
#   NAMESPACE=stardelt OWNER_GROUPS="analytics finance" bash scripts/openbao-connections.sh
#
# It writes the three shared policies from scripts/openbao-policies/ (only the placeholders differ
# from the files: the jwt mount accessor and the owner group), and for every owner group an external
# group `owner-<g>` with the group alias `<g>` — the alias name is the group name exactly as the
# token's `groups` claim carries it. Administrators become the external group `platform-admins` with
# the alias $ADMIN_GROUP (default stardelt-admins).
#
# Tokens reach the store only through stdin of `kubectl exec`, never through argv or a log line.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="${NAMESPACE:-stardelt}"
POD="${POD:-openbao-0}"
CONTAINER="${CONTAINER:-openbao}"
INIT_SECRET=openbao-init

ADMIN_GROUP="${ADMIN_GROUP:-stardelt-admins}"
POLICIES="$PWD/scripts/openbao-policies"

for tool in kubectl python3 base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "openbao-connections: $tool not found" >&2; exit 1; }
done

fail() { echo "openbao-connections: $*" >&2; exit 1; }
K=(kubectl -n "$NAMESPACE")

# 1. Owner groups: arguments, else the space-separated OWNER_GROUPS. Validate every name before any
# kubectl call — a name with `/` or `..` would otherwise move a group's policy to another path.
groups=()
if [ "$#" -gt 0 ]; then
  groups=("$@")
elif [ -n "${OWNER_GROUPS:-}" ]; then
  read -r -a groups <<< "$OWNER_GROUPS"
fi
group_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
for g in "${groups[@]}"; do
  [[ "$g" =~ $group_re ]] \
    || fail "refusing owner group name '$g' (letters, digits, dot, underscore and dash; at most 64)"
done
[[ "$ADMIN_GROUP" =~ $group_re ]] \
  || fail "refusing admin group name '$ADMIN_GROUP' (letters, digits, dot, underscore and dash; at most 64)"

# bao <args...>: no token. bao_root <args...>: the root token is sent as the first line of stdin and
# exported inside the pod; anything the caller pipes in follows it.
bao() { "${K[@]}" exec -i "$POD" -c "$CONTAINER" -- env BAO_ADDR=http://127.0.0.1:8200 bao "$@"; }
bao_root() {
  { printf '%s\n' "$ROOT_TOKEN"; cat; } | "${K[@]}" exec -i "$POD" -c "$CONTAINER" -- \
    sh -c 'IFS= read -r BAO_TOKEN; export BAO_TOKEN BAO_ADDR=http://127.0.0.1:8200; exec bao "$@"' sh "$@"
}
json_get() { python3 -c 'import sys,json;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "$1"; }

ROOT_TOKEN="$("${K[@]}" get secret "$INIT_SECRET" -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)" \
  || true
[ -n "${ROOT_TOKEN:-}" ] || fail "Secret $INIT_SECRET has no root token: the store is initialised but its token is gone"

# 2. The accessor of the jwt mount: a group alias names the mount by accessor, not by path.
ACC="$(bao_root auth list -format=json < /dev/null | json_get 'jwt/.accessor')" || ACC=""
[ -n "$ACC" ] || fail "the jwt/ auth method is missing: run scripts/openbao-bootstrap.sh first"

# 3. The shared policies, straight from the files; connections-user needs the mount accessor.
sed "s/__ACCESSOR__/$ACC/g" "$POLICIES/connections-user.hcl" | bao_root policy write connections-user - >/dev/null
bao_root policy write connections-admin - < "$POLICIES/connections-admin.hcl" >/dev/null
bao_root policy write connections-platform-read - < "$POLICIES/connections-platform-read.hcl" >/dev/null
echo "› policies connections-user, connections-admin, connections-platform-read: written"

# group <name> <policy> <alias>: external group plus its alias on the jwt mount, alias only if missing.
group() {
  local name=$1 policy=$2 alias=$3 id alias_name
  bao_root write identity/group name="$name" type=external policies="$policy" < /dev/null >/dev/null
  id="$(bao_root read -field=id "identity/group/name/$name" < /dev/null)"
  alias_name="$(bao_root read -format=json "identity/group/name/$name" < /dev/null | json_get data.alias.name)"
  if [ "$alias_name" != "$alias" ]; then
    bao_root write identity/group-alias name="$alias" mount_accessor="$ACC" canonical_id="$id" < /dev/null >/dev/null
  fi
}

# 4. One policy, external group and alias per owner group.
for g in "${groups[@]}"; do
  sed "s/__GROUP__/$g/g" "$POLICIES/connections-group.hcl" | bao_root policy write "connections-group-$g" - >/dev/null
  group "owner-$g" "connections-group-$g" "$g"
  echo "› owner group $g: group owner-$g, alias $g, policy connections-group-$g"
done

# 5. The administrators: managed connections are write-only for them.
group platform-admins connections-admin "$ADMIN_GROUP"
echo "› admin group $ADMIN_GROUP: group platform-admins, policy connections-admin"

# 6. Break-glass: an administrator may read a group value in an emergency, through a sign-in role that only
# a token issued to Nova can use (bound claim azp), valid for 15 minutes, every use audited (decision D27).
bao_root policy write connections-breakglass - < "$POLICIES/connections-breakglass.hcl" >/dev/null
sed "s/__ADMIN_GROUP__/$ADMIN_GROUP/" "$POLICIES/breakglass-role.json" | bao_root write auth/jwt/role/breakglass - >/dev/null
echo "› break-glass: role breakglass (token issued to Nova, member of $ADMIN_GROUP, 15 minutes), policy connections-breakglass"

echo "openbao-connections: OK — owner groups: ${groups[*]:-none}"
