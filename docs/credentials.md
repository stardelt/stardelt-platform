# S3 credentials (generated)

Part of the [stardelt-platform](../README.md) manual.

All components that touch object storage read credentials from the `stardelt-s3-creds` Secret.
`make install` and `make install-core` generate it on the first run (`scripts/s3-secrets.sh`:
a random key pair, also written to `seaweedfs-s3-config` for the SeaweedFS gateway) and never
overwrite an existing one. To bring your own, create **both** Secrets before installing;
`manifests/s3-credentials.example.yaml` shows the first, and `seaweedfs_s3_config` is
`{"identities":[{"name":"stardelt","credentials":[{"accessKey":"…","secretKey":"…"}],"actions":["Admin","Read","Write"]}]}`.

The object store also ships its own web UI (buckets, users and policies, a file browser). It is
**for cluster administrators only**, reached with `make seaweedfs-admin` (a port-forward to
`http://127.0.0.1:23646`; the login is the generated Secret `seaweedfs-admin-ui`, never printed). It
has no ingress — and none may be added — because it can change storage identities and read every
object, so it is exactly as sensitive as `kubectl`. Normal users do not get raw storage access; they
get the governed *Volumes* view in Nova (later).

---

# Airflow and Superset credentials

Neither values file contains a secret. `scripts/app-secrets.sh` generates them on the
cluster and every install path runs it first (`make install`, `make chart-install`);
`make install-core` does not need it. It is idempotent — a Secret that already exists is
left untouched, so re-running an install never rotates a key under a running stack.

| Secret | Keys | Read by |
|---|---|---|
| `airflow-fernet-key` | `fernet-key` | `fernetKeySecretName` |
| `airflow-webserver-key` | `webserver-secret-key`, `api-secret-key` | `webserverSecretKeySecretName` (Airflow <3) and `apiSecretKeySecretName` (Airflow 3) |
| `airflow-jwt-secret` | `jwt-secret` | `jwtSecretName` |
| `airflow-admin` | `username`, `password` | create-user Job env → `airflow users create` |
| `superset-secret-key` | `secret-key` | `SUPERSET_SECRET_KEY` via `extraEnvRaw` |
| `superset-admin` | `username`, `password`, `firstname`, `lastname`, `email` | Superset init Job (password) |

The Airflow chart has no Secret reference for `createUserJob.defaultUser` and the Superset
chart has no `supersetSecretKeySecretName` (its `extraSecretEnv` writes literals), so both
values files use the charts' next-smallest hooks instead: `createUserJob.env` plus custom
`args`, and `extraEnvRaw` plus a copy of the default `init.initscript` that reads the
password from the environment. Usernames and profile fields stay in values; only
credentials come from Secrets.

The Secrets carry `app.kubernetes.io/part-of=stardelt` and belong to no Helm release, so
`make uninstall` / `helm uninstall` keep them (like the PVCs). Read one back deliberately —
the script never prints a value:

```sh
kubectl -n stardelt get secret airflow-admin -o jsonpath='{.data.password}' | base64 -d
kubectl -n stardelt get secret airflow-fernet-key -o jsonpath='{.data}' | jq 'keys'
```

To rotate, delete the Secret and re-run the step — `NAMESPACE=stardelt bash
scripts/app-secrets.sh` (or the next `make install`). Two things to know:

- **The fernet key is not like the others.** Rotating `airflow-fernet-key` makes every
  connection Airflow stored encrypted in its metadata database undecryptable; the stored
  credentials have to be re-entered. Rotating the API/JWT/session keys only ends sessions
  (Superset users get logged out).
- **The Airflow create-user Job only creates the user.** Changing an existing user's
  password is Airflow CLI work, not a Secret edit. And because Job specs are immutable,
  delete the two Airflow Jobs before the first upgrade that carries this change:
  `kubectl -n stardelt delete job airflow-create-user airflow-run-airflow-migrations`.

---
