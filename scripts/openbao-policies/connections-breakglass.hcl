# Break-glass (decision D27): an administrator may read the value of a GROUP connection in an emergency,
# and nothing else. Never attached to the admin group: it is the token policy of the sign-in role
# `breakglass` only (breakglass-role.json), reachable through Nova's audited endpoint. Personal and
# managed values stay unreadable for everybody.
path "secret/data/connections/group/*" {
  capabilities = ["read"]
}
