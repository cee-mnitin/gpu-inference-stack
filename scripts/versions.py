#!/usr/bin/env python3
"""Compare the image each service is CONFIGURED to use against the image its
container is actually RUNNING.

These are different questions and only one of them is visible in `docker ps`.
They diverge the moment a profile pins a new version and nothing has restarted
yet — precisely the state a version bump leaves you in, and the reason "I
changed VLLM_IMAGE" does not mean "I am running it".

Reads the rendered compose config as JSON on stdin:

    scripts/dc.sh <profiles> config --format json | scripts/versions.py

Exit 0 always: this reports, it does not gate. `make start` is what fixes drift.
"""
from __future__ import annotations

import json
import subprocess
import sys


def running_image(container: str) -> str:
    """The image a container was CREATED from, or '-' if there is no container.

    .Config.Image is the tag as given at create time, which is what we want to
    compare against the compose config. .Image would be the resolved sha256 and
    would never match.
    """
    r = subprocess.run(
        ["docker", "inspect", "-f", "{{.Config.Image}}", container],
        capture_output=True, text=True,
    )
    return r.stdout.strip() or "-"


def main() -> int:
    try:
        doc = json.load(sys.stdin) or {}
    except (json.JSONDecodeError, ValueError):
        print("  (could not read compose config — is a profile selected?)")
        return 0

    services = doc.get("services") or {}
    if not services:
        print("  (no services in the rendered config)")
        return 0

    print("  %-16s %-46s %s" % ("SERVICE", "CONFIGURED", "RUNNING / IMAGE ID"))
    drift = []
    for name, spec in sorted(services.items()):
        configured = spec.get("image", "-")
        got = running_image(spec.get("container_name") or name)
        container = spec.get("container_name") or name
        running_id = subprocess.run(
            ["docker", "inspect", "-f", "{{.Image}}", container],
            capture_output=True, text=True,
        ).stdout.strip()
        configured_id = subprocess.run(
            ["docker", "image", "inspect", "-f", "{{.Id}}", configured],
            capture_output=True, text=True,
        ).stdout.strip()
        changed = got not in ("-", configured) or bool(running_id and configured_id and running_id != configured_id)
        mark = "!" if changed else " "
        print("  %-16s %-46s %s %s %s" % (name, configured, got, running_id or "(not running)", mark))
        if changed:
            drift.append(name)

    print()
    if drift:
        print("  ! running a different image than configured: " + " ".join(drift))
        print("    `make start` recreates those containers.")
    else:
        print("  OK — references match; image IDs compared where the configured image is locally available")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
