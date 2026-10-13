# Local CRIC dumps

The PanDA server's `configurator` daemon downloads site / DDM endpoint /
schedconfig / blacklist data from CRIC on a timer and mirrors it into the
`sites`, `panda_sites`, `ddm_endpoint`, `panda_ddm_relation`, and
`schedconfig_json` tables. In production the CRIC endpoints live at
`atlas-cric.cern.ch` / `datalake-cric.cern.ch`. In a local dev stack those
URLs are unreachable and the daemon logs a rolling stream of
`The site dump was not retrieved correctly` errors every few minutes.

`aux.get_dump()` in panda-server transparently supports `file://` URLs (see
`pandaserver/configurator/aux.py`), so we can point the daemon at these
JSON files instead. Behavior in the container is identical to a CRIC
fetch, minus the network round-trip.

## Files

| File | Corresponds to |
|---|---|
| `sites.json` | `CRIC_URL_SITES` — one entry per compute site |
| `ddmendpoints.json` | `CRIC_URL_DDMENDPOINTS` — one entry per DDM endpoint |
| `schedconfig.json` | `CRIC_URL_SCHEDCONFIG` — one entry per PanDA queue |
| `ddmblacklist.json` | `CRIC_URL_DDMBLACKLIST` (write) and read/full variants — endpoints to exclude; `{}` means none |

The schemas are minimal — only the fields
`pandaserver.configurator.Configurator.retrieve_data` /
`process_site_dumps` / `parse_endpoints` actually read are populated.
Add fields on demand if you enable additional Configurator features.

## Wiring

`config/panda/panda_server.cfg` sets `CRIC_URL_*` to `file:///etc/panda/cric/<name>.json`.
These JSON files are **templates**: `docker-compose.yml` mounts this directory
read-only at `/etc/panda/cric-templates`, and at panda-server startup
`scripts/render-cric.py` expands them into the writable `/etc/panda/cric` that
`CRIC_URL_*` points at — one full site/queue entry per queue in `PANDA_QUEUES`,
each cloned from the `PANDA_COMPOSE_LOCAL` template (sharing its MOCK-POSIX
endpoint). So the files here describe a single template queue; the per-queue
dumps the Configurator actually reads are generated at runtime.

## Adding a queue or site

For extra compute queues, you normally do **not** edit these files — set
`PANDA_QUEUES` (see `docs/configuration.md`) and `render-cric.py` clones the
template entry for each queue automatically.

To change the shared shape of every rendered queue, edit the single
`PANDA_COMPOSE_LOCAL` template entry in place (the renderer only ever reads that
entry and rebuilds the dumps from it, so adding extra entries here has no effect):

1. Edit the `PANDA_COMPOSE_LOCAL` entry in `schedconfig.json` (keeps
   `panda_queue`, `panda_resource`, `atlas_site`, `astorages`).
2. Edit the `PANDA_COMPOSE_LOCAL` site in `sites.json` (keeps `state=ACTIVE`,
   `tier_level`, `datapolicies`, `ddmendpoints`, `presources`).
3. Edit the DDM endpoint(s) referenced by the site in `ddmendpoints.json`
   (each keeps `state=ACTIVE`, `token`, `site`, `type`, `is_tape`).
4. Restart panda-server — rendering runs only at container startup, so a
   restart is required; waiting for the next Configurator run will not pick up
   template edits (it reads the already-rendered `/etc/panda/cric`).

The `panda_queues.cfg` in Harvester still needs to reference the queue name
independently — the CRIC dumps only tell panda-server about the queue; they
don't automatically wire it into Harvester.
