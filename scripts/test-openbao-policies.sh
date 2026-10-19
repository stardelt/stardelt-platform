#!/usr/bin/env bash
# Prove the connection policies (scripts/openbao-policies/*.hcl, decision D27) against a throwaway local
# OpenBao in dev mode: no cluster, no network, no real credentials. Needs the `bao` binary
# (OpenBao 2.7.x) on PATH or in $BAO, and openssl and python3.
#
#   bash scripts/test-openbao-policies.sh
#
# People log in with self-signed tokens (a key pair made here); the policies, external groups and
# group aliases are the ones scripts/openbao-connections.sh creates, built from the same files.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BAO="${BAO:-bao}"
for tool in "$BAO" openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test-openbao-policies: $tool not found (OpenBao binaries: https://github.com/openbao/openbao/releases)" >&2; exit 2; }
done

POLICIES="$PWD/scripts/openbao-policies"
ADDR="http://127.0.0.1:${PORT:-18200}"
ROOT=dev-only-root-token                       # a throwaway dev server, not a credential
umask 077
tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

export BAO_ADDR="$ADDR"
"$BAO" server -dev -dev-listen-address="${ADDR#http://}" -dev-root-token-id="$ROOT" >"$tmp/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 40); do "$BAO" status >/dev/null 2>&1 && break; sleep 0.5; done
"$BAO" status >/dev/null 2>&1 || { cat "$tmp/server.log" >&2; echo "test-openbao-policies: the dev server did not start" >&2; exit 1; }
export BAO_TOKEN="$ROOT"

openssl genrsa -out "$tmp/key.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/key.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() { # mint <sub> <groups as JSON list>
  local now h p s; now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  p=$(printf '{"iss":"https://id.test/realms/stardelt","aud":"openbao","sub":"%s","groups":%s,"iat":%d,"nbf":%d,"exp":%d}' \
        "$1" "$2" $((now - 30)) $((now - 30)) $((now + 600)) | b64)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$tmp/key.pem" | b64)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

"$BAO" auth enable jwt >/dev/null
"$BAO" write auth/jwt/config jwt_validation_pubkeys=@"$tmp/pub.pem" bound_issuer=https://id.test/realms/stardelt >/dev/null
ACC=$("$BAO" auth list -format=json | python3 -c 'import json,sys;print(json.load(sys.stdin)["jwt/"]["accessor"])')
"$BAO" write auth/jwt/role/platform-users role_type=jwt bound_audiences=openbao user_claim=sub groups_claim=groups \
  token_policies=connections-user token_ttl=10m >/dev/null

# Policies from the shipped files; the placeholders are the only difference to what the cluster gets.
"$BAO" policy write connections-user - < <(sed "s/__ACCESSOR__/$ACC/g" "$POLICIES/connections-user.hcl") >/dev/null
"$BAO" policy write connections-admin "$POLICIES/connections-admin.hcl" >/dev/null
"$BAO" policy write connections-platform-read "$POLICIES/connections-platform-read.hcl" >/dev/null
external_group() { # external_group <group name in the token> <policy>
  "$BAO" write identity/group name="owner-$1" type=external policies="$2" >/dev/null
  "$BAO" write identity/group-alias name="$1" mount_accessor="$ACC" canonical_id="$("$BAO" read -field=id "identity/group/name/owner-$1")" >/dev/null
}
for g in analytics finance; do
  "$BAO" policy write "connections-group-$g" - < <(sed "s/__GROUP__/$g/g" "$POLICIES/connections-group.hcl") >/dev/null
  external_group "$g" "connections-group-$g"
done
external_group stardelt-admins connections-admin

login() { "$BAO" write -field=token auth/jwt/login role=platform-users jwt="$(mint "$1" "$2")"; }
ALICE=$(login sub-alice '["analytics"]'); BOB=$(login sub-bob '["finance"]'); ADMIN=$(login sub-admin '["stardelt-admins"]')
PLAT=$("$BAO" token create -field=token -policy=connections-platform-read -ttl=10m)

pass=0; fail=0
t() { # t <name> <ok|deny> <token> <bao args...>
  local name=$1 want=$2 tok=$3 got=ok out; shift 3
  out=$(BAO_TOKEN=$tok "$BAO" "$@" 2>&1) || got=deny
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf 'PASS %-52s %s\n' "$name" "$got"
  else fail=$((fail + 1)); printf 'FAIL %-52s wanted %s, got %s: %s\n' "$name" "$want" "$got" "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}
t "alice writes a group secret of hers"        ok   "$ALICE" kv put secret/connections/group/analytics/crm user=u password=p
t "alice reads it back"                        ok   "$ALICE" kv get secret/connections/group/analytics/crm
t "alice lists her group's names"              ok   "$ALICE" kv list secret/connections/group/analytics
t "alice writes into another group"            deny "$ALICE" kv put secret/connections/group/finance/x a=b
t "alice lists another group's names"          deny "$ALICE" kv list secret/connections/group/finance
t "alice writes her personal secret"           ok   "$ALICE" kv put secret/connections/user/sub-alice/pat token=t
t "alice reads her personal secret"            ok   "$ALICE" kv get secret/connections/user/sub-alice/pat
t "bob writes his personal secret"             ok   "$BOB" kv put secret/connections/user/sub-bob/pat token=t
t "alice reads bob's personal secret"          deny "$ALICE" kv get secret/connections/user/sub-bob/pat
t "alice writes into bob's personal path"      deny "$ALICE" kv put secret/connections/user/sub-bob/x a=b
t "alice writes a managed secret"              deny "$ALICE" kv put secret/connections/managed/sftp user=u password=p
t "admin writes a managed secret"              ok   "$ADMIN" kv put secret/connections/managed/sftp user=u password=p
t "admin reads the managed value"              deny "$ADMIN" kv get secret/connections/managed/sftp
t "admin lists managed names"                  ok   "$ADMIN" kv list secret/connections/managed
t "alice reads the managed value"              deny "$ALICE" kv get secret/connections/managed/sftp
t "alice lists managed names"                  deny "$ALICE" kv list secret/connections/managed
t "admin reads a group value"                  deny "$ADMIN" kv get secret/connections/group/analytics/crm
t "admin writes into a group path"             deny "$ADMIN" kv put secret/connections/group/analytics/planted a=b
t "admin reads a personal value"               deny "$ADMIN" kv get secret/connections/user/sub-alice/pat
t "admin writes into a personal path"          deny "$ADMIN" kv put secret/connections/user/sub-alice/planted a=b
t "admin lists a group's names"                ok   "$ADMIN" kv list secret/connections/group/analytics
t "admin reads a group secret's metadata"      ok   "$ADMIN" kv metadata get secret/connections/group/analytics/crm
t "platform reader reads the managed value"    ok   "$PLAT" kv get secret/connections/managed/sftp
t "platform reader reads a group value"        deny "$PLAT" kv get secret/connections/group/analytics/crm
t "platform reader writes a managed value"     deny "$PLAT" kv put secret/connections/managed/x a=b
t "admin destroys a group secret (incident)"   ok   "$ADMIN" kv metadata delete secret/connections/group/analytics/crm
t "alice reads it after it was destroyed"      deny "$ALICE" kv get secret/connections/group/analytics/crm
echo "test-openbao-policies: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
