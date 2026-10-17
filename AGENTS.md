# AGENTS.md — stardelt-platform

Deployment repo for stardelt: Helm values, manifests and install scripts that bring
the platform up on any conformant Kubernetes cluster. No charts are vendored — the
install is pinned upstream charts + this repo's values (master spec §6).

## Read first

- `../stardelt-docs/docs/design/master-spec.md` — canonical spec (published at
  https://stardelt.io); when documents disagree, it wins.
- `../stardelt-docs/docs/design/execution-plan.md` + `gap-decisions.md` — work packages
  and decisions D8–D16.
- `../stardelt-docs/docs/architecture/licenses.md` — license policy.

The running development environment is the Hetzner k3s cluster
(`alpha.dev.stardelt.io`), provisioned by `dev/hetzner-k3s/` (`make dev-up`, needs
`HCLOUD_TOKEN`). `kubectl`'s current-context selects the target cluster — pin it.

## Layout

- `Makefile` — single source of truth: chart versions pinned as `<COMPONENT>_VERSION`
  (Renovate updates them via `renovate.json`) and every install target.
- `helm-values/` — one values file per chart; `helm-values/slim/` = small-node overrides.
- `manifests/` — CNPG Postgres, Lakekeeper bootstrap, Nova deployment, S3 cred templates.
- `scripts/` — `check-deps.sh` (`make deps`), `lint.sh` (`make lint`), port-forwards.
- `dev/` — Hetzner k3s provisioning, playground ingress/DNS, `ghcr-pull-secret.sh`.
- `images/superset/` — Superset image (+psycopg2, Trino driver).

## Install / lint

```bash
make deps               # verify docker, kubectl, helm
make lint               # bash -n every script under scripts/ + dev/ (+ shellcheck if installed)
make install            # full stack
make install-core       # storage+catalog+query+Nova; SLIM=1 for 8 GB nodes (cx33)
make install-notebooks  # JupyterHub
make pf                 # port-forwards to in-cluster services
make uninstall          # reverse-order teardown (PVCs intentionally left in place)
make dev-up / dev-down / dev-dns
```

CI (`.github/workflows/ci.yml`): yamllint on `helm-values/` + `manifests/`,
`jq -e renovate.json`, `make lint`, and `helm template` for each chart with its values.

## Conventions

- **PR-only.** Never push to `main`; branch off `origin/main` and keep PRs small.
- **License policy: OSI-permissive only.** The single documented exception is OpenBao
  (MPL-2.0) — see `../stardelt-docs/docs/architecture/licenses.md`.
- Chart bumps arrive as Renovate PRs; README tables and `ci.yml` carry hand-maintained
  copies of the pins — keep them in sync.
- Read the master spec first; never add a component without a contract and a license.

## Gotchas

- Images are `ghcr.io/stardelt/*` and private: create the `ghcr-creds` pull secret with
  `./dev/ghcr-pull-secret.sh` (needs `gh` logged in with `write:packages`).
- `make install` needs the `stardelt-s3-creds` Secret (template:
  `manifests/s3-credentials.example.yaml`); `install-core` applies the dev secret itself.
- `SLIM=1` adds `-f helm-values/slim/trino.yaml` (install-core only).
