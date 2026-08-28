# Rucio Integration (opt-in)

The panda-compose stack ships two Harvester plugins under
`config/harvester/plugins/`:

- `docker_submitter.py` — runs each PanDA worker as a Docker container.
- `rucio_stager.py` — after each container exits, uploads output
  files to a Rucio dev stack, attaches them to the destination
  dataset, and hands the resulting metadata back to panda-server so
  the Adder can archive the job.

Neither plugin is wired into the default `panda_queues.cfg`: fresh
installs still use `DummyStager` so the stack starts cleanly without
any Rucio configured. This page walks through the opt-in.

## Prerequisites

- A running Rucio dev stack. The rucio/rucio-dev image and its
  compose file provide a fully-functional Rucio server, an
  Auth/Console, and a MOCK-POSIX RSE that writes to `/tmp/rucio_rse`
  on the host. Confirm the Docker network is up:
  ```bash
  docker network ls | grep rucio
  ```
  The default network name is `ruciodevnetwork` — if yours differs,
  adjust the override file below.

- The `panda-dev-user` Rucio account exists and is registered with a
  scope you want the RucioStager to write to (default `user.hermes`
  — change `defaultScope` in the queue config to your own scope).

## Step 1 — Rucio client config

Create `config/rucio/rucio.cfg`:

```ini
[client]
rucio_host = https://rucio:443
auth_host = https://rucio:443
auth_type = userpass
username = ddmlab
password = secret
account = root
ca_cert = /opt/rucio/etc/rucio_ca.pem
```

Copy the Rucio dev stack's self-signed CA cert next to it, then create
the OpenSSL hash symlink OpenSSL requires for `X509_CERT_DIR` lookups:

```bash
cp path/to/rucio_ca.pem config/rucio/rucio_ca.pem
h=$(openssl x509 -hash -noout -in config/rucio/rucio_ca.pem)
ln -sf rucio_ca.pem config/rucio/${h}.0
```

## Step 2 — Copy the override example

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
```

Compose picks up `docker-compose.override.yml` automatically. Read the
file's header for what it does and adjust the network name if
your Rucio dev stack uses a different one.

## Step 3 — Enable RucioStager in the queue config

Edit `config/harvester/panda_queues.cfg`:

```json
"stager": {
    "name": "RucioStager",
    "module": "rucio_stager",
    "outputBaseDir": "/tmp/harvester_output",
    "rse": "MOCK-POSIX",
    "rucioAccount": "root",
    "defaultScope": "user.hermes"
}
```

Replace the shipped `DummyStager` block with the above.

## Step 4 — Install rucio-clients in the harvester container

Add `rucio-clients` to the harvester service's bootstrap pip install
line in `docker-compose.yml`. The plugin lazily imports
`rucio.client.uploadclient.UploadClient` inside `trigger_stage_out()`;
without the package the stager logs a clean error and every
stage-out fails.

```yaml
harvester:
  command:
    - /bin/bash
    - -c
    - |
      source /opt/harvester/bin/activate
      pip install -q 'docker==7.1.0' 'rucio-clients==38.1.0'
      ...
```

## Step 5 — Bring the stack back up

```bash
docker compose up -d
```

Submit a test task with `prun`. Output files should appear in Rucio:

```bash
# In the Rucio dev container:
rucio did list 'user.hermes:*rucioout.*'
```

And on the RSE:

```bash
find /tmp/rucio_rse/user/hermes -type f
```

## Design notes

See the docstring in `config/harvester/plugins/rucio_stager.py` for
the plugin's design tradeoffs and gotchas — most notably why it
authenticates as `root` in the local dev setup and why it uploads
one file at a time instead of in bulk.
