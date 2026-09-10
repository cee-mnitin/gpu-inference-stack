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

`image: vllm/vllm-openai:v0.23.0` is hardcoded. 0.23 predates Blackwell
(`sm_120`) and does not degrade gracefully, so the five `ddai*` boxes cannot
run the stack as committed. Which vLLM build a box needs is a property of its
GPU, i.e. of its server profile.

### 4. No embedder works on Blackwell

`text-embeddings-inference` publishes turing / 89 / hopper / latest and nothing
for `sm_120`; it crash-loops with `Runtime compute cap 120 is not compatible
with compile time compute cap 80`. Infinity's torch engine runs there, and
serves bge-m3 and bge-reranker-v2-m3 from one container — which is what
`config/litellm/config.yaml` already expects.

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
