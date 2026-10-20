# Administrators administer connections and never read a value. Managed connections are write-only
# (create and update without read). Every connection of every scope can be listed, inspected by its
# metadata and destroyed (incident response). There is no access to `secret/data/` of group or user
# paths: an administrator can neither read nor plant a value there.
path "secret/data/connections/managed/*" {
  capabilities = ["create", "update"]
}
# Managed connections need their metadata written too (Nova create/rotate). Scoped to
# `managed/` on purpose: an administrator still cannot alter the metadata of a user's or a
# group's connection.
path "secret/metadata/connections/managed/*" {
  capabilities = ["create", "update"]
}
path "secret/metadata/connections/*" {
  capabilities = ["list", "read", "delete"]
}
