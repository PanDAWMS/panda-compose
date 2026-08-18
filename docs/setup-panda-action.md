# setup-panda action

The `PanDAWMS/panda-compose` repository is itself a reusable
[composite GitHub Action](https://docs.github.com/en/actions/creating-actions/creating-a-composite-action).
Referencing it with `uses: PanDAWMS/panda-compose@main` (or a pinned tag) starts the full
PanDA stack and waits for it to become healthy — in a single step.

## Usage

```yaml
- name: Setup PanDA
  uses: PanDAWMS/panda-compose@main
```

Or pin to a specific release:

```yaml
- name: Setup PanDA
  uses: PanDAWMS/panda-compose@v1
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `ref` | `main` | Git ref (branch, tag, SHA) of `PanDAWMS/panda-compose` to check out. Useful when you need a specific version of the stack config. |
| `timeout` | `300` | Seconds to wait for the PanDA server to become healthy. |
| `project-name` | `panda-compose` | Docker Compose project name. Determines container name prefixes (e.g. `panda-compose-panda-jedi-1`). Change only if the default conflicts with other services on the runner. |
| `env-overrides` | `""` | Newline-separated `KEY=VALUE` pairs appended to `.env` before the stack starts. Use this to override environment-based settings such as default passwords; published host ports remain fixed by the compose file. |

## Outputs

| Output | Value | Description |
|---|---|---|
| `panda-url` | `http://localhost:25080/server/panda` | HTTP URL of the PanDA REST API |
| `panda-url-ssl` | `http://localhost:25080/server/panda` | SSL URL (same as HTTP in the dev stack) |

## Environment variables set

The action writes the following into `$GITHUB_ENV` so all subsequent steps see them automatically:

| Variable | Value |
|---|---|
| `PANDA_URL` | `http://localhost:25080/server/panda` |
| `PANDA_URL_SSL` | `http://localhost:25080/server/panda` |
| `X509_USER_PROXY` | `/dev/null` (suppresses grid-proxy warnings) |
| `PANDA_COMPOSE_PROJECT` | the `project-name` input value |
| `PANDA_COMPOSE_DIR` | path to the checked-out `PanDAWMS/panda-compose` tree (`__panda_compose__`) |

## Teardown

Composite actions have no automatic `post:` step. Add a teardown step with `if: always()`:

```yaml
- name: Tear down PanDA stack
  if: always()
  run: |
    docker compose -f $PANDA_COMPOSE_DIR/docker-compose.yml \
      -p $PANDA_COMPOSE_PROJECT down -v
```

## Complete example

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - uses: actions/checkout@v4

      - name: Setup PanDA
        uses: PanDAWMS/panda-compose@main

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install panda-client
        run: pip install panda-client

      - name: Submit and wait for job
        run: |
          JOB_ID=$(python3 $PANDA_COMPOSE_DIR/scripts/pandajob-submit \
            --site PANDA_COMPOSE_LOCAL \
            --transformation /bin/echo \
            --params "hello from ${{ github.repository }}")
          echo "Job ID: $JOB_ID"

          DEADLINE=$((SECONDS + 600))
          while [[ $SECONDS -lt $DEADLINE ]]; do
            STATUS=$(python3 $PANDA_COMPOSE_DIR/scripts/pandajob-status "$JOB_ID" \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['jobStatus'])")
            echo "$(date -u '+%H:%M:%S') $STATUS"
            [[ "$STATUS" == "finished" ]] && break
            [[ "$STATUS" == "failed" || "$STATUS" == "cancelled" ]] && exit 1
            sleep 15
          done
          [[ "$STATUS" == "finished" ]] || { echo "Timed out"; exit 1; }

      - name: Tear down PanDA stack
        if: always()
        run: |
          docker compose -f $PANDA_COMPOSE_DIR/docker-compose.yml \
            -p $PANDA_COMPOSE_PROJECT down -v
```

## Overriding configuration

Use `env-overrides` to change passwords or other settings without modifying `.env.example`:

```yaml
- name: Setup PanDA
  uses: PanDAWMS/panda-compose@main
  with:
    env-overrides: |
      PANDA_DB_PASSWORD=my_custom_secret
      HARVESTER_DB_PASSWORD=my_harvester_secret
```

## Pinning to a specific version

For reproducible CI, pin to a release tag or commit SHA:

```yaml
- uses: PanDAWMS/panda-compose@v1          # semver tag (recommended)
- uses: PanDAWMS/panda-compose@abc1234     # commit SHA (most precise)
```

## Timing

The action blocks until both the PanDA server and JEDI are healthy:

| Phase | Typical duration |
|---|---|
| Stack startup + server healthy | 1–5 min |
| JEDI healthy | +30 s |
| Job `finished` after submission | 2–8 min |
| **Recommended `timeout-minutes`** | **≥ 25** |
