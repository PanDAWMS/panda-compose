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

`config/panda/panda_server.cfg` sets `CRIC_URL_*` to `file:///etc/panda/cric/<name>.json`
and `docker-compose.yml` mounts this directory into the panda-server container
at that path.

## Adding a queue or site

1. Add an entry to `schedconfig.json` (must include `panda_queue`,
   `panda_resource`, `atlas_site`, `astorages`).
2. Add the site to `sites.json` (must include `state=ACTIVE`,
   `tier_level`, `datapolicies`, `ddmendpoints`, `presources`).
3. Add each DDM endpoint referenced by the site to `ddmendpoints.json`
   (must include `state=ACTIVE`, `token`, `site`, `type`, `is_tape`).
4. Restart or wait ~4 minutes for the next configurator run.

The `panda_queues.cfg` in Harvester still needs to reference the queue name
independently — the CRIC dumps only tell panda-server about the queue; they
don't automatically wire it into Harvester.
