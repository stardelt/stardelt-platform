# The connections of one owner group (__GROUP__): every member may create, read, update, delete and list them.
path "secret/data/connections/group/__GROUP__/*" {
  capabilities = ["create", "update", "read", "delete"]
}
path "secret/metadata/connections/group/__GROUP__/*" {
  # See connections-user.hcl: Nova writes metadata next to the value on create and rotate.
  capabilities = ["create", "update", "list", "read", "delete"]
}
path "secret/metadata/connections/group/__GROUP__" {
  capabilities = ["list"]
}
