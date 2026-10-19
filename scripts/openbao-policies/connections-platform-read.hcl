# Platform-run code (the secret sync for catalogs, the connection test) reads managed connections, and only those.
path "secret/data/connections/managed/*" {
  capabilities = ["read"]
}
