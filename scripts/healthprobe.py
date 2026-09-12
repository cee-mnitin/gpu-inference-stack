#!/usr/bin/env python3
"""Health probe that exercises the INFERENCE path.

Why this exists
---------------
On 2026-09-12 Infinity stopped serving embeddings on ddai3: every request to
`/embeddings` timed out, through the gateway and directly. Docker reported the
container **healthy** for the whole episode, because the probe was
`GET /health` — served by the HTTP layer, which was fine. The thing that was
broken was the only thing the probe did not touch.

Two separate gaps, and fixing one without the other fixes nothing:

1. A liveness probe cannot see a hung inference path. So this probe sends a
   real request — one short embedding, or a one-token completion — and checks
   the response has the shape the contract promises.

2. `restart: unless-stopped` does NOT act on health. Docker's restart policy
   fires when the process EXITS; an unhealthy container is simply labelled and
   left running. Detection alone therefore recovers nothing — see
   scripts/watchdog.sh, which is the half that acts, and runs on the HOST.

WHY THE RESET IS NOT HERE. The first version of this script killed PID 1 after
N consecutive failures, so the restart policy would replace the container. It
was tested against a real hang and DID NOT WORK: in the Infinity container PID
1 *is* the engine, and the kernel discards default-action signals sent to PID 1
from inside its own namespace unless the process installed a handler — and a
process whose event loop is wedged cannot run a handler anyway. The probe
reported "8 consecutive failures — killing PID 1" and the container went on
running, untouched, for another seven minutes. A watchdog that cannot fire at
the one failure it exists for is worse than none, because it reads like cover.

An engine under load is slow, not hung, so keep --timeout generous: this probe
only reports, and the restart decision (with its own consecutive-failure
threshold) belongs to the watchdog.

Exit 0 = serving. Exit 1 = not serving; Docker marks the container unhealthy
after its own `retries`, which is what the host watchdog keys on.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request


def _probe(url: str, payload: dict, timeout: float, expect: str) -> tuple[bool, str]:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status != 200:
                return False, f"HTTP {r.status}"
            body = json.load(r)
    except urllib.error.HTTPError as e:      # a 4xx/5xx IS an answer: the
        return False, f"HTTP {e.code}"        # engine is up but refusing
    except Exception as e:                    # noqa: BLE001 — timeout, reset, DNS
        return False, f"{type(e).__name__}: {e}"
    # Shape check, not just a 200: a proxy or an error envelope can return 200
    # with nothing useful in it, which is the same outage from a caller's seat.
    if expect not in body or not body[expect]:
        return False, f"200 but no {expect!r} in response"
    return True, "ok"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--kind", choices=("embeddings", "chat"), required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--timeout", type=float, default=20.0)
    # Accepted and ignored, so an older compose file keeps working after an
    # image update rather than failing every probe on an unknown argument.
    p.add_argument("--threshold", type=int, default=0, help=argparse.SUPPRESS)
    p.add_argument("--state", default="", help=argparse.SUPPRESS)
    args = p.parse_args()

    if args.kind == "embeddings":
        payload, expect = {"model": args.model, "input": ["health probe"]}, "data"
    else:
        payload = {"model": args.model, "max_tokens": 1,
                   "messages": [{"role": "user", "content": "ping"}]}
        expect = "choices"

    ok, why = _probe(args.url, payload, args.timeout, expect)
    if ok:
        return 0
    print(f"healthprobe: {why}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
