# panda-compose

A self-contained Docker Compose stack for running a local
[PanDA](https://panda-wms.readthedocs.io) workload management system.
Designed for development and CI testing of tools that integrate with PanDA —
such as CI executors, workflow managers, and custom Harvester plugins.

This repository mirrors the component set of
[panda-k8s](https://github.com/PanDAWMS/panda-k8s) but expressed as a single
`docker-compose.yml`, using the same upstream container images.

## Stack components

| Service | Image | Purpose |
|---|---|---|
| `postgres` | `ghcr.io/pandawms/panda-database:latest` | PanDA + JEDI database (PostgreSQL with pre-installed schema) |
| `activemq` | `ghcr.io/pandawms/panda-activemq:latest` | Message broker (STOMP/OpenWire) |
| `panda-server` | `ghcr.io/pandawms/panda-server:latest` | PanDA REST API + Apache httpd |
| `panda-jedi` | `ghcr.io/pandawms/panda-jedi:latest` | JEDI workload management daemon |
| `mariadb` | `mariadb:10.11` | Harvester database |
| `harvester` | `ghcr.io/hsf/harvester:latest` | Resource-facing pilot submission service |

Startup order: `postgres` + `activemq` + `mariadb` → `panda-server` → `init` (one-shot) → `panda-jedi` + `harvester`

## Quick start

```bash
git clone https://github.com/PanDAWMS/panda-compose.git
cd panda-compose
cp .env.example .env
docker compose up -d
./scripts/healthcheck.sh
```

The PanDA server is then accessible at `http://localhost:25080/server/panda`.

For full setup instructions see [Quick Start](getting-started.md).

## Project goals

- **Zero external dependencies** — the entire PanDA stack runs on a single machine via Docker Compose.
- **Image parity with production** — uses the same container images as [panda-k8s](https://github.com/PanDAWMS/panda-k8s).
- **End-to-end job execution** — submitted jobs are picked up by Harvester, executed as subprocesses, and reported back as `finished`.
- **CI-ready** — a GitHub Actions smoke test validates the full job lifecycle on every commit.

## Relation to panda-k8s

This repository intentionally reuses the same container images and environment variable
names as [panda-k8s](https://github.com/PanDAWMS/panda-k8s). If you need a production-
grade deployment, follow the panda-k8s Helm chart instructions instead.
