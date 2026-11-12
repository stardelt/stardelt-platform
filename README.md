<img src="https://raw.githubusercontent.com/stardelt/.github/main/profile/logo-wordmark.svg" alt="stardelt" height="56" />

# stardelt-platform

**Install the open-source data platform you actually own, on any Kubernetes cluster, with one command.**

SQL over Iceberg tables, notebooks, scheduled pipelines and dashboards behind one sign-in, with table permissions by group. Permissive licences only, no phone-home, no licence server.

![Nova, the stardelt interface: the catalog of a team's tables](https://stardelt.io/img/nova/catalog.png)

## Try it first

- **[Try the demo](https://stardelt.io/demo/)**: a running instance, sign in with `demo` / `demo`. Nothing to install.
- **[Quickstart](https://stardelt.io/docs/getting-started/quickstart)**: install the core, load a file, query it.

## Install

You need a Kubernetes cluster with one real node (8 GB of memory or more), `kubectl` 1.28+, `helm` 3.18+ and, for sign-in, `cert-manager` 1.15+.

```sh
git clone https://github.com/stardelt/stardelt-platform
cd stardelt-platform
make platform-dry-run                                  # what would happen, nothing is written
IDENTITY=1 BASE_DOMAIN=data.example.com make platform  # install; safe to run twice
```

`make upgrade` moves an installed platform to this checkout. Details, options and what to do when a step fails: [docs/install.md](docs/install.md).

## What it installs

| Part | Component |
|---|---|
| Object storage | SeaweedFS, or your own S3 |
| Table catalog | Lakekeeper (Iceberg REST) with OpenFGA permissions |
| Query engine | Trino |
| Interface and API | Nova |
| Sign-in | Keycloak, or your own OpenID Connect provider |
| Notebooks | JupyterHub |
| Pipelines | Airflow, driven by `Pipeline` resources |
| Dashboards | Superset |

## The manual

| Page | What it covers |
|---|---|
| [Install, upgrade, remove](docs/install.md) | Prerequisites, the runbook, the Helm chart |
| [Identity](docs/identity.md) | The platform IdP, Trino sign-in, users and groups |
| [Catalogs and permissions](docs/catalogs.md) | Catalogs, grants, the permission bridge |
| [Notebooks](docs/notebooks.md) | Published notebooks and notebook tasks |
| [Spark](docs/spark.md) | Heavy compute on the same tables |
| [Backups](docs/backups.md) | What is backed up and how to restore |
| [Credentials](docs/credentials.md) | Generated secrets and where they live |
| [Development](docs/development.md) | Make targets, layout, versions, images |

The product documentation is at **[stardelt.io](https://stardelt.io)**.

## Status

stardelt runs end to end, but there is no tagged release yet: resources and APIs can still change. See the [roadmap](https://stardelt.io/docs/roadmap).

## Contribute

Open an issue here for anything about installing and running the platform. Read [how to contribute](https://stardelt.io/docs/developer) first.

## Licence

Apache 2.0. Every component carries a permissive licence; see the [licence policy](https://stardelt.io/docs/architecture/licenses).
