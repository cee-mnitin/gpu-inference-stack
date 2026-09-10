# Design: `llamacpp` service — a third inference runtime

**Date:** 2026-09-10
**Status:** Approved design, pending implementation plan
**Scope:** Add a llama.cpp `llama-server` backend to the stack, able to serve
either Qwen3-Next-80B-A3B or Qwen3.8-Flash-Next depending on the box.

---

## 1. Goal

Add one profile-gated `llamacpp` service whose **weights are chosen by
`.env`**, so that:

- the **RTX A6000 48GB** box (`sm_86`) runs **Qwen3-Next-80B-A3B**
  (`UD-Q3_K_XL`, 33.19 GiB) and fills every chat role of the
  `gpu/<task>/<role>` contract;
- the **RTX PRO 6000 Blackwell Max-Q 97GB** box (`sm_120`) runs
  **Qwen3.8-Flash-Next** (UD-IQ3_XXS, 76.3 GiB) as a deep / long-context /
  vision deployment.

This is the stack's existing premise applied to a new runtime: *consumers
choose a capability tier, deployments choose the weights.* The runtime is now
part of what a deployment chooses, alongside the image and the weights.

## 2. Findings that constrain this design

Established by investigation on 2026-09-10. These are the reasons the design
looks the way it does; do not "simplify" them away without re-checking.

### 2.1 The reference repo is the wrong engine and the wrong storage model

`lna-lab/flash-next-8gb` runs **ExLlamaV3 + EXL3 3.05bpw**, not llama.cpp. Its
whole technique is streaming the 51B n-gram (PLE) table off **NVMe** at
~2.7 KB/token from deterministic addresses.

The A6000 box has **no NVMe** — `/dev/sda` is a rotational SAS logical volume
(`/sys/block/sda/queue/rotational` = 1). Disk-streaming the PLE table there
would be seek-bound. It also does not need to: 251 GB RAM holds the whole
quantized table resident. **We do not adopt the disk-streaming approach.**

### 2.2 llama.cpp support is real, young, and partly broken

| Component | State (2026-09-10) |
| --- | --- |
| `qwen4exp` architecture | Merged 2026-08-27, PR ggml-org/llama.cpp#27742 |
| 51B PLE / n-gram table | **Issue #28355 OPEN** (filed 2026-09-04): table not loaded after build **10665**, causing extremely slow prefill |
| MTP speculative decoding | **Not in mainline.** PR #28243 still a *draft* |
| Quantized KV cache | Contested: #27742 reports `-ctk/-ctv q8_0` assertion failures; a working 4090 config uses q8_0 anyway |
| `-sm tensor` | Incompatible with the hyper-connection layout |

Consequences: **pin the image to build 10665**, **default KV to f16**, and
**leave MTP out of scope**.

### 2.3 MTP is not worth carrying

Beyond being unmerged: measured acceptance swings from 0.32–0.38 (net *slower*
decode) to 0.77–0.93 depending on hardware, and PR #28243 itself records
stability concerns on **RTX Blackwell** — which is precisely the box that would
run Flash-Next. Upstream H100 measurements had MTP reducing throughput 8–36%
and raising per-token latency 32–173% at ~36% acceptance.

### 2.4 `sm_86` is why llama.cpp is the right runtime here

The A6000 is Ampere: no FP8/FP4 tensor cores. Qwen's own deployment guidance
targets vLLM / SGLang / TokenSpeed and leans on NVFP4 quants this card cannot
run natively, and vLLM's host-memory PLE prefetch is still an open feature
request (vllm-project/vllm#53908). llama.cpp's `-ncmoe` / `-ot` CPU-offload
path is the mature option for this model shape.

### 2.5 `llama-server` covers the contract surface

`--jinja` tool calling, `response_format: json_schema`, `chat_template_kwargs`
accepted in the request body, `/v1/models`, `/v1/chat/completions`, `/health`.
No capability gap against `gpu/chat/*`.

Note one difference from vLLM: `llama-server` serves a single model and does
**not** 404 on a mismatched `model` field. A wrong `--alias` is therefore
benign here, unlike a wrong `--served-model-name` on vLLM.

### 2.6 Configuration is by environment variable, not command line

**Verified against `server-cuda-b10884` on 2026-09-10.** `llama-server`
exposes `LLAMA_ARG_*` environment variables for **138** flags, including every
one this design needs: `LLAMA_ARG_MODEL`, `_ALIAS`, `_HOST`, `_PORT`,
`_N_GPU_LAYERS`, `_N_CPU_MOE`, `_CTX_SIZE`, `_N_PARALLEL`, `_FLASH_ATTN`,
`_CACHE_TYPE_K/V`, `_ENDPOINT_METRICS`, `_JINJA`, `_OVERRIDE_TENSOR`,
`_LOAD_MODE`, `_LAZY_MODE`, `_FIT`, `_FIT_TARGET`, `_FIT_CTX`,
`_KV_UNIFIED_PER_SLOT`, `_THREADS`, `_MMPROJ`, `_REASONING`, `_CACHE_REUSE`.

This supersedes the command-string approach: the service takes **no `command:`
at all** and is configured entirely through `environment:`. That removes the
compose word-splitting fragility this repo has already been burned by (see the
`VLLM_*_FLAG` comments in `docker-compose.yml`), and gives every knob a name
with a compose-native default.

### 2.7 Three flag defaults are actively dangerous here

1. **`-fit` defaults to `on`** — llama.cpp adjusts *unset* arguments to fit
   device memory, and `--fit-ctx` (default 4096) is the floor it may shrink
   context to. A box that leaves `--ctx-size` unset can therefore come up
   serving **4k** while `/v1/models` and a small health probe both look fine.
   Setting `--ctx-size` explicitly immunises it, because fit only touches
   *unset* args. Left that way, `fit on` becomes an asset: it auto-tunes
   `-ngl`/`-ncmoe` against whatever VRAM Infinity is actually using, which a
   hardcoded `-ncmoe` cannot do.

2. **`-lzm/--lazy-mode` defaults to `auto`** = "read the rows of tensors larger
   than 4 GiB from disk on demand instead of keeping them resident (requires
   mmap)". On the A6000 box — rotational SAS, no NVMe (§2.1) — this is the
   worst available behaviour. **`LLAMA_ARG_LAZY_MODE=off` is mandatory here.**
   It is also a plausible mechanism for issue #28355's "extremely slow
   prefill" symptom on the 51B PLE table; worth testing on a current build
   before assuming the b10644 pin is permanent.

3. **`--kv-unified-per-slot N` is a CAP, not a floor** — the opposite of what
   its name suggests and of what this design initially assumed. Verified on
   b10884, the server logs:

   ```
   srv load_model: capping per-slot context (131072) to --kv-unified-per-slot (32768)
   ```

   Set to the contract *minimum* it can only ever REDUCE context. On the
   Blackwell profile (1 slot, 131072) it silently produced 32768 — a 4x loss
   of exactly the long-context capability that deployment exists for — and an
   assertion checking `>= 32768` passes it.

   So it is **not wired into the service at all**. `--ctx-size` and
   `--parallel` already determine per-slot context exactly, and
   `LLAMACPP_CTX_PER_SLOT` survives only as `health-check.sh`'s floor value.

   Separately and benignly, llama.cpp also caps slot context to the model's
   *training* context. Both models here natively support 262144, so this only
   matters if the service is pointed at a short-context model.

### 2.8 Healthcheck binaries: verified, not assumed

`server-cuda-b10884` contains **`curl`, `python3`, `bash`**; `wget` and `nc`
are absent. The healthcheck therefore uses `curl -f`. This was checked rather
than assumed, because this repo has already shipped three fixes for probes
that referenced absent binaries.

## 3. Non-goals

- **MTP / speculative decoding.** Out of scope per §2.3. Reachable later as a
  one-variable experiment (`LLAMACPP_SPEC_TYPE`) once #28243 merges.
- **PLE streaming from disk.** Out of scope per §2.1.
- **Replacing vLLM as the stack default.** vLLM stays the default engine;
  llama.cpp is opt-in per box.
- **Fixing the pre-existing `Qwen3.6-35B-A3B-FP8`-on-`sm_86` question** (no
  native FP8 path on Ampere). Noted, not addressed here.

## 4. The service

New `llamacpp` service in `docker-compose.yml`, `profiles: [llamacpp]`.

**Port 8083** on the host → 8080 in-container. Verified free: 11434 (ollama),
8000 (vllm), 8001 (vllm-router), 8082 (embeddings), 7997 (infinity), 8080
(litellm), 6379, 9090, 3000, 9100, 9400, 9121, 80/443 are all taken.

### 4.1 Image, pinned

**Build 10665 has no published image.** `docker pull
...:server-cuda-b10665` returns `manifest unknown`. Enumerating the registry
(11,394 tags, paginated) shows images exist for only 521 of the `server-cuda-b*`
builds; the ones bracketing 10665 are **b10644** and **b10666**.

```
image: ${LLAMACPP_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda-b10884}
```

The default is **b10884** — the newest published build, and the one actually
pulled and flag-verified on the A6000 box (§2.6, §2.8). It is the correct
default because the A6000 runs Qwen3-Next-80B-A3B, whose support landed at
b7186 and which is **not** affected by issue #28355.

The **Blackwell profile pins `b10644`** instead, with a comment naming issue
#28355: it is the newest published build at or below the known-good 10665.
b10666 is deliberately not used — it is one build past the last known-good
number, so it may be the regression itself.

Putting the conservative pin on the profile that needs it, rather than in the
compose default, means the shipped default is a build that was actually
verified on real hardware instead of one chosen from a bug report.

### 4.2 Configuration: `environment:`, no `command:`

Per §2.6 the service passes **no `command:`**. Every knob is a
`LLAMA_ARG_*` entry with a `LLAMACPP_*` compose default, so a box overrides one
variable in `.env` rather than editing an argument string:

| `LLAMA_ARG_*` | compose default | why |
| --- | --- | --- |
| `MODEL` | `/models/${LLAMACPP_MODEL_FILE}` | required; no default |
| `ALIAS` | `${LLAMACPP_MODEL_NAME:-llamacpp}` | LiteLLM's `openai/<name>` target |
| `HOST` / `PORT` | `0.0.0.0` / `8080` | fixed in-container |
| `CTX_SIZE` | `${LLAMACPP_CTX_SIZE:-131072}` | **explicit, to immunise against `fit` (§2.7.1)** |
| `N_PARALLEL` | `${LLAMACPP_PARALLEL:-4}` | 131072/4 = 32768 per slot = contract floor |
| `KV_UNIFIED_PER_SLOT` | `${LLAMACPP_CTX_PER_SLOT:-32768}` | states the contract floor directly |
| `LAZY_MODE` | `${LLAMACPP_LAZY_MODE:-off}` | **mandatory `off` here (§2.7.2)** |
| `LOAD_MODE` | `${LLAMACPP_LOAD_MODE:-mmap}` | rotational disk; see §2.1 |
| `FIT` | `${LLAMACPP_FIT:-on}` | auto-tunes `ngl`/`ncmoe` to real free VRAM |
| `FIT_TARGET` | `${LLAMACPP_FIT_TARGET:-2048}` | MiB margin left per device |
| `FIT_CTX` | `${LLAMACPP_FIT_CTX:-131072}` | belt-and-braces floor if `-c` is ever unset |
| `N_CPU_MOE` | `${LLAMACPP_NCMOE:-}` | **unset by default** — let `fit` decide; set to pin it |
| `N_GPU_LAYERS` | `${LLAMACPP_NGL:-}` | unset by default, same reason |
| `FLASH_ATTN` | `${LLAMACPP_FLASH_ATTN:-on}` | |
| `CACHE_TYPE_K` / `_V` | `${...:-f16}` | f16 default per §2.2 |
| `THREADS` | `${LLAMACPP_THREADS:-16}` | matters only when `ncmoe` > 0 |
| `CACHE_REUSE` | `${LLAMACPP_CACHE_REUSE:-256}` | llama.cpp's analogue of vLLM prefix caching |
| `ENDPOINT_METRICS` | `1` | Prometheus scrape target (§8) |
| `JINJA` | `1` | tool calling; already default-enabled in b10884 |
| `OVERRIDE_TENSOR` | `${LLAMACPP_OVERRIDE_TENSOR:-}` | Blackwell PLE offload only |
| `MMPROJ` | `${LLAMACPP_MMPROJ:-}` | Blackwell vision only |
| `REASONING` | `${LLAMACPP_REASONING:-auto}` | emits `reasoning_content`, not raw `<think>` |

**Correction (verified on b10884): an empty `LLAMA_ARG_*` value is NOT treated
as unset.** `llama-server` parses it and exits:

```
error while handling environment variable "LLAMA_ARG_N_CPU_MOE": invalid value
```

With `restart: unless-stopped` that becomes a crash loop rather than a visible
one-shot failure. Tested across 15 variables: every numeric and enum one
rejects empty; only `MMPROJ` and `ALIAS` tolerate it.

So the four variables that default to empty use compose's pass-through form
instead, which omits the variable entirely:

```yaml
- LLAMA_ARG_N_CPU_MOE${LLAMACPP_NCMOE:+=${LLAMACPP_NCMOE}}
```

When `LLAMACPP_NCMOE` is empty this renders as the bare name
`LLAMA_ARG_N_CPU_MOE`, which compose resolves from the host environment — and
since it is not there, the variable never reaches the container. When set it
renders as `LLAMA_ARG_N_CPU_MOE=6` as normal. Verified both ways: one
`LLAMA_ARG_*` in the container env when empty, three when set.

Leaving `N_CPU_MOE` and `N_GPU_LAYERS` unset by default is a deliberate
production choice. `fit on` measures free VRAM at boot, so the service adapts
when Infinity's footprint moves; a hardcoded `-ncmoe` tuned once goes stale and
fails closed (OOM) rather than degrading. Operators who need bit-reproducible
startup pin both.

### 4.3 Volumes, GPU, logging

```
volumes:  ${LLAMACPP_MODELS_DIR:-./data/llamacpp/models}:/models:ro
devices:  ['${LLAMACPP_GPU_DEVICES:-${GPU_DEVICES:-0}}']
logging:  json-file, MAX_LOG_SIZE / MAX_LOG_FILES  (as every other service)
```

`:ro` — the server has no reason to write to the weights directory.
`LLAMACPP_GPU_DEVICES` defaults to `GPU_DEVICES` so a multi-GPU box can pin
llama.cpp and vLLM to different cards (see §5).

### 4.4 Healthcheck

`start_period: ${LLAMACPP_START_PERIOD:-900s}` — 15 minutes, longer than
vLLM's 600s. Reading a 76 GiB GGUF off the rotational SAS array at plausible
sequential throughput is 5–9 minutes before any warmup.

Probe is `curl -f http://localhost:8080/health`. Per §2.8 this was **verified
by inspecting the pinned image**, not assumed — `curl` and `python3` are
present, `wget` and `nc` are not. The comment beside the healthcheck records
that check, so a future image bump knows to re-run it.

## 5. Engine exclusivity

Neither box can host both engines:

| Box | llama.cpp weights | + vLLM | VRAM | Fits? |
| --- | --- | --- | --- | --- |
| A6000 48 GB | 80B `UD-Q3_K_XL` 33.19 GiB | +31 GB | 48 GB | no |
| Blackwell 97 GB | Flash-Next IQ3_XXS 76.3 GiB | +31 GB | 97 GB | no |

`scripts/deploy.sh` therefore **hard-errors and exits non-zero** when
`ENABLE_VLLM=true` and `ENABLE_LLAMACPP=true` are both set, with
`ALLOW_VLLM_LLAMACPP_COTENANCY=1` as a documented escape hatch for a box that
has genuinely pinned them to different `*_GPU_DEVICES`.

Rationale: two engines contending for one card does not fail cleanly. It OOMs
mid-request or thrashes, which surfaces to a consumer as intermittent
5xx/timeouts rather than as a configuration error. Fail at deploy time,
loudly.

`deploy.sh` additionally **warns** (does not fail) when *neither* is enabled,
because the three required `gpu/chat/*` contract roles are then unserved and
`health-check.sh` will report contract failures.

### 5.1 Both engines ship disabled

`ENABLE_LLAMACPP=false` in `.env.example`, and **both new server profiles ship
with `ENABLE_VLLM=false` and `ENABLE_LLAMACPP=false`**. The operator enables
exactly one engine for the box they are on.

This makes the §5 conflict unreachable in the shipped state rather than merely
guarded against, and it means copying a profile never starts a multi-hour
model load by surprise. Each profile header states which engine that box is
intended to run and what to flip.

## 6. Contract hazard: context is divided across slots

`llama-server --ctx-size` is the **total** KV pool, split across `--parallel`
slots. `-c 32768 -np 4` gives each slot **8k**.

The contract promises **>=32k** on `gpu/chat/interactive` and
`gpu/chat/bulk`, **>=16k** on `gpu/chat/fast`. So a naive `-c 32768` is a
silent contract violation of the exact shape this codebase keeps fixing:
`/v1/models` lists the alias, the existing `health-check.sh` call probe sends a
small prompt and passes, and only real long prompts fail.

There are **three** independent routes into this violation, and all three
need closing:

1. **Arithmetic** — `-c` too small for `-np`. Closed by defaulting
   `LLAMACPP_CTX_SIZE=131072` against `LLAMACPP_PARALLEL=4`.
2. **`fit on` shrinking an unset `-c`** to as low as `--fit-ctx` (default
   4096), per §2.7.1. Closed by setting `--ctx-size` explicitly — `fit` only
   adjusts *unset* arguments — and by `FIT_CTX=131072` as a second line.
3. **Silent drift** — any future `.env` edit to `PARALLEL` or `CTX_SIZE`.
   Closed by a runtime assertion, below.

The runtime assertion: `health-check.sh` reads `llama-server`'s
`/props` (falling back to `/slots`, which is enabled by default), derives the
**per-slot** context, and **fails** when it is below 32768 while any
`gpu/chat/*` role is bound to the llamacpp backend. This is the only one of the
three that catches a drifted running system rather than a bad config, so it is
the load-bearing mitigation; the first two just make the default correct.

## 7. Role bindings per box

The topology inverts relative to today: the A6000 becomes the contract box and
the Blackwell box becomes a specialist. No YAML changes are needed — the
`CONTRACT_*_MODEL` / `CONTRACT_*_API_BASE` indirection in
`config/litellm/config.yaml` already carries this.

### 7.1 A6000 48 GB — Qwen3-Next-80B-A3B — the contract box

Fills **`interactive` + `bulk` + `fast`**. 3B active parameters, real
concurrency, tool calling, JSON, long context. llama.cpp support has been
stable since b7186 (PR #16095), unlike `qwen4exp`.

**Correction to earlier sizing: there is no MXFP4_MOE quant of this model.**
Neither `Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF` nor
`unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF` publishes one; the 40.73 GiB MXFP4
figure belonged to a different model. Real options, from the unsloth repo's
file listing:

| file | size | verdict |
| --- | --- | --- |
| `...-UD-Q3_K_XL.gguf` | **33.19 GiB** | **chosen** — fully GPU-resident |
| `...-Q3_K_M.gguf` | 35.67 GiB | fits, ~1 GiB spare — too tight |
| `...-IQ4_XS.gguf` | 39.72 GiB | documented alternative, needs offload |
| `...-Q4_K_S.gguf` | 42.38 GiB | needs ~6 GiB offloaded |
| `...-Q4_K_M.gguf` | 45.17 GiB | does not fit usefully |

VRAM budget, measured on this box (48086 MiB = 46.96 GiB free of 47.99 GiB
total; 392 MiB held by an unrelated process):

```
  Infinity (bge-m3 + bge-reranker-v2-m3)          ~3.0 GiB
  KV @ 131072 ctx, f16                            ~3.0 GiB
      12 of 48 layers are full-attention; 2 KV heads x 256 dim
      x 2 (K+V) x 2 B = 24.6 KB/token. The 36 Gated DeltaNet
      layers hold constant state, which is why 128k is affordable.
  graph / compute buffers + CUDA context          ~2.5 GiB
  safety margin                                   ~1.5 GiB
  ------------------------------------------------------------
  weights budget                                 ~36.9 GiB
```

`UD-Q3_K_XL` at 33.19 GiB fits with ~3.7 GiB spare, so `fit` should settle on
`ncmoe 0` — fully resident, which is where the decode speed is. Unsloth Dynamic
quants hold sensitive tensors at higher precision (the repo ships
`imatrix_unsloth.gguf_file`), so quality sits well above a vanilla Q3.

`IQ4_XS` (39.72 GiB) is the documented quality-first alternative; it needs
roughly 3 GiB offloaded, which `fit on` will arrange without a config change.
Both are **single files** — no multi-part assembly.

Exact source: repo `unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF`, file
`Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf`.

```
CONTRACT_INTERACTIVE_MODEL=openai/${LLAMACPP_MODEL_NAME}
CONTRACT_INTERACTIVE_API_BASE=http://llamacpp:8080/v1
# bulk, fast: same deployment
```

`Qwen3-Next-80B-A3B-Instruct` is a non-thinking model, so the
`chat_template_kwargs: {enable_thinking: false}` already set on `bulk`/`fast`
is inert — an unknown chat-template variable is ignored. No change needed.

**`gpu/chat/vision` is left unserved on this box.** The 80B is text-only, and
the VRAM budget above has no room for Ollama's ~10 GiB VL model on top of a
33 GiB resident chat model. So this profile sets `ENABLE_OLLAMA=false`. That is
the documented clean degradation: the alias is optional, and a consumer that
cannot find it routes vision to a cloud provider. Pointing it at something that
half-works would violate the stack's own rule.

### 7.2 Blackwell 97 GB — Qwen3.8-Flash-Next — deep / long-context / vision

76.3 GiB resident of 97 GB leaves ~20 GB for KV, so `-ncmoe 0` and low
offload. The hybrid layer mix helps: only the 12 QSA layers grow KV with
context; the 36 Gated DeltaNet layers hold constant state.

Fills **`interactive`** and, via `--mmproj`, **`gpu/chat/vision`** — an upgrade
on `gemma3:12b`, and one that removes the LiteLLM/Pillow dependency in that
path because a vLLM-shaped OpenAI backend is base64'd directly rather than
converted.

It does **not** fill `bulk` or `fast`: effectively single-slot, and `fast`
carries a 60s timeout. Per the stack's own rule — *a role you cannot serve
should be left unserved rather than pointed at something that half-works* —
this profile points those two roles at the A6000 instead:

```
CONTRACT_INTERACTIVE_MODEL=openai/${LLAMACPP_MODEL_NAME}
CONTRACT_INTERACTIVE_API_BASE=http://llamacpp:8080/v1
CONTRACT_VISION_MODEL=openai/${LLAMACPP_MODEL_NAME}
CONTRACT_VISION_API_BASE=http://llamacpp:8080/v1
CONTRACT_BULK_API_BASE=http://${A6000_HOST}:8080/v1
CONTRACT_FAST_API_BASE=http://${A6000_HOST}:8080/v1
```

`A6000_HOST` is the one value the operator must supply (LAN or Netbird address
of the A6000 box). It points at that box's **LiteLLM root on 8080**, not at its
llama.cpp on 8083 — the same "bare root, no `/v1` path" rule the README states
for consumers.

Cross-box role placement is exactly what the contract's server-addressed
indirection exists for. The profile ships with those two commented and a
header note that the box goes off-contract for `bulk`/`fast` until they are
filled.

This profile must override the §4.2 concurrency defaults, which are tuned for
the 80B: `LLAMACPP_PARALLEL=1` and `LLAMACPP_CTX_SIZE=131072` (one slot, 128k).
Long context is affordable here despite only ~20 GB of KV headroom because QSA
runs on a 2048-token budget and only 12 of 48 layers grow KV at all.

This box also sets, per §4.2's table:

```
LLAMACPP_OVERRIDE_TENSOR=per_layer_token_embd=CPU
LLAMACPP_MMPROJ=/models/mmproj-F16.gguf
LLAMACPP_LAZY_MODE=off        # see the #28355 hypothesis in §10.6
LLAMACPP_REASONING=auto
```

`LLAMA_ARG_REASONING` is the llama.cpp equivalent of vLLM's
`--reasoning-parser qwen3`: it emits `reasoning_content` on the OpenAI response
so LiteLLM surfaces it rather than leaking `<think>` into content.

## 8. Files touched

| File | Change |
| --- | --- |
| `docker-compose.yml` | new `llamacpp` service (§4) |
| `.env.example` | new `LLAMACPP CONFIGURATION` section; `ENABLE_LLAMACPP=false`; contract-binding examples |
| `servers/server-a6000-48gb.env` | **new** — 80B, contract box, both engines off |
| `servers/server-blackwell-97gb.env` | **new** — Flash-Next, deep/vision, both engines off |
| `servers/server-high-vram.env` | fix `GPU_VRAM_TOTAL=96` drift |
| `scripts/deploy.sh` | `llamacpp` profile; exclusivity guard; no-engine warning (§5) |
| `scripts/health-check.sh` | `llamacpp` service probe; `/props` context-per-slot warning (§6) |
| `config/prometheus/prometheus.yml` | scrape job for `llamacpp:8080/metrics` |
| `config/litellm/config.yaml` | **no change** — indirection already suffices |
| `README.md`, `servers/README.md`, `docs/SETUP.md` | runtime-choice docs; model acquisition |

### 8.1 Model acquisition

Documented, not automated (these are 40–76 GiB multi-part GGUF downloads):
`hf download` per box into `LLAMACPP_MODELS_DIR`, with a note that first load
off the A6000 box's SAS array is slow and that 845 GB free is ample for either
model.

## 9. Testing strategy

- `docker compose config` — proves the `environment:` block resolves, that
  optional variables render as empty strings rather than literal `${...}`, and
  that no `command:` is present.
- **Already done (2026-09-10):** image `server-cuda-b10884` pulled, binaries
  inspected (§2.8), every `LLAMA_ARG_*` name confirmed against `--help` (§2.6),
  and the `-fit` / `-lzm` defaults read (§2.7). The Blackwell pin **b10644**
  still needs the same pass on that box before its profile is used.
- Arch check, mirroring the documented vLLM one, on both boxes.
- `deploy.sh`: both-enabled errors; neither-enabled warns; one-enabled starts
  the right profile set.
- `health-check.sh`: service probe passes; the §6 warning fires on a
  deliberately bad `-c`/`-np` pair.
- End-to-end through LiteLLM: a real tool call and a real `json_schema`
  `response_format` request against each bound role, plus one image request
  against `gpu/chat/vision` on the Blackwell profile.

## 10. Open risks

1. **Issue #28355 is unresolved and `bug-unconfirmed`.** The build-10665 pin is
   a workaround, not a fix. If Flash-Next prefill is still slow on 10665, the
   Blackwell profile is blocked and the A6000/80B half ships alone. The two
   halves are deliberately independent for this reason.
2. **Flag drift.** `--load-mode` was renamed recently and the 4090 reference
   config uses newer flags (`--fit`) that may not exist in 10665. Mitigated by
   the §9 `--help` check, which has now been run for b10884.
3. **KV quantization is contested** (§2.2). f16 is the default; `q8_0` is a
   measured optimisation, not an assumption.
4. **Quant quality at Q3.** `UD-Q3_K_XL` is chosen for residency, not
   fidelity. If tool-call or JSON reliability measures worse than the outgoing
   `Qwen3.6-35B-A3B`, the fallback is `IQ4_XS` with `fit` offloading ~3 GiB — a
   one-variable change. Worth one comparison during bring-up, since the
   contract's value is precisely tool-calling and JSON.
5. **`-c 131072` with f16 KV may not fit** alongside 33.19 GiB of weights once
   Infinity is co-resident. `fit on` handles this by offloading experts rather
   than failing, so the degradation is speed, not a crash. If it offloads more
   than a few layers, the levers are `-np 2` (2 x 32k, still contract-compliant)
   or `q8_0` KV. Both preserve the contract; §6's assertion makes an accidental
   violation visible either way.
