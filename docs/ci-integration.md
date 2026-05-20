# CI Integration

panda-compose is designed to be used as a service in GitHub Actions workflows,
allowing you to test tools that submit jobs to PanDA against a real (local) server.

## Using the setup-panda action

The simplest way to integrate PanDA in your CI is with the reusable composite action:

```yaml
- name: Setup PanDA
  uses: PanDAWMS/panda-compose@main
```

This single step starts the full stack and waits for it to be healthy. See
[Setup PanDA Action](setup-panda-action.md) for the full reference including inputs,
outputs, environment variables, and the required teardown step.

## Built-in smoke test

The repository's own CI workflow (`.github/workflows/ci.yml`) exercises the full
stack on every push and pull request:

1. Start the stack with `docker compose up -d`
2. Wait for `panda-server` to become healthy (up to 5 min)
3. Wait for `panda-jedi` to become healthy (up to 2 min)
4. Submit a job in a `python:3.12-alpine` container (exercises per-job `--container` selection)
5. Poll until the job reaches `finished` (up to 10 min)
6. Tear down with `docker compose down -v`

## Using panda-compose in your own workflow

### Basic pattern

Add panda-compose as a step in your GitHub Actions job. The stack must be healthy
before your tool submits jobs.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout your repository
        uses: actions/checkout@v4

      - name: Checkout panda-compose
        uses: actions/checkout@v4
        with:
          repository: PanDAWMS/panda-compose
          path: panda-compose

      - name: Start PanDA stack
        working-directory: panda-compose
        run: |
          cp .env.example .env
          docker compose up -d

      - name: Wait for PanDA server
        working-directory: panda-compose
        run: ./scripts/healthcheck.sh 300

      - name: Wait for JEDI
        run: |
          echo "Waiting for JEDI (up to 120s)..."
          DEADLINE=$((SECONDS + 120))
          while [[ $SECONDS -lt $DEADLINE ]]; do
            STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
              panda-compose-panda-jedi-1 2>/dev/null || echo unknown)
            [[ "$STATUS" == "healthy" ]] && echo "JEDI healthy" && break
            sleep 10
          done
          [[ "$STATUS" == "healthy" ]] || { echo "JEDI not healthy"; exit 1; }

      # ── Your integration tests go here ─────────────────────────────
      - name: Run your tool against PanDA
        env:
          PANDA_URL: http://localhost:25080/server/panda
          PANDA_URL_SSL: http://localhost:25080/server/panda
          X509_USER_PROXY: /dev/null
        run: |
          # Replace with your actual tool invocation
          pip install panda-client
          JOB_ID=$(python3 panda-compose/scripts/pandajob-submit \
            --site PANDA_COMPOSE_LOCAL \
            --transformation /bin/echo \
            --params "integration test")
          echo "Job ID: $JOB_ID"
          # ... poll for completion ...

      - name: Tear down
        if: always()
        working-directory: panda-compose
        run: docker compose down -v
```

### Using a specific panda-compose version

Pin to a release tag or commit SHA for reproducibility:

```yaml
      - name: Checkout panda-compose
        uses: actions/checkout@v4
        with:
          repository: PanDAWMS/panda-compose
          ref: v1.0.0          # or a commit SHA
          path: panda-compose
```

### Custom environment

Override defaults by writing a custom `.env` before `docker compose up -d`:

```yaml
      - name: Start PanDA stack (custom config)
        working-directory: panda-compose
        run: |
          cat > .env <<'EOF'
          PANDA_DB_PASSWORD=my_secret
          HARVESTER_DB_PASSWORD=my_other_secret
          EOF
          docker compose up -d
```

### Submitting a custom script

Use `--script` to run a host-side shell script inside the worker container.
The script content is read from the host filesystem and passed inline to `sh -c`;
no volume mount or `docker cp` is needed.

```yaml
      - name: Submit with custom script
        env:
          PANDA_URL: http://localhost:25080/server/panda
          PANDA_URL_SSL: http://localhost:25080/server/panda
          X509_USER_PROXY: /dev/null
        run: |
          JOB_ID=$(python3 panda-compose/scripts/pandajob-submit \
            --site PANDA_COMPOSE_LOCAL \
            --script my_test_script.sh \
            --container python:3.12-alpine \
            --name my-custom-job)
          echo "Submitted job $JOB_ID"
```

The `--container IMAGE` flag selects the Docker image the script runs in
(default: `alpine:latest`).  Any image that provides `sh` works; the script
content is passed as `sh -c '<content>'`.

## Timing guidance

| Workflow timeout | Recommended value |
|---|---|
| Stack startup (healthcheck) | 5 min |
| JEDI startup | 2 min |
| Job completion poll | 10 min |
| **Total `timeout-minutes`** | **≥ 25** |

The dominant latency is the adder daemon loop (~6 min) that moves jobs from
`transferring` to `finished`. Allow at least 10 minutes for the poll.

## Environment variables for panda-client

```bash
PANDA_URL=http://localhost:25080/server/panda      # HTTP REST API
PANDA_URL_SSL=http://localhost:25080/server/panda  # same (no TLS in dev)
X509_USER_PROXY=/dev/null                          # suppress grid-proxy warnings
```

The dev stack runs with `PANDA_AUTH=None`, so no authentication credentials
are required.

## Debugging CI failures

**Job stuck at `defined`:**
JEDI was not healthy before the job was submitted. Add a JEDI health wait step
(see pattern above) and ensure `timeout-minutes` is large enough.

**Job reached `failed` (exit code 127):**
The transformation binary does not exist inside the worker container image.
Use `/bin/echo`, `/bin/true`, or switch to `--script` with an appropriate `--container IMAGE`.

**`docker inspect` returns `not_found`:**
The container name `panda-compose-panda-jedi-1` depends on the Compose project name,
which defaults to the directory name (`panda-compose`). If you cloned to a different
directory, adjust the container name accordingly, or use:
```bash
docker compose -f panda-compose/docker-compose.yml ps
```

**Stack logs:**
```bash
docker compose -f panda-compose/docker-compose.yml logs --tail=100
```
