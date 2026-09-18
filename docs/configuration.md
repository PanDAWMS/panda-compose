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
| `config/harvester/panda_queues.cfg` | `harvester` | Compute queue definitions |

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

### `config/harvester/panda_queues.cfg` — queue definition

The queue configuration is JSON. The `PANDA_COMPOSE_LOCAL` queue uses the Docker plugins:

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

To add a second queue (e.g., for a different experiment), add a new template entry
and a corresponding site entry in `panda_queues.cfg` and register the site in the
database via a modified version of `scripts/setup-queue.sh`.

## Ports

| Port | Service | Protocol | Purpose |
|---|---|---|---|
| `25080` | `panda-server` | HTTP | PanDA REST API |
| `61613` | `activemq` | STOMP | Message broker (PanDA ↔ JEDI) |
| `61616` | `activemq` | OpenWire | Message broker (alternate) |
| `8161` | `activemq` | HTTP | Web console (admin/admin) |

> **Note:** HTTPS (port `25443`) is **not** configured in the dev stack.
> Use the HTTP endpoint for all local development and CI.
