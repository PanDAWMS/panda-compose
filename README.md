# panda-compose

A self-contained Docker Compose stack for running a local [PanDA](https://pandawms.org) workload management
system. Designed for development and CI testing of tools that integrate with
[PanDA](https://github.com/PanDAWMS/), such as CI executors, workflow managers, and custom Harvester plugins.

This repository mirrors the component set of
[panda-k8s](https://github.com/PanDAWMS/panda-k8s) but expressed as a single
`docker-compose.yml`, using the same upstream container images.

## Stack components

| Service | Image | Purpose |
|---|---|---|
| `postgres` | `ghcr.io/pandawms/panda-database:latest` | PanDA + JEDI database (postgres with pre-installed schema) |
| `activemq` | `ghcr.io/pandawms/panda-activemq:latest` | Message broker (STOMP/OpenWire) |
| `panda-server` | `ghcr.io/pandawms/panda-server:latest` | PanDA REST API + Apache httpd |
| `mariadb` | `bitnami/mariadb:latest` | Harvester database |
| `harvester` | `ghcr.io/hsf/harvester:latest` | Resource-facing pilot submission service |

Service startup order: `postgres` + `activemq` + `mariadb` → `panda-server` → `harvester`

## Quick start

```bash
# 1. Clone and enter the repository
git clone https://github.com/PanDAWMS/panda-compose.git
cd panda-compose

# 2. Create your environment file (edit secrets as needed)
cp .env.example .env

# 3. Start the stack
docker compose up -d

# 4. Wait for the server to become healthy
./scripts/healthcheck.sh

# 5. Register the local compute queue
./scripts/setup-queue.sh
```

The PanDA server is then accessible at:
- HTTP:  `http://localhost:25080/server/panda`
- HTTPS: `https://localhost:25443/server/panda`

The ActiveMQ web console is at `http://localhost:8161/admin/` (admin/admin).

## Configuration

### Environment variables

Copy `.env.example` to `.env` and adjust the values. The most important variables are:

| Variable | Default | Description |
|---|---|---|
| `PANDA_DB_PASSWORD` | `panda_secret` | PostgreSQL password for PanDA |
| `PANDA_ACTIVEMQ_PASSWD_panda` | `panda_mq_secret` | ActiveMQ password for PanDA |
| `PANDA_AUTH` | `None` | Authentication type (`None` = no-auth dev mode, `oidc` for token auth) |
| `HARVESTER_DB_PASSWORD` | `harvester_secret` | MariaDB password for Harvester |

### Config files

Static configuration is mounted read-only into the containers:

| File | Container path | Purpose |
|---|---|---|
| `config/panda/panda_common.cfg` | `/etc/panda/panda_common.cfg` | Logging |
| `config/panda/panda_server.cfg` | `/etc/panda/panda_server.cfg` | PanDA server |
| `config/panda/panda_jedi.cfg` | `/etc/panda/panda_jedi.cfg` | JEDI daemon |
| `config/harvester/panda_harvester.cfg` | `/etc/harvester/panda_harvester.cfg` | Harvester main config |
| `config/harvester/panda_queues.cfg` | `/etc/harvester/panda_queues.cfg` | Compute queue definitions |

The default queue `PANDA_COMPOSE_LOCAL` uses Harvester's `DockerSubmitter` — jobs run
as Docker containers on the host Docker daemon. The default container image is
`alpine:latest`; override per job with `--container IMAGE`.

## Relation to panda-k8s

This repository intentionally reuses the same container images and environment variable
names as [panda-k8s](https://github.com/PanDAWMS/panda-k8s). If you need a production-
grade deployment, follow the panda-k8s Helm chart instructions instead.

## Developing against the PanDA stack

Point your tool's PanDA URL at `http://localhost:25080/server/panda` and use the
`PANDA_COMPOSE_LOCAL` queue name. The dev stack uses no-auth mode (`PANDA_AUTH=None`),
so no token or certificate is required for local development.

## Submitting and managing jobs

The `scripts/` directory contains three Python wrapper scripts that talk to the PanDA
REST API via [panda-client](https://pypi.org/project/panda-client/).

### Prerequisites

```bash
pip install panda-client
```

The scripts read the server URL from environment variables (the dev-stack defaults are
already baked in, so the exports below are only needed if you changed the ports):

```bash
export PANDA_URL=http://localhost:25080/server/panda
export PANDA_URL_SSL=http://localhost:25080/server/panda
export X509_USER_PROXY=/dev/null   # suppress grid-proxy noise in the dev stack
```

### Submit a job

```bash
JOB_ID=$(python3 scripts/pandajob-submit \
    --site PANDA_COMPOSE_LOCAL \
    --transformation sh \
    --params "-c 'echo hello'" \
    --name  my-test-job)
echo "Submitted PanDA job $JOB_ID"
```

| Option | Description |
|---|---|
| `--site SITE` | PanDA compute site / queue name (e.g. `TEST_SITE`, `PANDA_COMPOSE_LOCAL`) |
| `--transformation PATH` | Executable to run inside the worker container |
| `--params STRING` | Arguments passed to the transformation (default: `""`) |
| `--container IMAGE` | Docker image for the job worker (overrides queue default `alpine:latest`) |
| `--script PATH` | Script path (must be accessible inside the worker container) |
| `--name NAME` | Human-readable job name (default: `panda-compose-job`) |
| `--cores N` | CPU cores requested (default: 1) |
| `--memory MB` | Memory in MB (default: 2000) |
| `--walltime S` | Wall-clock limit in seconds (default: 3600) |

On success a single integer job ID is printed to stdout.

### Job lifecycle

Jobs submitted to `PANDA_COMPOSE_LOCAL` run end-to-end through the full PanDA stack:

```
defined → activated → sent → starting → running → transferring → finished
```

Harvester picks up activated jobs (~30 s), launches them as Docker containers
on the host Docker daemon, and reports the result back to PanDA server.
A trivial job typically completes in 1–2 minutes. The job reaches `finished`
status once the adder daemon has processed the job output report.

### Query job status

```bash
python3 scripts/pandajob-status $JOB_ID
```

Prints a JSON object to stdout:

```json
{
  "jobID": 7,
  "jobStatus": "finished",
  "exeErrorCode": 0,
  "exeErrorDiag": "",
  "pilotErrorCode": 0,
  "pilotErrorDiag": "",
  "taskBufferErrorCode": 0,
  "taskBufferErrorDiag": ""
}
```

Known `jobStatus` values: `defined`, `waiting`, `assigned`, `activated`, `sent`,
`starting`, `running`, `merging`, `transferring`, `finished`, `failed`, `cancelled`.

### Cancel a job

```bash
python3 scripts/pandajob-kill $JOB_ID
```

Exits 0 even if the job is already in a terminal state.

## CI

A GitHub Actions smoke-test workflow (`.github/workflows/ci.yml`) starts the full stack
on every push and PR, submits a job in a Docker container, and polls until it reaches
`finished`.
