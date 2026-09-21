# Rucio Integration

The stack runs Rucio as part of `docker-compose.yml` — there is no
opt-in step and no separate overlay file. `docker compose up -d`
brings up three Rucio services alongside PanDA:

| service | role |
|---|---|
| `ruciodb` | PostgreSQL backing store |
| `rucio-init` | one-shot: creates the schema and the `root` account |
| `rucio` | the Rucio server (HTTP, port 80 inside the network) |

Two Harvester plugins under `config/harvester/plugins/` use it:

- `docker_submitter.py` — runs each PanDA worker as a Docker container.
- `rucio_stager.py` — after each container exits, uploads output files
  to Rucio, attaches them to the destination dataset, and hands the
  metadata back to panda-server so the Adder can archive the job.

`config/harvester/panda_queues.cfg` already selects `RucioStager`, and
the base compose file already mounts both plugins and installs
`rucio-clients`. Nothing needs enabling.

## No certificates required

The server runs with `RUCIO_ENABLE_SSL=False`, so Apache listens on
plain HTTP and **no CA certificate, host certificate, or OpenSSL hash
symlink is involved**. The client config
(`config/rucio/rucio-ci.cfg`, mounted into harvester at
`/opt/rucio/etc/rucio.cfg`) is correspondingly minimal:

```ini
[client]
rucio_host = http://rucio:80
auth_host = http://rucio:80
auth_type = userpass
username = ddmlab
password = secret
account = root
```

Note there is no `ca_cert` key and no `[database]` section — the
`[database]` section is server-side only, and a client that has one
will try to talk SQL directly and fail with `no such table: rses`.

## Bootstrapping the RSE

`rucio-init` creates only the schema and the `root` account. The RSE,
its protocol, the scopes and the account quota are created by:

```bash
./scripts/bootstrap-rucio.sh panda-compose-rucio-1
```

It is idempotent (an already-exists 409 counts as success), and it
creates:

| item | value |
|---|---|
| RSE | `MOCK-POSIX` |
| protocol | posix `file://`, prefix `/tmp/rucio_rse/` |
| scopes | `user.alice`, `mock` |
| quota | `root` on `MOCK-POSIX`, unlimited (`-1`) |

The quota is not optional: without it `UploadClient` completes DID
registration and then fails at the replication-rule step with
`InsufficientAccountLimit`.

The GitHub composite action runs this automatically once the server
reports healthy, so CI needs no extra step.

## Verifying

```bash
# server is up
docker exec panda-compose-rucio-1 curl -fsS http://localhost/ping

# files on the RSE
docker exec panda-compose-rucio-1 find /tmp/rucio_rse -type f
```

To list DIDs you need a token:

```bash
TOKEN=$(docker exec panda-compose-rucio-1 curl -s -i \
  -H 'X-Rucio-Account: root' \
  -H 'X-Rucio-Username: ddmlab' \
  -H 'X-Rucio-Password: secret' \
  http://localhost/auth/userpass \
  | grep -i '^x-rucio-auth-token:' | tr -d '\r' | awk '{print $2}')

docker exec panda-compose-rucio-1 curl -s \
  -H "X-Rucio-Auth-Token: $TOKEN" \
  'http://localhost/dids/user.alice/dids/search?type=file'
```

## Submitting a job that produces output

A job only stages out if it declares an output file. `pandajob-submit`
takes `--output`, and the payload must write a file of exactly that
name:

```bash
pandajob-submit --site PANDA_COMPOSE_LOCAL \
  --container python:3.12-alpine \
  --transformation sh \
  --output user.alice.demo.out.txt \
  --params "-c 'echo hello > user.alice.demo.out.txt'"
```

The LFN must follow the ATLAS convention `user.<name>.*`, because the
stager derives the Rucio scope from its first two dot-separated
components (`user.alice.demo.out.txt` → scope `user.alice`). A bare
name like `out.txt` makes the stager infer the job name as the scope
and fail with `ScopeNotFound`.

## Design notes

See the docstring in `config/harvester/plugins/rucio_stager.py` for the
plugin's tradeoffs — most notably why it authenticates as `root` and
why it uploads one file at a time rather than in bulk.

## Troubleshooting

### "No module named 'rucio'"
The harvester bootstrap didn't install `rucio-clients`. Check the pip
step in the harvester service's `command` in `docker-compose.yml`.

### "no such table: rses"
The client config has a `[database]` section. Remove it — clients must
go through the HTTP API.

### "InsufficientAccountLimit"
`bootstrap-rucio.sh` hasn't run, or ran before the RSE existed. Re-run
it; it is idempotent.

### "ScopeNotFound"
The output LFN doesn't follow `user.<name>.*`, so the derived scope
isn't a registered one. See the submission section above.

### RucioStager can't find output files (`candidates=[]`)
`DockerSubmitter` asks the *host* Docker daemon to bind-mount
`<outputBaseDir>/worker-<ID>` into each worker, so that path is
resolved on the host. If harvester mounts `outputBaseDir` as a named
volume instead of a host bind, the worker writes to one directory and
the stager reads another. `docker-compose.yml` binds
`/tmp/harvester_output` from the host for exactly this reason.

### Jobs stay in `activated`
Harvester isn't fetching. Check, in order:

```bash
# 1. did the queue config load at all?
docker exec panda-compose-harvester-1 python3 -c \
  "import sqlite3;print(sqlite3.connect('/var/lib/panda/harvester.db')\
   .execute('SELECT queueName FROM pq_table').fetchall())"

# 2. if empty, why?
docker exec panda-compose-harvester-1 \
  grep -E 'ERROR|Omitted' /var/log/harvester/panda-queue_config_mapper.log | tail
```

An empty `pq_table` means the queue config was rejected — usually a
plugin named in `panda_queues.cfg` that isn't mounted into
`/harvester/plugins/`. A populated `pq_table` combined with
`got 0 queues` in `panda-job_fetcher.log` means the queue is missing
the `nQueueLimitJob` key, which `get_num_jobs_to_fetch()` requires to
treat a queue as PUSH.
