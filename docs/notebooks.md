# Published notebooks (versioned bucket)

Part of the [stardelt-platform](../README.md) manual.

Published notebooks live in the object store's `notebooks` bucket, with **versioning enabled**.
Every publish is an immutable object version, and a scheduled notebook pins the version a person
approved: a later publish, a delete or an S3-gateway restart does not change the bytes a pinned
version returns (measured in spike #268). `make notebooks-bucket` — also run by `make install` —
creates the bucket with the platform identity and turns versioning on. It is idempotent, and it
prints only the bucket and its versioning state:

```sh
$ make notebooks-bucket
› bucket notebooks: versioning Enabled
› bucket notebooks: run copies kept 30 days
```

An executed copy under `_runs/` expires after 30 days (`RUN_COPY_DAYS`); published notebooks are
never expired.

Nova writes to that bucket with `NOVA_S3_URL`, `NOVA_S3_ACCESS_KEY` and `NOVA_S3_SECRET_KEY`
(the key pair in Secret `stardelt-s3-creds`, the same identity the object store and every other
consumer already use — no new identity) and `NOVA_S3_NOTEBOOK_BUCKET=notebooks`. A notebook may
call Nova with the token it already holds: the hub token carries audience `nova` through the
`aud-nova` mapper on the `jupyterhub` and `stardelt-dev` clients (`make sync-nova-audience`, run by
`make install-identity`). The same tokens carry audience `lakekeeper` through `aud-lakekeeper`
(`make sync-catalog-audience`), which is what `stardelt.spark()` needs for the catalog. The publish,
list and version routes themselves are in stardelt-nova#225; this repository creates the bucket and
wires the identity.

---

# Notebook tasks

A notebook runs on a schedule as a pod of its own, built by the pipeline DAG through a
`KubernetesPodOperator`. It cannot be the Airflow task pod: the notebook image has no Airflow in
it, so a pod that swaps in that image exits 127 before the task code runs (stardelt-demos#25). The
install gives the DAG four variables in the Airflow `env` list in `helm-values/airflow.yaml` —
they reach every Airflow container and every spawned task pod, the same way the `PIPELINE_*`
credentials for `sql` tasks do:

| Variable | Value | What it is for |
|---|---|---|
| `PIPELINE_NOTEBOOK_IMAGE` | `ghcr.io/stardelt/jupyter-singleuser:dev@sha256:…` | the task pod's image — the same digest as `singleuser.image.tag` |
| `PIPELINE_NOTEBOOK_BUCKET` | `notebooks` | the versioned bucket the task reads and writes |
| `PIPELINE_NOTEBOOK_S3_CONN` | `stardelt_s3` | the Airflow connection that pre-signs the two URLs |
| `PIPELINE_NOTEBOOK_TRINO_CA_SECRET` | `trino-ca` | the Secret the pod mounts to verify the query engine |

`PIPELINE_NOTEBOOK_IMAGE` and `singleuser.image.tag` must name the same digest: a task pod on the
single-user image of an older merge has no papermill and fails inside the pod, so
`scripts/check-notebook-image-pin.sh` (run by `make lint`, and therefore by CI) fails the build
and prints the three digests when they drift. Bump all three together, as described under
[Jupyter single-user image](development.md#jupyter-single-user-image).

Objects in that bucket:

- `notebooks/<ownerGroup>/<name>.ipynb` — the published notebook. A task pins the object
  **version** it approved, not the name, so a later publish or delete does not change the bytes
  the run executes.
- `_runs/<ownerGroup>/<pipeline>/<run_id>/<task>.ipynb` — the executed copy, so the output a run
  produced is readable next to the input it started from. Group names start with a letter or a
  digit, which is why `_runs` cannot collide with one. It is kept for 30 days, then the bucket's
  lifecycle rule removes it.

**The pod holds no storage credential.** An S3 key scoped to `notebooks` can still read every
other bucket through `CopyObject` (spike #272), and a notebook is user code: it could send the
key anywhere. So the pod gets two pre-signed URLs instead — one GET for the pinned object
version, one PUT for the output key — signed by the DAG in the worker, which holds
`stardelt_s3`. What the pod does get is the pipeline principal's client credentials
(`PIPELINE_CLIENT_ID` / `PIPELINE_CLIENT_SECRET`, the same variables a `sql` task uses), so the
notebook's queries carry its own token.

**Who may run what.** A notebook runs as the pipeline's principal — `spec.runAs`, or the
platform default `pipeline-runner` when the Pipeline names none — never as the person who
scheduled it. The catalog grants that principal holds decide what the notebook can read, write
and create, and the run leaves the same audit trail as any other pipeline task. *Scheduling* is a
write to the `Pipeline` resource, so whoever may write it decides when the notebook runs; a
`runAs` principal belongs to an owner group (`ServicePrincipal.spec.ownerGroup`), which is what
the run's data access follows.

---
