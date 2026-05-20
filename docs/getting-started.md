# Quick Start

This page walks you through bringing up the full PanDA stack and submitting your first job.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) 20.10+
- [Docker Compose](https://docs.docker.com/compose/install/) v2.x (the `docker compose` plugin)
- ~4 GB free RAM for all containers

## 1. Clone the repository

```bash
git clone https://github.com/PanDAWMS/panda-compose.git
cd panda-compose
```

## 2. Configure environment

```bash
cp .env.example .env
```

The defaults in `.env.example` are suitable for local development. Edit `.env` if you
need to change ports or secrets. See [Configuration](configuration.md) for all variables.

## 3. Start the stack

```bash
docker compose up -d
```

Docker Compose pulls all images on the first run. Startup takes 1–2 minutes.

## 4. Wait for the server

```bash
./scripts/healthcheck.sh
```

This polls `http://localhost:25080/server/panda/isAlive` until it returns `alive=yes`
(default timeout: 120 seconds). JEDI becomes healthy ~30 s after the server.

## 5. Submit a test job

```bash
pip install panda-client

export PANDA_URL=http://localhost:25080/server/panda
export PANDA_URL_SSL=http://localhost:25080/server/panda
export X509_USER_PROXY=/dev/null

JOB_ID=$(python3 scripts/pandajob-submit \
    --site  PANDA_COMPOSE_LOCAL \
    --transformation /bin/echo \
    --params "hello from panda-compose" \
    --name  my-first-job)
echo "Job ID: $JOB_ID"
```

## 6. Track the job

```bash
# Poll until finished
while true; do
    STATUS=$(python3 scripts/pandajob-status "$JOB_ID" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['jobStatus'])")
    echo "Status: $STATUS"
    [[ "$STATUS" == "finished" || "$STATUS" == "failed" ]] && break
    sleep 15
done
```

A job submitted with `/bin/echo` typically reaches `finished` within 2–8 minutes.
See [Job Management](job-management.md) for all status values and the full lifecycle.

## 7. Tear down

```bash
docker compose down -v   # -v removes named volumes (DB data)
```

## Troubleshooting

**Stack fails to start:**
Check individual service logs:
```bash
docker compose logs panda-server --tail=50
docker compose logs panda-jedi   --tail=50
docker compose logs harvester    --tail=50
```

**Job stuck at `defined`:**
JEDI needs a few seconds to start its activator thread. Wait 60 s and poll again.
If the job stays at `defined` beyond 2 minutes, check JEDI logs:
```bash
docker compose logs panda-jedi --tail=100
```

**ActiveMQ web console:**
`http://localhost:8161/admin/` (credentials: `admin` / `admin`)
