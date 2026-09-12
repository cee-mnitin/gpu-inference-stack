# Thirteen published aliases, all dead — and why deleting them was wrong

**Status:** implemented 2026-09-12
**Touches:** `config/litellm/config.yaml`, `docker-compose.yml`,
`servers/common-blackwell-32gb.env`, `scripts/health-check.sh`,
`scripts/tests/test_published_aliases.sh`, `.env`

## What was wrong

ddai4 published nineteen aliases in `/v1/models`. Probed one by one, **thirteen
returned HTTP 500 or 404**:

| family | count | why it was dead |
|---|---:|---|
| `qwen3.6-*` vLLM | 5 | asked for served model `qwen3.6`; this engine serves `qwen3.6-35b-a3b` |
| `*-ollama-docker` | 2 | `ENABLE_OLLAMA=false` — no container |
| `*-ollama-native` | 4 | no native Ollama on `:11437` |
| `bge-*-native` | 2 | cruxint's TEI pair exists only on server-85 |

`config/litellm/config.yaml` already argues, at length, that this exact state is
the thing to avoid — a consumer *routes around* a missing alias but *breaks* on
a published one that does not answer, having no way to tell "unserved" from
"serving badly". It made that argument only about the six contract aliases and
left thirteen others as literals, which a box has no way to switch off.

## Why not just delete them

They carry real traffic on another box. `servers/server-85.env` pins
`VLLM_PORT=11502`, `VLLM_ROUTER_PORT=11500`, `OLLAMA_PORT=11437` and
`VLLM_MODEL_NAME=qwen3.6` *specifically* to keep these names resolving, and
says so: "260 of the last 290 gateway requests were openai/qwen3.6. Renaming it
is the single most breaking change available here."

So this is not dead code. It is a live contract for one box that had become a
liability for every other box.

## The fix

The one the optional contract roles already use: **an env-driven `model_name`
with a historical default.** A box that cannot serve an alias moves it to the
`unserved/` namespace, which publishes the deployment outside the consumable
one — still introspectable in `/v1/models` for debugging, invisible to a
consumer looking for something to route to.

Defaults are the historical names, so **server-85 is unchanged by this.**
`servers/common-blackwell-32gb.env` unserves the ten aliases it has no backend
for.

The served *model* name was the other half, and the more interesting one:
`openai/qwen3.6` was correct on server-85 and wrong on every Blackwell box.
`LEGACY_VLLM_MODEL` now defaults to `openai/${VLLM_MODEL_NAME}`, so each box
asks its own engine for the name that engine actually answers to. That change
alone took three of the thirteen from broken to working — the compose-network
vLLM aliases were never pointing at the wrong *place*, only asking for the
wrong *name*.

Result on ddai4: **0 dead aliases.** Six contract + three working legacy +
ten `unserved/`.

## Two guards, because the static one cannot see a dead backend

`scripts/tests/test_published_aliases.sh` (no docker, no network) asserts that
no `model_name:` is a literal, that no entry hardcodes `openai/qwen3.6`, that
every `os.environ/` name is forwarded by compose, that every forwarded variable
has a default, and that the Blackwell profile unserves its ten. The three
*required* chat roles are exempt and stay literal: a box that cannot serve
`gpu/chat/{interactive,bulk,fast}` is not a GPU stack, and consumers refuse to
boot on their absence rather than routing around them — making them switchable
would only offer an operator a way to publish a stack nobody can use.

`scripts/health-check.sh` covers what a static test cannot: it now probes every
published alias *outside* the `gpu/` and `unserved/` namespaces and names any
that do not answer. A dead legacy alias is a **warning**, not a failure — it
breaks no contract and a box mid-migration may legitimately carry one. It must
simply never again be invisible. A `400` counts as alive: an embedding
deployment refusing a chat body is a live backend, not a missing one.

## Also corrected here

`.env` on this box described a machine that no longer exists — it specified
Qwen3-8B-FP8 and argued *against* the 35B-A3B ("~35 GB of weights and this box
has 32 GB total"), and budgeted ~9.5 GB for an Ollama vision model. That
arithmetic assumed FP8 weights; in NVFP4 the same 35B-A3B loads in 20.4 GiB,
which is what made the swap possible, and vision moved onto that model because
it is itself multimodal. The next operator reading those paragraphs beside a
running engine would have drawn the wrong conclusion about what this box can
hold.
