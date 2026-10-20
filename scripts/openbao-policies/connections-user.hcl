# A person's own connections: create, read, update, delete below their own prefix, nothing else.
# __ACCESSOR__ is the mount accessor of the jwt auth method; the alias name is the token's `sub`.
path "secret/data/connections/user/{{identity.entity.aliases.__ACCESSOR__.name}}/*" {
  capabilities = ["create", "update", "read", "delete"]
}
path "secret/metadata/connections/user/{{identity.entity.aliases.__ACCESSOR__.name}}/*" {
  # create/update are required: Nova writes the connection's non-secret metadata
  # (type, config, key names) next to the value, so a create or rotate touches it too.
  capabilities = ["create", "update", "list", "read", "delete"]
}
path "secret/metadata/connections/user/{{identity.entity.aliases.__ACCESSOR__.name}}" {
  capabilities = ["list"]
}
