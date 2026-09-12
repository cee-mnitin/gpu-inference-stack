# `health-check.sh` must read the server profile, not `.env` alone

**Status:** implemented 2026-09-12
**Touches:** `scripts/lib-profile.sh` (new `profile_load_vars`), `scripts/health-check.sh`,
`scripts/tests/test_profile_vars.sh` (new)

## Problem

`health-check.sh` is the tool the README tells you to run *"before pointing a
consumer at a new box"*. On ddai4 it reported, against a completely healthy
stack:

```
Checking LiteLLM...    ✗ FAILED (HTTP 404)
Checking Prometheus... ✗ FAILED (HTTP 000)
Checking Grafana...    ✗ FAILED (HTTP 401)
Ember contract aliases: ✗ could not list models — is LiteLLM up and is LITELLM_MASTER_KEY set?
```

Every one of those was a false negative. LiteLLM was serving 19 models on
:8090, Prometheus on :9490, Grafana on :3400.

**Cause.** The script did `source "$PROJECT_ROOT/.env"` and nothing else. `.env`
holds only `SERVER_PROFILE` plus secrets; the ports, the bind address and the
`ENABLE_*` switches live in the profile chain
(`servers/server-64.env` → `servers/common-blackwell-32gb.env`), which
`docker compose` layers via `--env-file` but which nothing had taught this
script to read. So every profile value fell back to the compose default:
`LITELLM_PORT` 8080, `PROMETHEUS_PORT` 9090, `GRAFANA_PORT` 3000.

The LiteLLM case is the instructive one. The script already carries a comment
explaining that probing the wrong address *"does not merely fail, it probes THAT
service and reports its answer: an HTTP 404 from an unrelated proxy,
indistinguishable from a broken LiteLLM."* That is precisely what happened —
`platform-traefik` holds 127.0.0.1:8080 on this box. The author diagnosed the
failure mode and fixed the **host** half (`LITELLM_BIND_ADDR`) while the
**port** half went on reading a default.

A check that is wrong in the alarming direction is not harmless: it trains
operators to ignore it, which is how a real outage gets waved past.

## Decision

Add `profile_load_vars` to `lib-profile.sh` — the same base → profile → `.env`
resolution `profile_env_file_args` already gives compose, but exported into the
current shell for the scripts that never invoke compose. `health-check.sh`
calls it in place of `source .env`.

Three properties the implementation must hold, and the tests pin each:

- **Parsed, not sourced.** These files legitimately contain spaces and shell
  metacharacters (`INFINITY_CMD="v2 --model-id BAAI/bge-m3 --port 7997"`), and
  sourcing one has already aborted a deploy with `--model-id: command not
  found`. Inline ` # …` comments are stripped from unquoted values only, which
  is what compose does and what `ENABLE_EMBEDDINGS=false  # no TEI tag for
  sm_120` needs.
- **Later file wins inside the chain** — base, then profile, then `.env`.
- **The caller always wins over all of them.** `LITELLM_PORT=9999
  ./scripts/health-check.sh` is a deliberate override and must beat a committed
  file. Keys already present in the environment are recorded *before* any
  export, so the first file to mention a key cannot make it look preset to the
  second.

## Result

```
Checking LiteLLM ✓ · Prometheus ✓ · Grafana ✓ · vLLM ✓ · Infinity ✓ · Redis ✓ · Postgres ✓
Ember contract aliases: interactive ✓ bulk ✓ fast ✓ embed ✓ rerank ✓ vision ✓(optional)
                        gpu/ocr/paddleocr-vl — not served (named, with the remedy)
Contract call probe: 6/6 ✓
```

`scripts/tests/test_profile_vars.sh` — no docker, no network; builds a throwaway
profile chain in a temp dir.
