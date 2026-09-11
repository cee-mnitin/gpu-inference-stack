# Portable across servers and models

**Status:** implemented
**Date:** 2026-09-10

## Problem

The stack is meant to run on every GPU server in the fleet, each with different
hardware, serving different weights, while presenting one unchanging contract
(`gpu/<task>/<role>`) to consumers. Today it cannot, for four reasons — three
config gaps and one live breakage.

### 1. The contract is published but not wired (LIVE BREAKAGE)

`config/litellm/config.yaml` reads twelve variables:

    CONTRACT_{INTERACTIVE,BULK,FAST}_{MODEL,API_BASE}
    CONTRACT_VISION_{ALIAS,MODEL,API_BASE}
    CONTRACT_{EMBED,RERANK,OCR}_API_BASE

`docker-compose.yml` passes **none** of them to the litellm container. Every
one of the six contract aliases therefore resolves to an unset `model` and
`api_base`: LiteLLM still lists them in `/v1/models`, and every request to them
fails. From a consumer's side that is indistinguishable from a healthy stack
serving a broken model.

`scripts/deploy.sh` cannot catch it. Its guard (`fix(deploy): refuse a stack
that publishes a chat role it cannot serve`) checks the variables are **set in
the environment**, which they are — it has no way to know the container never
receives them.

`config/litellm/config.yaml` also routes embed and rerank at
`infinity/BAAI/...`, but there is no `infinity` service in the compose file.

### 2. Model-shape flags are hardcoded

The vllm command ends with a fixed tail:

    --enable-expert-parallel --enable-auto-tool-choice
    --tool-call-parser qwen3_xml --reasoning-parser qwen3

Each is wrong for some model the fleet needs to serve:

- `--enable-expert-parallel` is **MoE-only**. It has no meaning for a dense
  model.
- `--reasoning-parser qwen3` breaks every **non-thinking** model. Measured on
  ddai3 with Qwen3-30B-A3B-Instruct-2507: because no closing `</think>` ever
  arrives, vLLM treats the whole completion as unterminated reasoning and
  returns `content: null` with the answer in `reasoning_content`, on **5 of 5**
  calls. A consumer reading `choices[0].message.content` gets nothing and sees
  an empty answer rather than an error.
- `--tool-call-parser qwen3_xml` is a per-family choice, and a model with no
  tool support should have neither it nor `--enable-auto-tool-choice`.

A YAML-list `command:` cannot express "omit this flag": an env var expanding to
`""` still produces an empty argv entry, which vLLM rejects. So there is no
value of any variable that makes a non-thinking model work.

### 3. The image is pinned in the file, not the profile

`image: vllm/vllm-openai:v0.23.0` is hardcoded, so a box cannot pin the build
its card is known to work with. Which vLLM build a box needs is a property of
its GPU, i.e. of its server profile.

*Corrected 2026-09-11:* this was first written as "0.23 predates Blackwell and
does not degrade gracefully". A live inspection of crimson-llm2 shows v0.23.0
serving Qwen3.6-35B on an RTX PRO 6000 Blackwell (sm_120, driver 570) today.
0.23 was never tested on the 32 GB cards; v0.25.1 is pinned there because ember
had already proven it, which is a "known-good" argument, not evidence the older
build fails.

### 4. No embedder works on Blackwell

No *published* `text-embeddings-inference` image carries `sm_120` kernels —
ghcr has turing / 89 / hopper / latest — and the container crash-loops with
`Runtime compute cap 120 is not compatible with compile time compute cap 80`.
Infinity's torch engine runs there, and serves bge-m3 and bge-reranker-v2-m3
from one container, which is what `config/litellm/config.yaml` already expects.

*Corrected 2026-09-11:* a locally built TEI **does** run on Blackwell —
crimson-llm2 uses `osint/tei:1.9.3-sm120`. So the accurate statement is that no
upstream tag works, not that TEI cannot. Infinity is still preferred: no custom
image to maintain, and one container covers both the embed and rerank roles.

## Design

**Pass the contract through, with defaults.** Restore the twelve
`CONTRACT_*` variables on the litellm service, each defaulting to this box's
local topology (`http://vllm:8000/v1`, `http://infinity:7997`) and to
`openai/${VLLM_MODEL_NAME}` for the chat roles, so a box that sets only
`VLLM_MODEL`/`VLLM_MODEL_NAME` gets a working contract with no further edits.

**Make every model-shape flag omittable.** Switch the vllm `command` to shell
form (`entrypoint: ["/bin/sh","-lc"]`, then `exec vllm serve …`) so flags can
use `${VAR:+--flag "$VAR"}`. Empty or unset means the flag is not emitted at
all. Tool-call parsing couples the two flags that must agree:

    ${VLLM_TOOL_CALL_PARSER:+--enable-auto-tool-choice --tool-call-parser "$VLLM_TOOL_CALL_PARSER"}

so `--enable-auto-tool-choice` can never appear without the parser it requires.
`VLLM_EXTRA_ARGS` is appended last for anything not modelled here.

Defaults preserve today's behaviour exactly (`qwen3_xml`, `qwen3`, expert
parallel and both caches on), so no existing profile changes meaning. A box
serving a dense or non-thinking model sets the relevant variable empty.

**Move the image to the profile.** `VLLM_IMAGE`, defaulting to the current pin.

**Restore the infinity service** behind an `infinity` profile, and keep the
TEI-based `embeddings` service for cards where TEI works. They are alternatives;
`CONTRACT_EMBED_API_BASE` / `CONTRACT_RERANK_API_BASE` decide which is in use.

**Add a wiring preflight** — `scripts/check-contract-wiring.sh`. It extracts
every `os.environ/NAME` from `config/litellm/config.yaml` and asserts the
litellm service in the rendered compose config actually passes that name. This
is the check that would have caught breakage #1, and it catches the general
class: a config file and a compose file drifting apart. `deploy.sh` runs it
before starting anything.

## Non-goals

Multi-GPU scheduling, autoscaling, and model downloading remain out of scope.
This spec is about a box being able to state what it serves, and the stack
refusing to lie about it.

---

# Part 2 — one knob per server

Added the same day, after Part 1 made the stack *capable* of describing
different hardware but left no clean way to *select* a description.

## Problem

Profiles were applied by `cp servers/server-x.env .env`. That forks the profile
the instant anything is tuned: the box drifts from the committed file and
nothing can say how. It also meant the four machines' configurations lived
nowhere reviewable — each existed only as whatever had been copied and then
edited on that host.

Two further gaps blocked cross-server work:

- **No shared way to name a peer.** `server-blackwell-97gb.env` carried a
  commented `CONTRACT_BULK_API_BASE=http://100.117.227.40:8080/v1`, so
  delegating a role meant hardcoding an address in a profile, and every profile
  that delegated repeated it.
- **`api_key` was the literal `"EMPTY"`** for all three chat roles and vision.
  Fine for a local engine; fatal for delegation, because a peer's LiteLLM
  requires a real key and 401s. Cross-server delegation could not work at all.

## Design

**`SERVER_PROFILE=<name>` in `.env` selects `servers/server-<name>.env`.**
Scripts layer it under `.env`:

    docker compose --env-file servers/server-<name>.env --env-file .env …

Compose unions the keys and the last file wins (verified on compose 5.1.4), so
the committed profile is authoritative for hardware, models, VRAM split, ports
and role wiring, while `.env` keeps only what is per-host: the profile name,
the fleet block, secrets and host paths.

The precedence cuts both ways, and that is the one sharp edge: **anything
uncommented in `.env` beats the profile.** It is how a host keeps a deliberate
one-off, and it is why every profile-owned key ships commented out in
`.env.example` — 68 of them. An uncommented copy of a profile's key silently
defeats profile selection, which is exactly the failure this layout exists to
prevent, so the template must not hand anyone that footgun.

`scripts/lib-profile.sh` resolves the profile; `scripts/dc.sh` is the wrapper
for ad-hoc commands. A bare `docker compose` sees only `.env`, so profile
values silently fall back to compose defaults written for another card — the
helper prints that warning and `dc.sh` exists so nobody needs to remember the
flags. A `SERVER_PROFILE` naming a file that does not exist is a hard error
everywhere, never a fallback.

**The fleet block.** `GPU_<octet>_URL` / `GPU_<octet>_KEY` for all four
machines, in `.env`, byte-identical on every box. Named by the last octet of
the Netbird address, because hardware gets replaced and roles move but the
address is what a peer dials. The port is part of the value: `.63` runs on 8090
since the shared platform's traefik holds 8080 there. A profile refers to these
by name, so no profile repeats an address:

    CONTRACT_BULK_API_BASE=${GPU_85_URL}/v1
    CONTRACT_BULK_API_KEY=${GPU_85_KEY}

Adding a fifth server is one edit to a block that is then copied unchanged,
rather than a change to every host.

**`api_key` per role, from the environment**, defaulting to `EMPTY` in compose.
That is what makes delegation possible; the keys are virtual keys minted on
each peer, never a peer's master key.

**Several chat models per box.** `vllm`, `vllm2`, `vllm3` are three instances
of one YAML-anchored definition, differing only in container name, published
port and their `VLLM<N>_*` variables. Each instance maps its own variables onto
the same internal names the shared command reads, which is what lets one
command definition serve all three — the flag-omission logic from Part 1 is
subtle enough that three copies would not stay in step.

VRAM remains the profile's responsibility, stated in every profile that could
get it wrong: vLLM preallocates, and each instance's utilization is a fraction
of the whole card, not of what is left. Nothing prevents a profile summing past
1.0 — the later instance simply fails to start. Only the 97 GB box has room for
two; the 32 GB boxes run one and delegate.

## The four profiles

| Profile | Host | GPU | Engine |
|---|---|---|---|
| `40` | dd4-skynet | A6000 48 GB, sm_86 | llama.cpp, Qwen3-Next-80B Q3 |
| `63` | ddai3 | RTX PRO 4500 32 GB, sm_120 | vLLM, Qwen3-30B-A3B AWQ |
| `72` | ddai5 | RTX PRO 4500 32 GB, sm_120 | vLLM, same |
| `85` | crimson-llm2 | RTX PRO 6000 97 GB, sm_120 | vLLM ×2 |

`63` and `72` are deliberately near-identical: `diff` between them shows only
`SERVER_NAME` and `LITELLM_PORT`, which is the point — anything else appearing
in that diff is drift worth explaining.

The hardware-class templates remain, for new hardware. They ship both chat
engines disabled because a template cannot know which you want; a per-server
profile is activated as-is and enables one.

## Verified

All four profiles render their own gateway address/port, models, role wiring
and instance count, with `.env` trimmed to per-host state on ddai3. The live
ddai3 stack was brought up through the layered path and serves all five of its
roles — three chat with zero reasoning leakage, 1024-dim embeddings, correct
rerank ordering — with vision correctly published as `unserved/vision`. A
nonexistent `SERVER_PROFILE` fails loudly. `check-contract-wiring.sh` confirms
all 16 `os.environ/` names reach the container, and was re-tested against a
deliberately regressed compose to confirm it still fails.

Also fixed here: Part 1's command rework had dropped
`--structured-outputs-config`, losing xgrammar JSON enforcement that the
contract's chat roles promise. Restored, conditionally, and passed per instance.
