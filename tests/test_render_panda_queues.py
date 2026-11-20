#!/usr/bin/env python3
"""Unit tests for scripts/render-panda-queues.py.

Run with: python3 -m unittest discover -s tests -v
(or via pytest if available; stdlib-only so CI needs no extra deps)

Covers the queue-template rendering contract:
- concrete queues are created for each PANDA_QUEUES entry
- concrete queues inherit the submitter block (incl. containerImage) from
  the shared template queue via templateQueueName
- PANDA_WORKER_IMAGE patches the template's containerImage before rendering
- without PANDA_WORKER_IMAGE the committed template default is preserved
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "render-panda-queues.py"
TEMPLATE = REPO_ROOT / "config" / "harvester" / "panda_queues.template.json"

TEMPLATE_QUEUE = "panda-compose-local.template"


def run_render(env_extra, template=TEMPLATE):
    """Run the render script in a temp env; return (stdout, rendered config)."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "panda_queues.cfg"
        env = {
            "PANDA_QUEUES_TEMPLATE": str(template),
            "PANDA_QUEUES_OUTPUT": str(out),
            # start from a clean env; the script only reads these three vars
            "PANDA_QUEUES": "PANDA_COMPOSE_LOCAL",
            "PANDA_WORKER_IMAGE": "",
        }
        env.update(env_extra)
        proc = subprocess.run(
            [sys.executable, str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        return proc.stdout, json.loads(out.read_text())


class TestRenderPandaQueues(unittest.TestCase):
    def test_committed_template_has_submitter_container_image(self):
        """The shipped template must carry the queue-default worker image.

        This is the value DockerSubmitter falls back to when a job has no
        per-job container_name; if it is missing or malformed every job
        without an override breaks.
        """
        config = json.loads(TEMPLATE.read_text())
        submitter = config[TEMPLATE_QUEUE]["submitter"]
        self.assertEqual(submitter["name"], "DockerSubmitter")
        self.assertTrue(
            submitter.get("containerImage"), "containerImage must not be empty"
        )

    def test_concrete_queue_created(self):
        _, config = run_render({"PANDA_QUEUES": "PANDA_COMPOSE_LOCAL E1_BNL"})
        self.assertIn("PANDA_COMPOSE_LOCAL", config)
        self.assertIn("E1_BNL", config)
        for name in ("PANDA_COMPOSE_LOCAL", "E1_BNL"):
            self.assertEqual(config[name]["queueStatus"], "online")
            self.assertEqual(config[name]["templateQueueName"], TEMPLATE_QUEUE)

    def test_default_image_preserved_without_override(self):
        """No PANDA_WORKER_IMAGE => the committed template default is kept."""
        template_default = json.loads(TEMPLATE.read_text())[TEMPLATE_QUEUE][
            "submitter"
        ]["containerImage"]
        _, config = run_render({"PANDA_WORKER_IMAGE": ""})
        self.assertEqual(
            config[TEMPLATE_QUEUE]["submitter"]["containerImage"],
            template_default,
        )

    def test_worker_image_override_applied(self):
        """PANDA_WORKER_IMAGE patches the template's containerImage."""
        stdout, config = run_render(
            {"PANDA_WORKER_IMAGE": "panda-compose/snakemake-worker:9.27.1"}
        )
        self.assertEqual(
            config[TEMPLATE_QUEUE]["submitter"]["containerImage"],
            "panda-compose/snakemake-worker:9.27.1",
        )
        self.assertIn("panda-compose/snakemake-worker:9.27.1", stdout)


if __name__ == "__main__":
    unittest.main()
