#!/usr/bin/env python3
"""Render the CRIC dumps for every queue in PANDA_QUEUES.

panda-compose ships CRIC dumps (schedconfig/sites/ddmendpoints) describing a
single queue, PANDA_COMPOSE_LOCAL. When extra local queues are provisioned via
PANDA_QUEUES they must also appear in the CRIC dumps, otherwise the Configurator
logs "SITE ... not found in CRIC", the sites get no DDM endpoints, and JEDI jobs
never leave 'defined' (no storage/site info to dispatch or activate them).

Every configured queue becomes a PanDA resource of the single template site
(PANDA_COMPOSE_LOCAL): one schedconfig entry per queue (sharing the template's
atlas_site and astorages), all listed under that site's `presources`. Keeping a
single site means the one mock storage endpoint (MOCK-POSIX) is local to every
queue (the Configurator's is_local compares the queue's atlas_site to the
endpoint's site). ddmendpoints/ddmblacklist are copied verbatim. Output is
written to the directory the server reads via CRIC_URL_* (default
/etc/panda/cric).
"""
import copy
import json
import os

TEMPLATE_QUEUE = os.environ.get("PANDA_CRIC_TEMPLATE_QUEUE", "PANDA_COMPOSE_LOCAL")
SRC = os.environ.get("PANDA_CRIC_TEMPLATE_DIR", "/etc/panda/cric-templates")
OUT = os.environ.get("PANDA_CRIC_OUTPUT_DIR", "/etc/panda/cric")

# Extra DDM endpoints to attach to the compose site, as a JSON object keyed by
# endpoint name, e.g. PANDA_CRIC_EXTRA_ENDPOINTS='{"DAQ_DISK_3": {"token": "DAQ",
# "type": "OS_LOGS"}}'. The RSEs behind such endpoints are typically created by
# the consumer of the stack (e.g. a data agent uploading to a dedicated RSE),
# which is why they are supplied via env and not baked into the shipped dumps.
# Endpoint names missing from the template's astorages are appended there (both
# read_lan and write_lan) so every rendered queue reads/writes them as local.
EXTRA_ENDPOINTS_RAW = os.environ.get("PANDA_CRIC_EXTRA_ENDPOINTS", "")

# Fields that identify the queue itself. atlas_site / site_name are deliberately
# NOT rekeyed: all queues stay on the single template site so storage is local.
NAME_FIELDS = ("panda_queue", "nickname", "panda_resource")


def load(name):
    with open(os.path.join(SRC, name)) as fh:
        return json.load(fh)


def write(name, obj):
    with open(os.path.join(OUT, name), "w") as fh:
        json.dump(obj, fh, indent=2)


def load_extra_endpoints():
    if not EXTRA_ENDPOINTS_RAW:
        return {}
    try:
        extra = json.loads(EXTRA_ENDPOINTS_RAW)
    except ValueError as e:
        raise SystemExit(f"PANDA_CRIC_EXTRA_ENDPOINTS is not valid JSON: {e}")
    if not isinstance(extra, dict):
        raise SystemExit("PANDA_CRIC_EXTRA_ENDPOINTS must be a JSON object keyed by endpoint name")
    for name, spec in extra.items():
        if not isinstance(spec, dict) or not all(k in spec for k in ("token", "type")):
            raise SystemExit(f"PANDA_CRIC_EXTRA_ENDPOINTS entry {name!r} needs 'token' and 'type'")
    return extra


def main():
    queues = [
        q for q in os.environ.get("PANDA_QUEUES", TEMPLATE_QUEUE).replace(",", " ").split() if q
    ]
    extra_endpoints = load_extra_endpoints()

    os.makedirs(OUT, exist_ok=True)

    # One schedconfig entry per queue, all sharing the template site's atlas_site
    # (and astorages), so each queue's storage resolves as local.
    sched = load("schedconfig.json")
    sched_tmpl = sched[TEMPLATE_QUEUE]
    if extra_endpoints:
        astorages = sched_tmpl.setdefault("astorages", {})
        for role in ("read_lan", "write_lan"):
            endpoints = astorages.setdefault(role, [])
            endpoints.extend(e for e in extra_endpoints if e not in endpoints)
    new_sched = {}
    for q in queues:
        entry = copy.deepcopy(sched_tmpl)
        for field in NAME_FIELDS:
            if field in entry:
                entry[field] = q
        new_sched[q] = entry
    write("schedconfig.json", new_sched)

    # Single site hosting every queue as a PanDA resource. presources is keyed
    # panda_resource -> panda_queue; list all queues so each maps to this site
    # (and thus to its local storage endpoints).
    sites = load("sites.json")
    site = copy.deepcopy(sites[TEMPLATE_QUEUE])
    site["presources"] = {q: {q: {"state": "ACTIVE"}} for q in queues}
    if extra_endpoints:
        site_ddm = site.setdefault("ddmendpoints", {})
        for name in extra_endpoints:
            site_ddm.setdefault(name, {"state": "ACTIVE"})
    write("sites.json", {TEMPLATE_QUEUE: site})

    # DDM endpoints and blacklist are shared across all local queues. Extra
    # endpoints are merged into ddmendpoints.json attached to the compose site.
    ddm = load("ddmendpoints.json")
    for name, spec in extra_endpoints.items():
        ddm[name] = {
            "state": "ACTIVE",
            "token": spec["token"],
            "site": TEMPLATE_QUEUE,
            "type": spec["type"],
            "is_tape": spec.get("is_tape", False),
        }
    write("ddmendpoints.json", ddm)
    write("ddmblacklist.json", load("ddmblacklist.json"))

    msg = f"Rendered CRIC dumps for {len(queues)} queue(s): {', '.join(queues)}"
    if extra_endpoints:
        msg += f"; extra endpoints: {', '.join(sorted(extra_endpoints))}"
    print(msg)


if __name__ == "__main__":
    main()
