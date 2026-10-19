# The connections of one owner group (__GROUP__): every member may create, read, update, delete and list them.
path "secret/data/connections/group/__GROUP__/*" {
  capabilities = ["create", "update", "read", "delete"]
}
path "secret/metadata/connections/group/__GROUP__/*" {
  capabilities = ["list", "read", "delete"]
}
path "secret/metadata/connections/group/__GROUP__" {
  capabilities = ["list"]
}
