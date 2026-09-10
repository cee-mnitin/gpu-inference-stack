# llama.cpp on this stack

The third inference runtime, alongside Ollama and vLLM. It is **mutually
exclusive with vLLM on any single GPU** — `scripts/deploy.sh` refuses to start
both.

## When to reach for it instead of vLLM

vLLM remains the default. Choose llama.cpp when one of these is true:

- **The weights are GGUF and larger than VRAM.** llama.cpp's `-ncmoe` /
  `-ot` CPU-offload path is mature; it will place expert tensors in host
  memory and keep serving.
- **The box predates FP8/FP4 tensor cores.** The A6000 is `sm_86` (Ampere),
  so the FP8 and NVFP4 quants that modern vLLM recipes assume have no native
  kernel path on it.
- **The model is `qwen4exp` / Qwen3.8-Flash-Next.** vLLM's host-memory PLE
  prefetch for that architecture is still an open feature request
  ([vllm#53908](https://github.com/vllm-project/vllm/issues/53908)).

## Which box runs what

| | A6000 48 GB (`sm_86`) | Blackwell 97 GB (`sm_120`) |
|---|---|---|
| profile | `servers/server-a6000-48gb.env` | `servers/server-blackwell-97gb.env` |
| model | Qwen3-Next-80B-A3B | Qwen3.8-Flash-Next |
| quant | `UD-Q3_K_XL`, 33.19 GiB | `UD-IQ3_XXS`, 76.3 GiB |
| image | `server-cuda-b10884` | `server-cuda-b10644` (pinned, see below) |
| slots | 4 × 32k | 1 × 128k |
| contract roles | `interactive` + `bulk` + `fast` | `interactive` + `vision` |
| `gpu/chat/vision` | unserved (text-only model) | served by the model itself |

## Getting the weights

Neither model is downloaded automatically — these are 35–82 GB transfers.

The A6000 box has **841 GB free** and no `hf` CLI. **Use the container path
there** — the host Python cannot install one without `apt`:

- `pip install huggingface_hub` is refused; the system Python ships
  PEP 668 `EXTERNALLY-MANAGED`.
- `python3 -m venv` also fails — `ensurepip` is absent, which needs
  `apt install python3.12-venv` and therefore root.

So download through a container, which touches no host Python at all:

```bash
mkdir -p ./data/llamacpp/models
docker run --rm -v "$PWD/data/llamacpp/models:/out" \
  --entrypoint sh python:3.12-slim -c \
  'pip install -q "huggingface_hub[cli]" && \
   hf download unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF \
     Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf --local-dir /out'
```

On a box that *does* have a working venv, the direct route is fine:

```bash
python3 -m venv ~/.venvs/hf
~/.venvs/hf/bin/pip install -q -U "huggingface_hub[cli]"
~/.venvs/hf/bin/hf download unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF \
  Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf \
  --local-dir ./data/llamacpp/models
```

Then point `LLAMACPP_MODEL_FILE` at the filename (not a path — the directory
comes from `LLAMACPP_MODELS_DIR`, mounted read-only at `/models`).

For the Blackwell box, Flash-Next is **split into parts**; name part 1 in
`LLAMACPP_MODEL_FILE` and llama.cpp finds the rest. Download `mmproj-F16.gguf`
alongside it for vision.

## Choosing a quant for a 48 GB card

Measured budget on the A6000 — 48086 MiB (46.96 GiB) free of 47.99 GiB total:

```
  46.96  free VRAM
 - 3.00  Infinity (bge-m3 + bge-reranker-v2-m3)
 - 3.00  KV cache @ 131072 ctx, f16
 - 2.50  graph / compute buffers + CUDA context
 - 1.50  safety margin
 -------
  36.96  available for weights
```

KV is cheap because Qwen3-Next is hybrid: only **12 of 48 layers** are
full-attention (2 KV heads × 256 dim × 2 for K+V × 2 bytes = 24.6 KB/token).
The other 36 are Gated DeltaNet with constant state. That is why 128k of
context costs ~3 GiB rather than ~30.

Real options from `unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF`:

| file | size | verdict |
|---|---|---|
| `...-UD-Q3_K_XL.gguf` | **33.19 GiB** | **default** — fits with ~3.7 GiB spare |
| `...-Q3_K_M.gguf` | 35.67 GiB | fits, ~1 GiB spare — too tight |
| `...-IQ4_XS.gguf` | 39.72 GiB | quality-first alternative; `fit` offloads ~3 GiB |
| `...-Q4_K_S.gguf` | 42.38 GiB | needs ~6 GiB offloaded |
| `...-Q4_K_M.gguf` | 45.17 GiB | does not fit usefully |

There is **no MXFP4_MOE quant of this model** in either the official Qwen repo
or unsloth's, despite that figure circulating — it belongs to a different
model. Unsloth Dynamic (`UD-`) quants hold sensitive tensors at higher
precision and ship an imatrix, so `UD-Q3_K_XL` sits well above a vanilla Q3.

## Tuning `fit`

`LLAMACPP_NCMOE` and `LLAMACPP_NGL` ship **empty**. `-fit` (default `on`) then
measures free VRAM at boot and offloads only the experts that do not fit. This
is deliberate: it adapts when Infinity's footprint moves, whereas a hardcoded
`-ncmoe` tuned once goes stale and then fails **closed** with an OOM instead of
degrading.

Read what it decided:

```bash
docker logs llamacpp 2>&1 | grep -iE 'fit|offload|n_cpu_moe|n_ctx'
```

Pin it instead when you need bit-reproducible startup, or when `fit` is being
more conservative than necessary:

```bash
LLAMACPP_NCMOE=0     # everything on GPU
LLAMACPP_NGL=999
```

`LLAMACPP_THREADS` matters **only** when `fit` has offloaded experts to CPU.

## Failure modes

### 1. Per-slot context below the contract floor

**Symptom:** container healthy, `/v1/models` lists the alias,
`health-check.sh`'s contract probe passes — and long prompts fail in
production with a 400 or a silent truncation.

**Cause:** `--ctx-size` is a **pool divided across `--parallel` slots**. So
`-c 32768 -np 4` serves **8k per slot**, while `gpu/chat/interactive` and
`gpu/chat/bulk` promise ≥32k. Every cheap probe sends a short prompt and
therefore passes.

There is a second route in: `-fit` defaults to `on` and adjusts *unset*
arguments, with `--fit-ctx` (default **4096**) as the floor it may shrink
context to. A box that leaves `--ctx-size` unset can come up serving 4k.

And a third: **`--kv-unified-per-slot` is a CAP, not a floor.** Setting it to
the contract minimum can only ever reduce context. The server says so:

```
srv load_model: capping per-slot context (131072) to --kv-unified-per-slot (32768)
```

On a 1-slot/128k deployment that silently cuts context 4x — while a "≥32768"
assertion still passes. It is deliberately **not** wired into the service for
this reason; `LLAMACPP_CTX_PER_SLOT` is only `health-check.sh`'s floor value.

A fourth, benign one: llama.cpp also caps slot context to the **model's
training context**, logging `exceeds the training context of the model`. Both
models here support far more than 32k natively (Qwen3-Next 262144,
Flash-Next 262144 extensible to 1M), so this only bites if you point the
service at a short-context model.

**Fix:** keep `LLAMACPP_CTX_SIZE` set explicitly (fit only touches unset
args), keep it at `LLAMACPP_PARALLEL × 32768`, and do not add
`--kv-unified-per-slot`. `health-check.sh` asserts the **live** per-slot value
from `/props` against both the floor *and* the configured
`CTX_SIZE / PARALLEL` ratio — the ratio check is what catches a silent
reduction that still clears the floor.

### 2. `LAZY_MODE=auto` on a box without NVMe

**Symptom:** extremely slow prefill; the GPU looks idle; heavy disk I/O.

**Cause:** `-lzm/--lazy-mode` defaults to `auto`, meaning "read the rows of
tensors larger than 4 GiB from disk on demand instead of keeping them
resident". The A6000 box has **no NVMe** — `/dev/sda` is a rotational SAS
logical volume — so those reads are seek-bound.

**Fix:** `LLAMACPP_LAZY_MODE=off`. Both profiles set it. With 251 GB of RAM,
full residency is free.

This is also a plausible mechanism for
[llama.cpp#28355](https://github.com/ggml-org/llama.cpp/issues/28355)'s
slow-prefill report on the 51B PLE table — a hypothesis worth testing before
assuming the b10644 pin is permanent.

### 3. `q8_0` KV cache on `qwen4exp`

**Symptom:** assertion failure during model load; the server never binds.

**Cause:** [PR #27742](https://github.com/ggml-org/llama.cpp/pull/27742)
reports `-ctk/-ctv q8_0` asserting on the Flash-Next architecture. Reports
conflict — a working 4090 config uses q8_0 — so it is hardware- and
build-dependent.

**Fix:** `f16` is the default in both profiles. Treat `q8_0` as a measured
optimisation you verify on the box, never a default.

### 4. Both engines enabled

**Symptom:** `deploy.sh` exits 1 with "mutually exclusive".

**Why an error and not a warning:** two engines contending for one card do not
fail cleanly. They OOM mid-request or thrash, which reaches a consumer as
intermittent 5xx and timeouts — indistinguishable from a flaky backend, and a
long way from "both engines were enabled". Neither GPU has the headroom:
33.19 GiB (A6000) or 76.3 GiB (Blackwell) of weights, plus vLLM's ~31 GB.

**Fix:** enable one. On a genuinely multi-GPU box with the engines pinned to
different devices via `GPU_DEVICES` / `LLAMACPP_GPU_DEVICES`, set
`ALLOW_VLLM_LLAMACPP_COTENANCY=1`.

### 5. An optional role published without a backend

**Symptom:** `gpu/chat/vision` appears in `/v1/models`, then every call 500s
with `Cannot connect to host ollama:11434`.

**Cause:** LiteLLM publishes every alias in `config/litellm/config.yaml`
regardless of whether its `api_base` answers. `ENABLE_OLLAMA=false` stops the
container but does not remove the alias.

This is worse than an absent alias. Per the contract, a consumer **routes
around a missing optional role** (vision falls back to a cloud provider) but
**breaks on a published-but-dead one** — it has no way to tell "unserved" from
"serving badly".

**Fix:** rename the alias out of the `gpu/` contract namespace:

```bash
CONTRACT_VISION_ALIAS=unserved/vision
```

`config/litellm/config.yaml` declares the vision alias as
`model_name: os.environ/CONTRACT_VISION_ALIAS`, defaulting to the real
contract name. So consumers looking for `gpu/chat/vision` no longer find it
and fall back cleanly, while the entry stays introspectable for debugging.
The block cannot simply be deleted upstream — the default profiles serve
vision via Ollama and the Blackwell profile serves it via llama.cpp.

`scripts/deploy.sh` additionally warns whenever a contract role's `api_base`
names a service whose `ENABLE_*` is false, so a half-configured box is caught
at deploy time.

### 6. Image built for the wrong compute capability

**Symptom:** every request dies with `no kernel image is available for
execution on the device`. The container is otherwise healthy.

**Cause:** the CUDA build does not include the box's architecture. This does
not degrade — it fails on all inference. `sm_120` (Blackwell) needs CUDA
12.8+; the `server-cuda` line is 12.8.1, which covers `sm_86` and `sm_120`.

**Fix:** verify before deploying, then set `LLAMACPP_IMAGE`:

```bash
docker run --rm --entrypoint sh $LLAMACPP_IMAGE -c '/app/llama-server --version'
```

Note that images exist for only **521 of the `server-cuda-b*` builds** — most
build numbers return `manifest unknown`. `b10665`, the number named as
known-good in issue #28355, is one of them; `b10644` is the nearest published
build at or below it.

## Why MTP / speculative decoding is off

Qwen3.8-Flash-Next ships a 4B MTP head, and it is tempting. It is not wired up
here, for two reasons.

It is **not in mainline** —
[PR #28243](https://github.com/ggml-org/llama.cpp/pull/28243) is still a
draft.

And where it has been measured the results do not justify a second model in
memory. Acceptance rates swing from **0.32–0.38** (net *slower* decode) to
0.77–0.93 depending on hardware. Upstream H100 numbers had MTP reducing
request throughput **8–36%** and raising per-token latency **32–173%** at ~36%
acceptance. The PR itself records stability concerns on **RTX Blackwell** —
which is the box that would run Flash-Next.

When #28243 merges, it is a one-variable experiment: add
`LLAMA_ARG_SPEC_TYPE=draft-mtp` plus the sidecar path, and measure acceptance
on the actual box before keeping it.

## Verifying a deployment

```bash
bash scripts/health-check.sh
```

Beyond the service probes this asserts the per-slot context (failure mode 1)
and calls every contract alias. But a green health check proves less than it
looks: its prompts are short and its calls are trivial. The two things the
contract actually promises are tool calling and JSON, so test those:

```bash
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2)
BASE=http://100.117.227.40:8080

# tool calling
curl -s $BASE/v1/chat/completions -H "Authorization: Bearer $KEY" \
 -H 'Content-Type: application/json' -d '{
  "model":"gpu/chat/interactive",
  "messages":[{"role":"user","content":"Weather in Pune? Use the tool."}],
  "tools":[{"type":"function","function":{"name":"get_weather",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},
    "required":["city"]}}}]}' | python3 -m json.tool | grep -A6 tool_calls

# structured output
curl -s $BASE/v1/chat/completions -H "Authorization: Bearer $KEY" \
 -H 'Content-Type: application/json' -d '{
  "model":"gpu/chat/bulk",
  "messages":[{"role":"user","content":"Pune is in Maharashtra, India."}],
  "response_format":{"type":"json_schema","json_schema":{"name":"loc",
    "schema":{"type":"object","properties":{"city":{"type":"string"},
    "state":{"type":"string"}},"required":["city","state"]}}}}' \
 | python3 -c 'import sys,json;print(json.loads(json.load(sys.stdin)["choices"][0]["message"]["content"]))'
```

And test a long prompt, which is the one failure the short probes structurally
cannot see:

```bash
python3 -c "
import json,urllib.request,os
p='word '*30000
r=urllib.request.Request('http://100.117.227.40:8080/v1/chat/completions',
  data=json.dumps({'model':'gpu/chat/interactive','max_tokens':16,
    'messages':[{'role':'user','content':p+'\nReply with the single word OK.'}]}).encode(),
  headers={'Authorization':'Bearer '+os.environ['KEY'],'Content-Type':'application/json'})
print(json.load(urllib.request.urlopen(r,timeout=600))['choices'][0]['message'])
"
```

## Measured bring-up numbers

Recorded on first deployment. Update when the quant, slot count, or co-tenants
change.

| | value | notes |
|---|---|---|
| `fit` decision | _pending first run_ | `docker logs llamacpp \| grep -i fit` |
| decode (single stream) | _pending first run_ | tokens/sec |
| prefill | _pending first run_ | tokens/sec |
| VRAM in use | _pending first run_ | `nvidia-smi` with Infinity co-resident |
