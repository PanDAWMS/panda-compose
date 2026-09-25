#!/usr/bin/env python3
"""Render the harvester panda_queues.cfg from a template and PANDA_QUEUES.

The template file defines the shared template queue (isTemplateQueue). For each
name in PANDA_QUEUES (whitespace- or comma-separated) a concrete online queue is
emitted that references the template via templateQueueName, so the harvester
manages exactly the queues registered in schedconfig by setup-queue.sh.
"""
import json
import os
import sys

TEMPLATE_NAME = "panda-compose-local.template"


def concrete_queue():
    return {
        "queueStatus": "online",
        "prodSourceLabel": "test",
        "prodSourceLabelRandomWeightsPermille": {"test": 1000},
        "templateQueueName": TEMPLATE_NAME,
        "maxWorkers": 10,
        "maxNewWorkersPerCycle": 5,
        "nQueueLimitWorkerRatio": 10,
        "nQueueLimitWorkerMin": 1,
        "nQueueLimitWorkerMax": 10,
        "nQueueLimitJob": 10,
        "nQueueLimitJobRatio": 10,
        "nQueueLimitJobMin": 1,
        "nQueueLimitJobMax": 50,
    }


def main():
    template_path = os.environ.get(
        "PANDA_QUEUES_TEMPLATE", "/etc/panda/panda_queues.template.json"
    )
    output_path = os.environ.get(
        "PANDA_QUEUES_OUTPUT", "/var/lib/panda/panda_queues.cfg"
    )
    names = [n for n in os.environ.get("PANDA_QUEUES", "PANDA_COMPOSE_LOCAL").replace(",", " ").split() if n]

    with open(template_path) as fh:
        config = json.load(fh)
    if TEMPLATE_NAME not in config:
        sys.exit(f"template queue '{TEMPLATE_NAME}' missing from {template_path}")

    for name in names:
        config[name] = concrete_queue()

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as fh:
        json.dump(config, fh, indent=2)

    print(f"Rendered {len(names)} queue(s) to {output_path}: {', '.join(names)}")


if __name__ == "__main__":
    main()
