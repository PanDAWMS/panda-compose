# Configuration

## Environment variables

Copy `.env.example` to `.env` and edit before starting the stack:

```bash
cp .env.example .env
```

The defaults are safe for local development. All variables have built-in fallbacks
in `docker-compose.yml` so the stack starts even without a `.env` file.

### Database

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_PASSWORD` | `postgres_secret` | PostgreSQL superuser password |
| `PANDA_DB_PASSWORD` | `panda_secret` | PostgreSQL password for the `panda` role |
| `PANDA_DB_NAME` | `panda_db` | PostgreSQL database name |
| `RUCIO_DB_USER` | `rucio` | PostgreSQL username for Rucio |
| `RUCIO_DB_PASSWORD` | `secret` | PostgreSQL password for Rucio |
| `RUCIO_DB_NAME` | `rucio` | Rucio database name |

### Messaging

| Variable | Default | Description |
|---|---|---|
| `PANDA_ACTIVEMQ_LIST` | `activemq:61613` | STOMP broker address (host:port) |
| `PANDA_ACTIVEMQ_PASSWD_panda` | `panda_mq_secret` | ActiveMQ password for the `panda` user |
| `PANDA_ACTIVEMQ_PASSWD_jedi` | `jedi_mq_secret` | ActiveMQ password for the `jedi` user |

### PanDA server

| Variable | Default | Description |
|---|---|---|
| `PANDA_AUTH` | `None` | Authentication mode. `None` = no-auth dev mode; `oidc` for OIDC token auth |
| `PANDA_SERVER_CONF_PORT` | `80` | Internal Apache listen port (mapped to host port `25080`) |
| `PANDA_SERVER_CONF_MIN_WORKERS` | `1` | Apache prefork minimum workers |
| `PANDA_SERVER_CONF_MAX_WORKERS` | `4` | Apache prefork maximum workers |
| `PANDA_SERVER_CONF_SERVERNAME` | `localhost` | Apache `ServerName` |

### JEDI task submission

These apply only to the JEDI *task* path (`prun` / `panda_api.submit_task`).
Direct job submission (`scripts/pandajob-submit`) bypasses JEDI and ignores them.

| Variable | Default | Description |
|---|---|---|
| `PANDA_TASK_LABEL` | `test` | `prodSourceLabel` of JEDI tasks; also the seeded work-queue `queue_type`. `[taskrefine]` uses `epic:any`, so any value is refined |

The VO is fixed to `epic` in `config/panda/panda_jedi.cfg` (hardcoded across every
JEDI stage) and is not independently configurable.

`setup-queue.sh` seeds a `jedi_work_queue` row (`queue_function='Resource'`) and
a `global_shares` row for the `epic` VO / `PANDA_TASK_LABEL`; without both, the
TaskRefiner fails with `workqueue is undefined` and the task never leaves
`waiting`.

### Proxies

If you are behind a corporate proxy, set `HTTP_PROXY` and `HTTPS_PROXY` in `.env`.
They are passed through to all services.

## Config files

Static configuration is mounted read-only into the containers. Edit these files to
customize service behavior; restart the affected container to apply changes.

| File | Mounted in | Purpose |
|---|---|---|
| `config/panda/panda_common.cfg` | `panda-server`, `panda-jedi`, `harvester` | Logging |
| `config/panda/panda_server.cfg` | `panda-server` | PanDA server settings |
| `config/panda/panda_jedi.cfg` | `panda-jedi` | JEDI daemon settings |
| `config/harvester/panda_harvester.cfg` | `harvester` | Harvester main config |
| `config/harvester/panda_queues.template.json` | `harvester` | Queue template; concrete queues are rendered from `PANDA_QUEUES` |

### `config/panda/panda_server.cfg` highlights

```ini
[daemon]
# Plugin called by the setupper daemon before job activation.
# Must match the 4-argument signature: (taskBuffer, jobs, logger, **params).
setupper_plugins = any:pandaserver.dataservice.setupper_dummy_plugin:SetupperDummyPlugin

# Plugin called by the adder daemon after job output processing.
# Must match the 2-argument signature: (taskBuffer,).
adder_plugins    = any:pandaserver.dataservice.adder_dummy_plugin:AdderDummyPlugin
```

Both plugins are no-ops (no real data management). They are required in the no-Rucio
configuration to prevent the setupper and adder daemons from failing on every job.

### `config/harvester/panda_queues.template.json` — queue template

The queue configuration is JSON. `panda_queues.template.json` defines the shared
template queue; at harvester startup `scripts/render-panda-queues.py` expands the
`PANDA_QUEUES` env list into `panda_queues.cfg`, one concrete queue per name, each
referencing the template. The template queue uses the Docker plugins:

```json
"submitter": {
  "name": "DockerSubmitter",
  "module": "docker_submitter",
  "containerImage": "alpine:latest",
  "dockerSocket": "unix:///var/run/docker.sock"
},
"monitor": {
  "name": "DockerMonitor",
  "module": "docker_monitor"
},
"messenger": {
  "name": "BaseMessenger",
  "module": "pandaharvester.harvestermessenger.base_messenger",
  "accessPoint": "/harvester/workers"
},
"stager": {
  "name": "DummyStager",
  "module": "pandaharvester.harvesterstager.dummy_stager"
}
```

To add more queues, list them in `PANDA_QUEUES` (whitespace- or comma-separated),
e.g. `PANDA_QUEUES=PANDA_COMPOSE_LOCAL E1_BNL E1_JLAB`. The same list drives both
the harvester (`render-panda-queues.py`) and the PanDA schedconfig registration
(`scripts/setup-queue.sh`), so the two stay in sync. Queues needing a different
plugin set still require editing `panda_queues.template.json`.

## Ports

| Port | Service | Protocol | Purpose |
|---|---|---|---|
| `25080` | `panda-server` | HTTP | PanDA REST API |
| `61613` | `activemq` | STOMP | Message broker (PanDA ↔ JEDI) |
| `61616` | `activemq` | OpenWire | Message broker (alternate) |
| `8161` | `activemq` | HTTP | Web console (admin/admin) |

> **Note:** HTTPS (port `25443`) is **not** configured in the dev stack.
> Use the HTTP endpoint for all local development and CI.
