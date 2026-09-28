# vLLM's host port moves off 8000

**Status:** implemented 2026-09-28
**Touches:** `docker-compose.yml`, `servers/*.env`, `.env.example`, every
`${VLLM_PORT:-…}` fallback in `scripts/` and `Makefile`, `scripts/tests/test_vllm_host_port.sh` (new). Consumer outside this repo:
ember-ai's `bench-maritime` (`BENCH_CHAT_URL`, `run_local_maritime_benchmark.py
--chat-url`, `docs/deepdrishti-benchmark.md`).

## Problem

On 2026-09-28 on ddai3, `make ddbe-start SVC=api` refused with
`Port conflict: API_EXT_PORT=8000 is already in use`. The holder was this
stack's `vllm-new`, published as `127.0.0.1:8000->8000/tcp`.

8000 is deepdarshak-backend's API host port (`API_EXT_PORT`) on every
deepdarshak host, and this stack runs on those same hosts (ddai1–ddai5). Every
default here — the compose fallback, `.env.example`, and the four profiles
that pin it (`server-default`, `server-high-vram`, `server-multi-gpu`,
`common-blackwell-32gb`, plus `server-blackwell-32gb`) — said 8000, so a fresh
start collided whichever stack came up second. `vllm-new` is
`restart: unless-stopped`, so after a reboot it usually wins and the API
does not start. ember already hit the same collision on 2026-09-08 with its
own (since removed) `VLLM_EXT_PORT`.

## Decision

The **host-published** port of the primary vLLM instance defaults to **8100**
everywhere: the compose fallback, every profile that sets `VLLM_PORT`,
`.env.example`, and every script/Makefile fallback.

8100 was chosen because it is free on ddai3 and declared by no compose file,
`.env.config` or ports file in the deepdarshak workspace, ember-ai or NCS
(checked 2026-09-28). The neighbours are taken: 8001 (vllm-router), 8005,
8010/8011 (vllm2/vllm3), 8080–8092 (traefik, LiteLLM, embeddings, llama.cpp,
…), 8105/8106.

**Unchanged:**
- The **container** port stays 8000. Everything on the compose network —
  LiteLLM's `api_base: http://vllm-new:8000/v1`, `CONTRACT_*_API_BASE=http://vllm:8000/v1`,
  the router's `ROUTER_HOST_*`, Prometheus's scrape target, the in-container
  healthcheck — is unaffected.
- `server-85.env` (crimson-llm2) keeps `VLLM_PORT=11502`: its legacy consumers
  dial that port directly on 0.0.0.0.
- `VLLM2_PORT` / `VLLM3_PORT` / `VLLM_ROUTER_PORT` — none of them collides with
  a workspace default.
- Historical docs (`MIGRATION_GUIDE.md`, `IMPLEMENTATION_SUMMARY.md`,
  `VLLM_COMPARISON.md`, `EXISTING_SERVICES.md`, `WORK_COMPLETED.md`,
  `QUICKSTART.md` / `DEPLOYMENT_GUIDE.md` (a native vLLM on another box),
  `docs/plans/`) describe a past state and are not rewritten.

## Who is affected

The direct port is loopback-bound on the ddai profiles; consumers off the box
use the LiteLLM gateway (`LITELLM_PORT`), which is unaffected. What dials
`127.0.0.1:${VLLM_PORT}` from the host:

- this repo's `health-check.sh`, `chain-bench.sh`, `deploy.sh` summary,
  `make` port check / endpoint listing, `preflight-checks.sh` — all read
  `VLLM_PORT` and fall back to the default;
- ember-ai `make bench-maritime` (`BENCH_CHAT_URL`) and
  `scripts/run_local_maritime_benchmark.py --chat-url`, default
  `http://127.0.0.1:8000/v1` → `http://127.0.0.1:8100/v1`.

A running deployment keeps 8000 until its vllm container is recreated
(`make stop && make start`, or `docker compose up -d vllm-new`).

## Test

`scripts/tests/test_vllm_host_port.sh` asserts:
1. compose publishes `${VLLM_PORT:-8100}:8000`;
2. every `${VLLM_PORT:-N}` fallback in `scripts/` and `Makefile` is 8100;
3. no profile under `servers/` sets `VLLM_PORT` to a port reserved by the
   deepdarshak workspace (8000, the backend API);
4. `.env.example` documents 8100.
