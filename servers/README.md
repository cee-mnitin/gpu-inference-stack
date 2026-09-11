# Server Profiles

One knob activates a machine. Put this in `.env`:

```bash
SERVER_PROFILE=63          # -> servers/server-63.env
```

Then use `scripts/deploy.sh` to bring it up, or `scripts/dc.sh` for anything
ad-hoc. **A bare `docker compose` does not see the profile** — it reads `.env`
only, so every profile value falls back to a compose default written for a
different class of card.

```bash
scripts/dc.sh ps
scripts/dc.sh logs -f litellm
scripts/dc.sh config | less
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
