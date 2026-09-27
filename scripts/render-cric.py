#!/usr/bin/env python3
"""Render the CRIC dumps for every queue in PANDA_QUEUES.

panda-compose ships CRIC dumps (schedconfig/sites/ddmendpoints) describing a
single queue, PANDA_COMPOSE_LOCAL. When extra local queues are provisioned via
PANDA_QUEUES they must also appear in the CRIC dumps, otherwise the Configurator
logs "SITE ... not found in CRIC", the sites get no DDM endpoints, and JEDI jobs
never leave 'defined' (no storage/site info to dispatch or activate them).

Each configured queue is cloned from the template queue/site entry (so it shares
the template's DDM endpoint, e.g. MOCK-POSIX) with the name fields substituted.
ddmendpoints/ddmblacklist are shared and copied verbatim. Output is written to
the directory the server reads via CRIC_URL_* (default /etc/panda/cric).
"""
import copy
import json
import os

TEMPLATE_QUEUE = os.environ.get("PANDA_CRIC_TEMPLATE_QUEUE", "PANDA_COMPOSE_LOCAL")
SRC = os.environ.get("PANDA_CRIC_TEMPLATE_DIR", "/etc/panda/cric-templates")
OUT = os.environ.get("PANDA_CRIC_OUTPUT_DIR", "/etc/panda/cric")

NAME_FIELDS = ("panda_queue", "nickname", "panda_resource", "atlas_site", "site_name")


def load(name):
    with open(os.path.join(SRC, name)) as fh:
        return json.load(fh)


def write(name, obj):
    with open(os.path.join(OUT, name), "w") as fh:
        json.dump(obj, fh, indent=2)


def main():
    queues = [
        q for q in os.environ.get("PANDA_QUEUES", TEMPLATE_QUEUE).replace(",", " ").split() if q
    ]
    # Always keep the template queue itself defined.
    if TEMPLATE_QUEUE not in queues:
        queues.insert(0, TEMPLATE_QUEUE)

    os.makedirs(OUT, exist_ok=True)

    sched = load("schedconfig.json")
    sched_tmpl = sched[TEMPLATE_QUEUE]
    new_sched = {}
    for q in queues:
        entry = copy.deepcopy(sched_tmpl)
        for field in NAME_FIELDS:
            if field in entry:
                entry[field] = q
        new_sched[q] = entry
    write("schedconfig.json", new_sched)

    sites = load("sites.json")
    site_tmpl = sites[TEMPLATE_QUEUE]
    new_sites = {}
    for q in queues:
        site = copy.deepcopy(site_tmpl)
        # presources is keyed by panda_resource -> panda_queue; rekey to this queue.
        site["presources"] = {q: {q: {"state": "ACTIVE"}}}
        new_sites[q] = site
    write("sites.json", new_sites)

    # DDM endpoints and blacklist are shared across all local queues.
    write("ddmendpoints.json", load("ddmendpoints.json"))
    write("ddmblacklist.json", load("ddmblacklist.json"))

    print(f"Rendered CRIC dumps for {len(queues)} queue(s): {', '.join(queues)}")


if __name__ == "__main__":
    main()
