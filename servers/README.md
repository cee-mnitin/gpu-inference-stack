# Server Profiles

On a fresh machine:

```bash
git pull
make setup      # detects this server, confirms, applies its profile,
                # checks prerequisites, pulls images, builds
make start      # starts it, then reports models served and access URLs
```

`make setup` matches this host's IP against the fleet block and shows you what
it found — GPU, model, context, ports, which services will run — before
anything is written. Accept and it records `SERVER_PROFILE` in `.env`.
Override detection with `make setup PROFILE=85`.

Flags follow the workspace convention used by the deepdarshak `make` targets:

| Flag | Effect |
|---|---|
| `AUTO=1` | take the **default** answer to every prompt — apply on `setup`, and *decline* on `clean`, because an unattended run must not be able to destroy a stack's keys and history |
| `REBUILD=1` | rebuild, reusing the Docker layer cache |
| `NO_CACHE=1` | like `REBUILD` but ignore the cache (`--no-cache --pull`) |
| `SKIP_BUILD=1` | skip the build |
| `FORCE=1` | the deliberate escape for `clean`, unattended |

Build is folded into `setup` and runs only when needed: the image is missing,
or the build context changed. `.docker-build-hash` records a hash of
`config/litellm/`, so editing the Dockerfile triggers a rebuild without anyone
having to remember `REBUILD=1`.

| | |
|---|---|
| `make setup` | detect, confirm, apply, check, pull, build |
| `make start` | start + summary of models and URLs |
| `make stop` / `make restart` | |
| `make status` / `make health` | containers and GPU / full health check |
| `make models` / `make urls` | what is serving / endpoints |
| `make logs` / `make check` | tail logs / prerequisites only |

### Making sure you run the version you configured

Pinned images (vLLM, Infinity, Redis…) just work: change `VLLM_IMAGE` in the
profile, `make setup` pulls the new tag, `make start` recreates the container
because the image changed.

The locally built one needs more care. `config/litellm/Dockerfile` bakes Pillow
into `ghcr.io/berriai/litellm:main-latest`, and that base tag is **mutable** —
so `make setup` builds with `--pull`, re-resolving the base instead of reusing a
cached layer and handing you last month's litellm from an apparently successful
build. Use `make setup REBUILD=1` to add `--no-cache` when a layer is wrong
rather than merely stale.

Then verify rather than assume:

```bash
make versions     # configured image vs the image each container is running
```

Those are different questions, and `docker ps` only answers the second. They
diverge exactly when you have bumped a version and not restarted — `make setup`
prints this at the end for that reason, and `make start` is what closes the gap.

For anything ad-hoc use `scripts/dc.sh`. **A bare `docker compose` does not see
the profile** — it reads `.env` only, so every profile value falls back to a
compose default written for a different class of card.

```bash
scripts/dc.sh ps
scripts/dc.sh logs -f litellm
```

## How layering works

```
docker compose --env-file servers/server-<name>.env --env-file .env …
```

Compose unions the keys of every `--env-file` and **the last file wins**. So
the committed profile supplies this box's hardware, models, VRAM split, ports
and role wiring, while `.env` supplies only what is genuinely per-host:
`SERVER_PROFILE`, the fleet address block, secrets, and host paths.

That ordering is the design. It also means **anything uncommented in `.env`
beats the profile** — useful for a deliberate one-off, and the reason every
profile-owned key ships commented out in `.env.example`. An uncommented copy of
a profile's key silently defeats profile selection.

The old flow was `cp servers/server-x.env .env`, which forks the profile the
moment anything is tuned: the box drifts from the committed file and nothing
can tell you how. Layering keeps the profile authoritative.

## The four machines

| Profile | Host | GPU | Chat engine | Notes |
|---|---|---|---|---|
| `40` | dd4-skynet, 100.117.227.40 | RTX A6000, 48 GB, sm_86 | llama.cpp, Qwen3-Next-80B Q3 | Ampere — none of the Blackwell traps apply |
| `63` | ddai3, 100.117.227.63 | RTX PRO 4500 Blackwell, 32 GB, sm_120 | vLLM, Qwen3-30B-A3B AWQ | gateway on **8090** — the shared platform holds 8080 |
| `72` | ddai5, 100.117.227.72 | RTX PRO 4500 Blackwell, 32 GB, sm_120 | vLLM, Qwen3-30B-A3B AWQ | near-copy of `63`; `diff` shows only the host-specific lines |
| `85` | crimson-llm2, 100.117.227.85 | RTX PRO 6000 Blackwell, 97 GB, sm_120 | vLLM ×2 | the only box with room for **two** chat models |

The hardware-class files (`server-default.env`, `server-high-vram.env`,
`server-multi-gpu.env`, `server-a6000-48gb.env`, `server-blackwell-32gb.env`,
`server-blackwell-97gb.env`) remain as templates for new hardware. They ship
both chat engines disabled, because a template cannot know which you want; a
per-server profile is meant to be activated as-is and enables one.

## Several chat models on one box

`vllm`, `vllm2` and `vllm3` are three instances of one anchored definition,
differing only in name, port and `VLLM<N>_*` variables. A profile enables the
ones its card can hold:

```bash
ENABLE_VLLM=true
ENABLE_VLLM2=true              # 97 GB box only
VLLM2_MODEL=Qwen/Qwen3.6-35B-A3B-FP8
VLLM2_MODEL_NAME=qwen3.6-bulk
VLLM2_GPU_MEMORY_UTILIZATION=0.44
CONTRACT_BULK_MODEL=openai/qwen3.6-bulk
CONTRACT_BULK_API_BASE=http://vllm2:8000/v1
```

**VRAM is the profile's responsibility.** vLLM *preallocates*, and each
instance's `gpu-memory-utilization` is a fraction of the **whole card**, not of
what is left. Nothing stops a profile summing past 1.0 — the second or third
instance simply fails to start. On a 32 GB card one instance plus Infinity is
already the limit: delegate instead of splitting.

## Serving a different model

Every model-shape flag is **omitted entirely** when its variable is empty,
which is the only way some models work at all:

| Variable | Empty means |
|---|---|
| `VLLM_REASONING_PARSER` | non-thinking model. Left set, an Instruct model returns `content: null` with the answer in `reasoning_content` on every call |
| `VLLM_TOOL_CALL_PARSER` | no tool calling — also suppresses `--enable-auto-tool-choice`, which requires a parser |
| `VLLM_EXPERT_PARALLEL` | dense (non-MoE) model |
| `VLLM_PREFIX_CACHING`, `VLLM_CHUNKED_PREFILL` | disabled |
| `VLLM_STRUCTURED_OUTPUTS_CONFIG` | no xgrammar JSON enforcement |
| `VLLM_EXTRA_ARGS` | appended verbatim, for anything unmodelled |

Two knobs that are not about model *shape* but matter as much:

| Variable | Effect |
|---|---|
| `VLLM_KV_CACHE_DTYPE=fp8` | halves bytes per KV token, so the same VRAM holds ~2× the cache. Measured on sm_120: 83,520 → 173,856 tokens, concurrency at 32k 2.55× → 5.31×. Use it when the workload is concurrency-bound |
| `VLLM_GPU_MEMORY_UTILIZATION` | a fraction of the **whole** card, preallocated. Leave room for every other service on that GPU |

## Delegating a role to another box

A card that cannot serve a role points it at a peer. Addresses come from the
fleet block in `.env`, so no profile repeats an IP:

```bash
CONTRACT_BULK_API_BASE=${GPU_85_URL}/v1
CONTRACT_BULK_MODEL=openai/qwen3.6
CONTRACT_BULK_API_KEY=${GPU_85_KEY}
```

`/v1` is required for chat and vision bases; the embed and rerank bases must
**not** have it, because LiteLLM appends that path itself. A role that is
deliberately unserved goes in `CONTRACT_UNSERVED_ROLES` so `deploy.sh` can tell
"not served here" from "forgotten".

## Blackwell (sm_120) gotchas

- **Pin the vLLM build your card is known to work with** via `VLLM_IMAGE`.
  The 32 GB profiles use `v0.25.1` because ember had already proven it there.
  This is not evidence the `v0.23.0` default fails on Blackwell — crimson-llm2
  serves Qwen3.6-35B on `v0.23.0` on an RTX PRO 6000 (sm_120) today.
- **No published TEI image has sm_120 kernels** — ghcr carries turing / 89 /
  hopper / latest, and the container crash-loops with `Runtime compute cap 120
  is not compatible with compile time compute cap 80`. A locally built one does
  work (`osint/tei:1.9.3-sm120` on crimson-llm2). Infinity is preferred anyway:
  no custom image, and it serves the reranker from the same container.
