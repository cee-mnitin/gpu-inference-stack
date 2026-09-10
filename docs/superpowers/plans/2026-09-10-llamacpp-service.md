# llama.cpp Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-ready, profile-gated `llamacpp` service to the GPU
inference stack, running Qwen3-Next-80B-A3B on this A6000 48GB box and able to
run Qwen3.8-Flash-Next on the Blackwell 97GB box, selected entirely by `.env`.

**Architecture:** One compose service configured exclusively through
`LLAMA_ARG_*` environment variables (no `command:`), mutually exclusive with
vLLM, bound to the existing `gpu/<task>/<role>` contract via the
`CONTRACT_*` indirection so `config/litellm/config.yaml` needs no change.

**Tech Stack:** Docker Compose, `ghcr.io/ggml-org/llama.cpp:server-cuda-b10884`,
bash, LiteLLM, Prometheus.

**Spec:** `docs/superpowers/specs/2026-09-10-llamacpp-service-design.md`

## Global Constraints

- **This repo has no test framework.** It is bash + compose. "Write the failing
  test" therefore means *write the verification command and observe it fail*.
  Every task states the exact command and the exact expected output.
- **Contract floor:** `gpu/chat/interactive` and `gpu/chat/bulk` require
  **>=32768** tokens of context **per slot**; `gpu/chat/fast` requires >=16384.
- **`LLAMA_ARG_LAZY_MODE=off` is mandatory** on the A6000 box (rotational SAS,
  no NVMe). Spec §2.7.2.
- **`LLAMA_ARG_CTX_SIZE` must always be set explicitly.** `-fit` defaults to
  `on` and will shrink an unset context to as low as 4096. Spec §2.7.1.
- **Compose default image:** `ghcr.io/ggml-org/llama.cpp:server-cuda-b10884`
  (verified on this box). Blackwell profile pins `...-b10644` (issue #28355).
- **Port:** host `8083` -> container `8080`. Verified free.
- **Model, this box:** repo `unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF`, file
  `Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf`, 33.19 GiB, single file.
- **This box must set `LITELLM_BIND_ADDR=100.117.227.40`** — `platform-traefik`
  holds `127.0.0.1:8080`, so LiteLLM's `0.0.0.0:8080` default cannot bind.
- Never enable both `ENABLE_VLLM` and `ENABLE_LLAMACPP`. Both ship `false`.

---

### Task 1: `llamacpp` compose service + `.env.example` section

**Files:**
- Modify: `docker-compose.yml` (new service after the `vllm-router` block)
- Modify: `.env.example` (new `LLAMACPP CONFIGURATION` section after the vLLM one)

**Interfaces:**
- Produces: service name `llamacpp`, in-network base `http://llamacpp:8080/v1`,
  compose profile `llamacpp`, host port `${LLAMACPP_PORT:-8083}`, metrics at
  `llamacpp:8080/metrics`, health at `/health`.
- Produces env contract consumed by Tasks 2, 3, 5: `ENABLE_LLAMACPP`,
  `LLAMACPP_PORT`, `LLAMACPP_IMAGE`, `LLAMACPP_MODEL_FILE`,
  `LLAMACPP_MODEL_NAME`, `LLAMACPP_MODELS_DIR`, `LLAMACPP_CTX_SIZE`,
  `LLAMACPP_PARALLEL`, `LLAMACPP_CTX_PER_SLOT`, `LLAMACPP_NCMOE`,
  `LLAMACPP_NGL`, `LLAMACPP_LAZY_MODE`, `LLAMACPP_LOAD_MODE`, `LLAMACPP_FIT`,
  `LLAMACPP_FIT_TARGET`, `LLAMACPP_FIT_CTX`, `LLAMACPP_FLASH_ATTN`,
  `LLAMACPP_CACHE_TYPE_K`, `LLAMACPP_CACHE_TYPE_V`, `LLAMACPP_THREADS`,
  `LLAMACPP_CACHE_REUSE`, `LLAMACPP_OVERRIDE_TENSOR`, `LLAMACPP_MMPROJ`,
  `LLAMACPP_REASONING`, `LLAMACPP_GPU_DEVICES`, `LLAMACPP_START_PERIOD`.

- [ ] **Step 1: Write the failing verification**

```bash
docker compose --profile llamacpp config 2>&1 | grep -A2 'container_name: llamacpp'
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: no output (the service does not exist yet).

- [ ] **Step 3: Add the service to `docker-compose.yml`**

Insert after the `vllm-router` service block. No `command:` — every knob is an
env var (spec §2.6, §4.2).

```yaml
  # ============================================================================
  # LLAMA.CPP - GGUF inference (Qwen3-Next-80B-A3B here, Flash-Next elsewhere)
  # ============================================================================
  # MUTUALLY EXCLUSIVE WITH vllm. Neither box can host both: this box's
  # UD-Q3_K_XL weights are 33.19 GiB of 48 GB, and vLLM wants ~31 GB on top.
  # scripts/deploy.sh refuses to start both; see ALLOW_VLLM_LLAMACPP_COTENANCY.
  llamacpp:
    # Pinned by BUILD NUMBER, not :latest, and not arbitrarily.
    #   - b10884 is the newest PUBLISHED build (images exist for only 521 of
    #     the server-cuda-b* builds) and is the one actually pulled and
    #     flag-verified on this box.
    #   - The Blackwell profile overrides this to b10644, because
    #     ggml-org/llama.cpp#28355 (OPEN) reports the 51B PLE n-gram table
    #     failing to load on builds newer than 10665, causing extremely slow
    #     prefill. b10644 is the newest published build at or below 10665.
    #     b10666 is deliberately skipped: it is one past the last known-good.
    # Qwen3-Next-80B-A3B is NOT affected by #28355 (it landed at b7186), which
    # is why this box gets the newer default.
    # Verify a candidate on the box before deploying:
    #   docker run --rm --entrypoint sh <image> -c '/app/llama-server --version'
    image: ${LLAMACPP_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda-b10884}
    container_name: llamacpp
    profiles:
      - llamacpp
    restart: unless-stopped
    ports:
      - "${LLAMACPP_PORT:-8083}:8080"
    volumes:
      # Read-only: the server has no reason to write to the weights directory.
      - ${LLAMACPP_MODELS_DIR:-./data/llamacpp/models}:/models:ro
    environment:
      # ── Model ────────────────────────────────────────────────────────────
      - LLAMA_ARG_MODEL=/models/${LLAMACPP_MODEL_FILE:?LLAMACPP_MODEL_FILE must name a .gguf under LLAMACPP_MODELS_DIR}
      - LLAMA_ARG_ALIAS=${LLAMACPP_MODEL_NAME:-llamacpp}
      - LLAMA_ARG_HOST=0.0.0.0
      - LLAMA_ARG_PORT=8080
      #
      # ── Context: EXPLICIT, and that is load-bearing ──────────────────────
      # --ctx-size is a POOL divided across --parallel slots, so -c 32768
      # with -np 4 gives each slot 8k while the contract promises >=32k.
      # /v1/models still lists the alias and a small health probe still
      # passes; only real long prompts fail.
      #
      # Worse, -fit defaults to ON and adjusts *unset* arguments to fit VRAM,
      # with --fit-ctx (default 4096) as the floor it may shrink context to.
      # Setting CTX_SIZE explicitly immunises against that, because fit only
      # touches unset args. FIT_CTX below is the second line of defence.
      #
      # 131072 / 4 slots = 32768 per slot = the contract floor exactly.
      # scripts/health-check.sh asserts the live per-slot value.
      - LLAMA_ARG_CTX_SIZE=${LLAMACPP_CTX_SIZE:-131072}
      - LLAMA_ARG_N_PARALLEL=${LLAMACPP_PARALLEL:-4}
      - LLAMA_ARG_KV_UNIFIED_PER_SLOT=${LLAMACPP_CTX_PER_SLOT:-32768}
      - LLAMA_ARG_FIT_CTX=${LLAMACPP_FIT_CTX:-131072}
      #
      # ── Residency ────────────────────────────────────────────────────────
      # LAZY_MODE=off is MANDATORY on this box. Its default is `auto`, which
      # means "read the rows of tensors larger than 4 GiB from disk on demand
      # instead of keeping them resident (requires mmap)". This box has NO
      # NVMe — /dev/sda is a rotational SAS logical volume — so on-demand
      # tensor reads are seek-bound. 251 GB of RAM makes residency free.
      - LLAMA_ARG_LAZY_MODE=${LLAMACPP_LAZY_MODE:-off}
      - LLAMA_ARG_LOAD_MODE=${LLAMACPP_LOAD_MODE:-mmap}
      #
      # ── Fit: ON, deliberately ────────────────────────────────────────────
      # N_CPU_MOE and N_GPU_LAYERS are intentionally UNSET (empty string reads
      # as unset). `fit on` then measures free VRAM at boot and offloads only
      # what does not fit, so the service adapts when Infinity's footprint
      # moves. A hardcoded -ncmoe tuned once goes stale and fails closed
      # (OOM) rather than degrading. Pin both for reproducible startup.
      - LLAMA_ARG_FIT=${LLAMACPP_FIT:-on}
      - LLAMA_ARG_FIT_TARGET=${LLAMACPP_FIT_TARGET:-2048}
      - LLAMA_ARG_N_CPU_MOE=${LLAMACPP_NCMOE:-}
      - LLAMA_ARG_N_GPU_LAYERS=${LLAMACPP_NGL:-}
      #
      # ── Attention / KV ───────────────────────────────────────────────────
      # f16 KV, not q8_0: PR #27742 reports -ctk/-ctv q8_0 assertion failures
      # on qwen4exp. q8_0 is a measured optimisation, not a default.
      - LLAMA_ARG_FLASH_ATTN=${LLAMACPP_FLASH_ATTN:-on}
      - LLAMA_ARG_CACHE_TYPE_K=${LLAMACPP_CACHE_TYPE_K:-f16}
      - LLAMA_ARG_CACHE_TYPE_V=${LLAMACPP_CACHE_TYPE_V:-f16}
      #
      # ── Throughput ───────────────────────────────────────────────────────
      # THREADS matters only when fit decides to offload experts to CPU.
      # CACHE_REUSE is llama.cpp's analogue of vLLM's --enable-prefix-caching
      # (default 0 = disabled).
      - LLAMA_ARG_THREADS=${LLAMACPP_THREADS:-16}
      - LLAMA_ARG_CACHE_REUSE=${LLAMACPP_CACHE_REUSE:-256}
      #
      # ── API surface the contract needs ───────────────────────────────────
      # JINJA gives tool calling. REASONING=auto extracts thought tags into
      # `reasoning_content` instead of leaking <think> into content — the
      # llama.cpp equivalent of vLLM's --reasoning-parser qwen3.
      - LLAMA_ARG_JINJA=1
      - LLAMA_ARG_REASONING=${LLAMACPP_REASONING:-auto}
      - LLAMA_ARG_ENDPOINT_METRICS=1
      #
      # ── Per-model extras (empty on this box) ─────────────────────────────
      # OVERRIDE_TENSOR places the Flash-Next 51B PLE table on CPU; MMPROJ
      # adds its vision tower. Both are empty for Qwen3-Next-80B-A3B.
      - LLAMA_ARG_OVERRIDE_TENSOR=${LLAMACPP_OVERRIDE_TENSOR:-}
      - LLAMA_ARG_MMPROJ=${LLAMACPP_MMPROJ:-}
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ['${LLAMACPP_GPU_DEVICES:-${GPU_DEVICES:-0}}']
              capabilities: [gpu]
    networks:
      - gpu-inference-net
    healthcheck:
      # curl, and that was CHECKED not assumed: this image ships curl and
      # python3 but NOT wget or nc. The ollama and litellm services in this
      # file both carry scars from probes that referenced absent binaries and
      # sat permanently `unhealthy` while serving 200s. Re-run on image bump:
      #   docker run --rm --entrypoint sh <image> -c 'command -v curl wget python3'
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 10
      # 15 min, longer than vLLM's 10. Reading 33 GiB off this box's
      # rotational SAS array is minutes before any warmup begins.
      start_period: ${LLAMACPP_START_PERIOD:-900s}
    logging:
      driver: "json-file"
      options:
        max-size: "${MAX_LOG_SIZE:-100m}"
        max-file: "${MAX_LOG_FILES:-5}"
```

- [ ] **Step 4: Add the `.env.example` section**

Insert after the vLLM configuration section.

```bash
# ============================================================================
# LLAMA.CPP CONFIGURATION  (alternative to vLLM — never both)
# ============================================================================
# MUTUALLY EXCLUSIVE WITH vLLM. deploy.sh exits non-zero if both are true.
# Neither GPU in this fleet can host both engines at once.
ENABLE_LLAMACPP=false
LLAMACPP_PORT=8083

# Runtime image, pinned by build number. See the comment in docker-compose.yml
# for why: images exist for only some builds, and #28355 makes builds newer
# than 10665 unsafe for Qwen3.8-Flash-Next specifically.
LLAMACPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda-b10884

# Weights. LLAMACPP_MODEL_FILE is REQUIRED and is a path relative to
# LLAMACPP_MODELS_DIR, which is mounted read-only at /models.
#   A6000 48GB : Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf   (33.19 GiB)
#   Blackwell  : Qwen3.8-Flash-Next-UD-IQ3_XXS-*.gguf          (76.3 GiB)
LLAMACPP_MODELS_DIR=./data/llamacpp/models
LLAMACPP_MODEL_FILE=Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf
LLAMACPP_MODEL_NAME=qwen3-next-80b

# Context. CTX_SIZE is a POOL split across PARALLEL slots, so per-slot context
# is CTX_SIZE/PARALLEL and THAT is what the contract's >=32k applies to.
# 131072/4 = 32768. Do not raise PARALLEL without raising CTX_SIZE.
# Leaving CTX_SIZE unset is unsafe: -fit would be free to shrink it to 4096.
LLAMACPP_CTX_SIZE=131072
LLAMACPP_PARALLEL=4
LLAMACPP_CTX_PER_SLOT=32768
LLAMACPP_FIT_CTX=131072

# Residency. `off` is mandatory on a box without NVMe — the default `auto`
# streams >4 GiB tensors from disk on demand.
LLAMACPP_LAZY_MODE=off
LLAMACPP_LOAD_MODE=mmap

# Fit. Leave NCMOE and NGL EMPTY to let llama.cpp measure free VRAM at boot
# and offload only what does not fit. Set them to pin startup exactly.
LLAMACPP_FIT=on
LLAMACPP_FIT_TARGET=2048
LLAMACPP_NCMOE=
LLAMACPP_NGL=

# Attention / KV. f16, not q8_0 — q8_0 asserts on the qwen4exp arch.
LLAMACPP_FLASH_ATTN=on
LLAMACPP_CACHE_TYPE_K=f16
LLAMACPP_CACHE_TYPE_V=f16

# Throughput. THREADS only matters if fit offloads experts to CPU.
LLAMACPP_THREADS=16
LLAMACPP_CACHE_REUSE=256

LLAMACPP_REASONING=auto
LLAMACPP_START_PERIOD=900s

# Per-model extras. Empty for Qwen3-Next-80B-A3B; the Blackwell/Flash-Next
# profile sets both.
LLAMACPP_OVERRIDE_TENSOR=
LLAMACPP_MMPROJ=

# To bind the contract's chat roles to llama.cpp instead of vLLM:
#   CONTRACT_INTERACTIVE_MODEL=openai/qwen3-next-80b
#   CONTRACT_INTERACTIVE_API_BASE=http://llamacpp:8080/v1
#   CONTRACT_BULK_MODEL=openai/qwen3-next-80b
#   CONTRACT_BULK_API_BASE=http://llamacpp:8080/v1
#   CONTRACT_FAST_MODEL=openai/qwen3-next-80b
#   CONTRACT_FAST_API_BASE=http://llamacpp:8080/v1
```

- [ ] **Step 5: Run the verification and confirm it passes**

```bash
LLAMACPP_MODEL_FILE=x.gguf docker compose --profile llamacpp config >/dev/null && echo RENDER_OK
LLAMACPP_MODEL_FILE=x.gguf docker compose --profile llamacpp config \
  | grep -E 'LLAMA_ARG_(CTX_SIZE|N_PARALLEL|LAZY_MODE|N_CPU_MOE|FIT)\b'
```
Expected: `RENDER_OK`, then `CTX_SIZE: "131072"`, `N_PARALLEL: "4"`,
`LAZY_MODE: "off"`, `N_CPU_MOE: ""`, `FIT: "on"`. `N_CPU_MOE` must be an
**empty string**, not the literal `${LLAMACPP_NCMOE}`.

- [ ] **Step 6: Verify the required-variable guard fires**

```bash
docker compose --profile llamacpp config 2>&1 | grep -c 'LLAMACPP_MODEL_FILE must name'
```
Expected: `1` — compose refuses to render without `LLAMACPP_MODEL_FILE`.

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "feat(llamacpp): add env-configured llama.cpp service on 8083"
```

---

### Task 2: `deploy.sh` — profile, exclusivity guard, no-engine warning

**Files:**
- Modify: `scripts/deploy.sh:54` (data dirs), `:69-72` (profile block)

**Interfaces:**
- Consumes: `ENABLE_LLAMACPP`, `ENABLE_VLLM`, `LLAMACPP_PORT`,
  `ALLOW_VLLM_LLAMACPP_COTENANCY` from Task 1.
- Produces: `llamacpp` in `COMPOSE_PROFILES`; exit code 1 on both-enabled.

- [ ] **Step 1: Write the failing verification**

```bash
cd /home/crimson/projects/gpu-inference-stack
printf 'ENABLE_VLLM=true\nENABLE_LLAMACPP=true\n' > /tmp/both.env
cp .env /tmp/env.bak 2>/dev/null || true
cat /tmp/both.env > .env
bash scripts/deploy.sh 2>&1 | head -20; echo "exit=$?"
```

- [ ] **Step 2: Confirm it fails wrongly**

Expected before the fix: the script proceeds past prerequisites and tries to
start both engines (`Enabling vLLM...` with no error). We want exit 1 and a
refusal message.

- [ ] **Step 3: Add the guard immediately after the `.env` source (after line 29)**

```bash
# ---------------------------------------------------------------------------
# Engine exclusivity: vLLM and llama.cpp cannot share a GPU here.
#
# This box's llama.cpp weights are 33.19 GiB of 48 GB, and the Blackwell box's
# are 76.3 GiB of 97 GB; vLLM wants ~31 GB on top of either. Two engines
# contending for one card does not fail cleanly — it OOMs mid-request or
# thrashes, which reaches a consumer as intermittent 5xx and timeouts rather
# than as a configuration error. So fail here, loudly, at deploy time.
#
# A genuinely multi-GPU box that has pinned VLLM and LLAMACPP to different
# devices via GPU_DEVICES / LLAMACPP_GPU_DEVICES can override.
# ---------------------------------------------------------------------------
if [ "${ENABLE_VLLM}" = "true" ] && [ "${ENABLE_LLAMACPP}" = "true" ]; then
    if [ "${ALLOW_VLLM_LLAMACPP_COTENANCY:-0}" != "1" ]; then
        echo -e "${RED}Error: ENABLE_VLLM and ENABLE_LLAMACPP are both true.${NC}"
        echo ""
        echo "  These engines are mutually exclusive on a single GPU. Enable the"
        echo "  one this box is meant to serve and disable the other:"
        echo ""
        echo "    vLLM       -> ENABLE_VLLM=true   ENABLE_LLAMACPP=false"
        echo "    llama.cpp  -> ENABLE_VLLM=false  ENABLE_LLAMACPP=true"
        echo ""
        echo "  If this box has more than one GPU and you have pinned them to"
        echo "  different devices (GPU_DEVICES vs LLAMACPP_GPU_DEVICES), set"
        echo "  ALLOW_VLLM_LLAMACPP_COTENANCY=1 to proceed."
        exit 1
    fi
    echo -e "${YELLOW}Warning: running vLLM and llama.cpp together (cotenancy override set).${NC}"
    echo "  GPU_DEVICES=${GPU_DEVICES:-0}  LLAMACPP_GPU_DEVICES=${LLAMACPP_GPU_DEVICES:-${GPU_DEVICES:-0}}"
fi

# A box with no chat engine cannot serve gpu/chat/interactive, /bulk or /fast —
# the three REQUIRED contract roles. Warn rather than fail: an embed/rerank-only
# box is a legitimate deployment.
if [ "${ENABLE_VLLM}" != "true" ] && [ "${ENABLE_LLAMACPP}" != "true" ]; then
    echo -e "${YELLOW}Warning: neither vLLM nor llama.cpp is enabled.${NC}"
    echo "  The required gpu/chat/* contract roles will be unserved and"
    echo "  health-check.sh will report contract failures."
fi
```

- [ ] **Step 4: Add the profile block after the vLLM block (line 72)**

```bash
if [ "${ENABLE_LLAMACPP}" = "true" ]; then
    PROFILES="$PROFILES,llamacpp"
    echo "Enabling llama.cpp..."
fi
```

- [ ] **Step 5: Add the data dir (modify line 54)**

```bash
mkdir -p "$PROJECT_ROOT/data"/{ollama/models,vllm/cache,llamacpp/models,huggingface,prometheus,grafana,postgres}
```

- [ ] **Step 6: Add the access-point line after the vLLM one (line 165)**

```bash
if [ "${ENABLE_LLAMACPP}" = "true" ]; then
    echo "  llama.cpp:   http://localhost:${LLAMACPP_PORT:-8083}"
fi
```

- [ ] **Step 7: Run the verifications and confirm they pass**

```bash
printf 'ENABLE_VLLM=true\nENABLE_LLAMACPP=true\n' > .env
bash scripts/deploy.sh >/tmp/o 2>&1; echo "both-enabled exit=$? (want 1)"; grep -c 'mutually exclusive' /tmp/o
printf 'ENABLE_VLLM=false\nENABLE_LLAMACPP=false\n' > .env
bash scripts/deploy.sh 2>&1 | grep -c 'neither vLLM nor llama.cpp'
printf 'ENABLE_VLLM=true\nENABLE_LLAMACPP=true\nALLOW_VLLM_LLAMACPP_COTENANCY=1\n' > .env
bash scripts/deploy.sh 2>&1 | grep -c 'cotenancy override set'
cp /tmp/env.bak .env 2>/dev/null || rm -f .env
```
Expected: `exit=1` and `1`; then `1`; then `1`.

- [ ] **Step 8: Commit**

```bash
git add scripts/deploy.sh
git commit -m "feat(deploy): gate llamacpp profile and refuse vllm cotenancy"
```

---

### Task 3: `health-check.sh` — service probe + per-slot context assertion

**Files:**
- Modify: `scripts/health-check.sh:62` (after the vLLM probe)

**Interfaces:**
- Consumes: `ENABLE_LLAMACPP`, `LLAMACPP_PORT`, `LLAMACPP_CTX_PER_SLOT` (Task 1).
- Produces: nothing consumed downstream. This is the runtime assertion that
  closes spec §6 route 3.

- [ ] **Step 1: Write the failing verification**

```bash
grep -c 'llama.cpp' scripts/health-check.sh
```

- [ ] **Step 2: Confirm it fails**

Expected: `0`.

- [ ] **Step 3: Add the probe and the assertion after line 62**

`/props` reports `default_generation_settings.n_ctx`, which is llama-server's
**per-slot** value. `/slots` is the fallback because it is enabled by default
whereas `--props` gates only POST. If neither is reachable the check reports
UNKNOWN rather than passing silently.

```bash
# Check llama.cpp if enabled
if [ "${ENABLE_LLAMACPP}" = "true" ]; then
    check_endpoint "llama.cpp" "http://localhost:${LLAMACPP_PORT:-8083}/health"

    # ------------------------------------------------------------------
    # CONTEXT-PER-SLOT ASSERTION
    #
    # llama-server's --ctx-size is a POOL divided across --parallel slots, so
    # -c 32768 with -np 4 serves 8k per slot while gpu/chat/interactive and
    # gpu/chat/bulk promise >=32k. Nothing else catches this: /v1/models lists
    # the alias, and the contract call probe below sends a SHORT prompt that
    # succeeds at any context size. Only real long prompts fail, in
    # production, as a consumer-side truncation or 400.
    #
    # -fit (default on) is a second route in — it may shrink an unset
    # --ctx-size to as little as --fit-ctx (default 4096). So assert the LIVE
    # value rather than trusting .env.
    # ------------------------------------------------------------------
    echo -n "Checking llama.cpp context per slot... "
    _lcbase="http://localhost:${LLAMACPP_PORT:-8083}"
    _perslot=$(curl -s --max-time 5 "$_lcbase/props" 2>/dev/null \
        | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("default_generation_settings",{}).get("n_ctx",""))' 2>/dev/null)
    if [ -z "$_perslot" ]; then
        _perslot=$(curl -s --max-time 5 "$_lcbase/slots" 2>/dev/null \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0].get("n_ctx","")) if isinstance(d,list) and d else print("")' 2>/dev/null)
    fi
    _floor="${LLAMACPP_CTX_PER_SLOT:-32768}"
    if [ -z "$_perslot" ]; then
        echo -e "${YELLOW}UNKNOWN (neither /props nor /slots answered)${NC}"
    elif [ "$_perslot" -lt "$_floor" ]; then
        echo -e "${RED}✗ $_perslot < $_floor${NC}"
        echo -e "  ${RED}CONTRACT VIOLATION${NC}: gpu/chat/interactive and gpu/chat/bulk"
        echo "  promise >=32768 tokens. llama-server divides LLAMACPP_CTX_SIZE"
        echo "  across LLAMACPP_PARALLEL slots, so raise CTX_SIZE to"
        echo "  PARALLEL x $_floor (or lower PARALLEL). Current:"
        echo "    LLAMACPP_CTX_SIZE=${LLAMACPP_CTX_SIZE:-unset} LLAMACPP_PARALLEL=${LLAMACPP_PARALLEL:-unset}"
        echo "  A short health probe cannot see this; only long prompts fail."
    else
        echo -e "${GREEN}✓ $_perslot >= $_floor${NC}"
    fi
fi
```

- [ ] **Step 4: Run the verification and confirm it passes**

```bash
bash -n scripts/health-check.sh && echo SYNTAX_OK
grep -c 'CONTRACT VIOLATION' scripts/health-check.sh
```
Expected: `SYNTAX_OK` then `1`.

- [ ] **Step 5: Commit**

```bash
git add scripts/health-check.sh
git commit -m "feat(health-check): assert llama.cpp per-slot context meets contract"
```

---

### Task 4: Prometheus scrape job

**Files:**
- Modify: `config/prometheus/prometheus.yml` (append after the `vllm` job)

**Interfaces:**
- Consumes: `llamacpp:8080/metrics` from Task 1 (`LLAMA_ARG_ENDPOINT_METRICS=1`).

- [ ] **Step 1: Write the failing verification**

```bash
grep -c "job_name: 'llamacpp'" config/prometheus/prometheus.yml
```

- [ ] **Step 2: Confirm it fails**

Expected: `0`.

- [ ] **Step 3: Append the job**

```yaml
  # llama.cpp metrics. Enabled unconditionally via LLAMA_ARG_ENDPOINT_METRICS=1
  # (llama-server's --metrics defaults to DISABLED). Prometheus tolerates a
  # down target, so this job is harmless on a box running vLLM instead.
  - job_name: 'llamacpp'
    static_configs:
      - targets: ['llamacpp:8080']
        labels:
          service: 'llamacpp'
    metrics_path: '/metrics'
    scrape_interval: 30s
    scrape_timeout: 10s
```

- [ ] **Step 4: Run the verification and confirm it passes**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('config/prometheus/prometheus.yml')); \
print([j['job_name'] for j in d['scrape_configs']])"
```
Expected: a list containing `'llamacpp'`.

- [ ] **Step 5: Commit**

```bash
git add config/prometheus/prometheus.yml
git commit -m "feat(prometheus): scrape llama.cpp metrics"
```

---

### Task 5: Server profiles

**Files:**
- Create: `servers/server-a6000-48gb.env`
- Create: `servers/server-blackwell-97gb.env`
- Modify: `servers/server-high-vram.env:7` (`GPU_VRAM_TOTAL` drift)

**Interfaces:**
- Consumes: the full `LLAMACPP_*` and `CONTRACT_*` env contract from Task 1.

- [ ] **Step 1: Write the failing verification**

```bash
ls servers/server-a6000-48gb.env servers/server-blackwell-97gb.env 2>&1
```

- [ ] **Step 2: Confirm it fails**

Expected: `No such file or directory` for both.

- [ ] **Step 3: Create `servers/server-a6000-48gb.env`**

```bash
# A6000 48GB Profile — RTX A6000 (sm_86, Ampere), 251 GB RAM, rotational SAS
#
# THE CONTRACT BOX. llama.cpp serves Qwen3-Next-80B-A3B behind all three
# required gpu/chat/* roles. vLLM is off: 33.19 GiB of weights plus vLLM's
# ~31 GB does not fit in 48 GB.
#
# BOTH ENGINES SHIP DISABLED. Enable exactly one:
#   ENABLE_LLAMACPP=true   (intended for this box)
#   ENABLE_VLLM=true       (the previous Qwen3.6-35B-A3B-FP8 setup)
# deploy.sh exits non-zero if both are true.

SERVER_PROFILE=a6000-48gb
GPU_DEVICES=0
GPU_VRAM_TOTAL=48

# REQUIRED on this box. platform-traefik holds 127.0.0.1:8080, and LiteLLM's
# 0.0.0.0 default covers loopback, so the bind fails without this. wt0 is the
# Netbird interface; 192.168.3.40 (ens10f0) is the LAN alternative.
LITELLM_BIND_ADDR=100.117.227.40
LITELLM_PORT=8080

# ── Engines: enable exactly one ───────────────────────────────────────────
ENABLE_VLLM=false
ENABLE_LLAMACPP=false

# ── llama.cpp: Qwen3-Next-80B-A3B ─────────────────────────────────────────
# UD-Q3_K_XL (33.19 GiB) is chosen for RESIDENCY. Budget on this card:
#   46.96 GiB free - 3.0 Infinity - 3.0 KV@131072/f16 - 2.5 buffers
#   - 1.5 margin = ~36.9 GiB for weights.  33.19 fits with ~3.7 spare.
# IQ4_XS (39.72 GiB) is the quality-first alternative; `fit on` will offload
# the ~3 GiB overflow without any other change.
LLAMACPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda-b10884
LLAMACPP_PORT=8083
LLAMACPP_MODELS_DIR=./data/llamacpp/models
LLAMACPP_MODEL_FILE=Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf
LLAMACPP_MODEL_NAME=qwen3-next-80b

# 131072/4 = 32768 per slot = the contract floor exactly.
LLAMACPP_CTX_SIZE=131072
LLAMACPP_PARALLEL=4
LLAMACPP_CTX_PER_SLOT=32768
LLAMACPP_FIT_CTX=131072

# MANDATORY off — this box has no NVMe, so the default `auto` would stream
# >4 GiB tensors off a rotational SAS array on demand.
LLAMACPP_LAZY_MODE=off
LLAMACPP_LOAD_MODE=mmap

# Empty NCMOE/NGL: let fit measure real free VRAM at boot.
LLAMACPP_FIT=on
LLAMACPP_FIT_TARGET=2048
LLAMACPP_NCMOE=
LLAMACPP_NGL=

LLAMACPP_FLASH_ATTN=on
LLAMACPP_CACHE_TYPE_K=f16
LLAMACPP_CACHE_TYPE_V=f16
LLAMACPP_THREADS=16
LLAMACPP_CACHE_REUSE=256
LLAMACPP_REASONING=auto
LLAMACPP_START_PERIOD=900s
LLAMACPP_OVERRIDE_TENSOR=
LLAMACPP_MMPROJ=

# ── Contract roles: all three chat roles on llama.cpp ─────────────────────
CONTRACT_INTERACTIVE_MODEL=openai/qwen3-next-80b
CONTRACT_INTERACTIVE_API_BASE=http://llamacpp:8080/v1
CONTRACT_BULK_MODEL=openai/qwen3-next-80b
CONTRACT_BULK_API_BASE=http://llamacpp:8080/v1
CONTRACT_FAST_MODEL=openai/qwen3-next-80b
CONTRACT_FAST_API_BASE=http://llamacpp:8080/v1

# ── Retrieval plane: required roles, stays on ─────────────────────────────
ENABLE_INFINITY=true
INFINITY_PORT=7997
CONTRACT_EMBED_API_BASE=http://infinity:7997
CONTRACT_RERANK_API_BASE=http://infinity:7997
ENABLE_EMBEDDINGS=false

# ── Vision: UNSERVED on this box, deliberately ────────────────────────────
# Qwen3-Next-80B-A3B is text-only, and the VRAM budget above has no room for
# Ollama's ~10 GiB VL model on top of a 33 GiB resident chat model.
# gpu/chat/vision is an OPTIONAL role: a consumer that cannot find it routes
# vision to a cloud provider, which is clean degradation. Pointing it at
# something that half-works is what the contract rules forbid.
# To serve it anyway, set ENABLE_OLLAMA=true and CONTRACT_VISION_* — and
# expect fit to offload experts to CPU to make room.
ENABLE_OLLAMA=false

# ── Monitoring ────────────────────────────────────────────────────────────
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
# NOTE: ports 80 and 443 are held by platform-traefik on this box, so the
# optional nginx profile cannot be enabled here.
```

- [ ] **Step 4: Create `servers/server-blackwell-97gb.env`**

```bash
# Blackwell 97GB Profile — RTX PRO 6000 Blackwell Max-Q (sm_120), 97 GB VRAM
#
# THE DEEP / LONG-CONTEXT / VISION BOX. llama.cpp serves Qwen3.8-Flash-Next
# behind gpu/chat/interactive and gpu/chat/vision. It does NOT serve
# gpu/chat/bulk or gpu/chat/fast: Flash-Next is effectively single-slot and
# `fast` carries a 60s timeout, so those two point at the A6000 box instead.
#
# BOTH ENGINES SHIP DISABLED. Enable exactly one. deploy.sh enforces this.
#
# BEFORE FIRST USE ON THIS BOX, verify the pinned image runs on sm_120:
#   docker run --rm --entrypoint sh $LLAMACPP_IMAGE -c '/app/llama-server --version'
# A too-old CUDA build does not degrade — every request dies with
# "no kernel image is available for execution on the device".

SERVER_PROFILE=blackwell-97gb
GPU_DEVICES=0
GPU_VRAM_TOTAL=97

LITELLM_PORT=8080
# Set to this box's Netbird/LAN address.
# LITELLM_BIND_ADDR=

ENABLE_VLLM=false
ENABLE_LLAMACPP=false

# ── llama.cpp: Qwen3.8-Flash-Next ─────────────────────────────────────────
# PINNED TO b10644, NOT the compose default b10884.
# ggml-org/llama.cpp#28355 (OPEN, filed 2026-09-04) reports the 51B PLE
# n-gram embedding table failing to load on builds newer than 10665, causing
# extremely slow prefill. b10644 is the newest PUBLISHED build at or below
# 10665. b10666 is skipped deliberately — one past the last known-good.
# See §10.6 of the spec: LAZY_MODE=off may make this pin unnecessary, but
# that needs a prefill measurement on this box before the pin moves.
LLAMACPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda-b10644
LLAMACPP_PORT=8083
LLAMACPP_MODELS_DIR=./data/llamacpp/models
LLAMACPP_MODEL_FILE=Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf
LLAMACPP_MODEL_NAME=qwen38-flash-next

# ONE slot at 128k. 76.3 GiB of weights leaves ~20 GB for KV, which is enough
# because QSA runs a 2048-token budget and only 12 of 48 layers grow KV at
# all — the other 36 are Gated DeltaNet with constant state.
LLAMACPP_CTX_SIZE=131072
LLAMACPP_PARALLEL=1
LLAMACPP_CTX_PER_SLOT=32768
LLAMACPP_FIT_CTX=131072

LLAMACPP_LAZY_MODE=off
LLAMACPP_LOAD_MODE=mmap

LLAMACPP_FIT=on
LLAMACPP_FIT_TARGET=2048
LLAMACPP_NCMOE=
LLAMACPP_NGL=

LLAMACPP_FLASH_ATTN=on
# f16, not q8_0: PR #27742 reports q8_0 KV assertion failures on qwen4exp.
LLAMACPP_CACHE_TYPE_K=f16
LLAMACPP_CACHE_TYPE_V=f16
LLAMACPP_THREADS=16
LLAMACPP_CACHE_REUSE=256
LLAMACPP_REASONING=auto
LLAMACPP_START_PERIOD=1800s

# The 51B PLE table goes to host memory, not GPU and not disk.
LLAMACPP_OVERRIDE_TENSOR=per_layer_token_embd=CPU
# Flash-Next's vision tower. Download alongside the weights.
LLAMACPP_MMPROJ=/models/mmproj-F16.gguf

# ── Contract roles ────────────────────────────────────────────────────────
CONTRACT_INTERACTIVE_MODEL=openai/qwen38-flash-next
CONTRACT_INTERACTIVE_API_BASE=http://llamacpp:8080/v1
CONTRACT_VISION_MODEL=openai/qwen38-flash-next
CONTRACT_VISION_API_BASE=http://llamacpp:8080/v1

# bulk and fast are NOT served here. Point them at the A6000 box's LiteLLM
# ROOT on 8080 — not at its llama.cpp on 8083, and with no /v1 path beyond
# what is shown. Until these are set, this box is off-contract for both
# roles and health-check.sh will say so.
# CONTRACT_BULK_MODEL=openai/qwen3-next-80b
# CONTRACT_BULK_API_BASE=http://100.117.227.40:8080/v1
# CONTRACT_FAST_MODEL=openai/qwen3-next-80b
# CONTRACT_FAST_API_BASE=http://100.117.227.40:8080/v1

ENABLE_INFINITY=true
INFINITY_PORT=7997
CONTRACT_EMBED_API_BASE=http://infinity:7997
CONTRACT_RERANK_API_BASE=http://infinity:7997
ENABLE_EMBEDDINGS=false
ENABLE_OLLAMA=false

PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
```

- [ ] **Step 5: Fix the `server-high-vram.env` drift**

Change line 7 from `GPU_VRAM_TOTAL=96` to:

```bash
# Set this to the box's ACTUAL VRAM. It was 96 on a profile also documented
# for 48GB cards (RTX 6000 Ada, A100 40/80); the A6000 box measured 48.
GPU_VRAM_TOTAL=48
```

- [ ] **Step 6: Run the verification and confirm it passes**

```bash
for f in servers/server-a6000-48gb.env servers/server-blackwell-97gb.env; do
  bash -n "$f" && echo "$f parses"
  grep -q '^ENABLE_VLLM=false' "$f" && grep -q '^ENABLE_LLAMACPP=false' "$f" \
    && echo "  both engines disabled ✓"
done
awk -F= '/^LLAMACPP_CTX_SIZE|^LLAMACPP_PARALLEL/{v[$1]=$2} END{
  print "per-slot =", v["LLAMACPP_CTX_SIZE"]/v["LLAMACPP_PARALLEL"], "(want >=32768)"}' \
  servers/server-a6000-48gb.env
```
Expected: both files parse, both report engines disabled, per-slot = 32768.

- [ ] **Step 7: Commit**

```bash
git add servers/
git commit -m "feat(servers): add a6000-48gb and blackwell-97gb profiles"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (runtime choice + profile table), `servers/README.md`
  (two new profiles + comparison row), `docs/SETUP.md` (llama.cpp path)
- Create: `docs/LLAMACPP.md` (model acquisition + tuning + failure modes)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Write the failing verification**

```bash
ls docs/LLAMACPP.md 2>&1; grep -c llama.cpp README.md servers/README.md docs/SETUP.md
```

- [ ] **Step 2: Confirm it fails**

Expected: `No such file or directory`, and `0` for all three greps.

- [ ] **Step 3: Create `docs/LLAMACPP.md`**

Must contain, with no placeholders:
- **Model acquisition.** `hf` is not installed on the A6000 box, so give both
  paths: `pip install -U "huggingface_hub[cli]"` then
  `hf download unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF
  Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf --local-dir ./data/llamacpp/models`,
  and the container-based alternative for a box without pip.
  Note: 35.6 GB, single file, 845 GB free on this box.
- **The quant table** from spec §7.1 with the VRAM arithmetic.
- **Tuning `fit`.** How to read what fit decided from the startup log, and
  when to pin `LLAMACPP_NCMOE` / `LLAMACPP_NGL` instead.
- **Five failure modes**, each with symptom -> cause -> fix:
  1. Per-slot context below 32768 (short probes pass, long prompts fail).
  2. `LAZY_MODE=auto` on a box without NVMe (slow prefill).
  3. `q8_0` KV on `qwen4exp` (assertion failure at load).
  4. Both engines enabled (deploy.sh refuses; explain why not a warning).
  5. Image build too old for the box's compute capability ("no kernel image
     is available for execution on the device" on every request).
- **Why MTP is off**, with the numbers from spec §2.3.

- [ ] **Step 4: Update `README.md`**

Add a short "Choosing an inference runtime" subsection under Architecture:
vLLM is the default; llama.cpp is for GGUF weights that do not fit VRAM, for
Ampere boxes where FP8/FP4 quants have no native path, and for the
`qwen4exp` architecture. State that they are mutually exclusive per GPU and
link `docs/LLAMACPP.md`.

- [ ] **Step 5: Update `servers/README.md`**

Add the two profiles to the list and a `llama.cpp` row to the comparison
table at line 109.

- [ ] **Step 6: Update `docs/SETUP.md`**

Add the `cp servers/server-a6000-48gb.env .env` path alongside the existing
`server-high-vram.env` instructions, and the weights-download prerequisite.

- [ ] **Step 7: Run the verification and confirm it passes**

```bash
test -f docs/LLAMACPP.md && echo LLAMACPP_DOC_OK
for f in README.md servers/README.md docs/SETUP.md; do
  printf "%-22s %s\n" "$f" "$(grep -ci 'llama' "$f")"
done
grep -c 'server-a6000-48gb' docs/SETUP.md servers/README.md
```
Expected: `LLAMACPP_DOC_OK`, non-zero counts for all three files, and
`server-a6000-48gb` present in both.

- [ ] **Step 8: Commit**

```bash
git add README.md servers/README.md docs/SETUP.md docs/LLAMACPP.md
git commit -m "docs(llamacpp): document runtime choice, tuning and failure modes"
```

---

### Task 7: Live bring-up on the A6000 box

**Files:**
- Create: `.env` (from `servers/server-a6000-48gb.env`; **not committed** —
  `.env` is the operator's, and it will hold `LITELLM_MASTER_KEY`)

**Interfaces:** consumes everything from Tasks 1-6.

> **This task downloads 35.6 GB and starts GPU services.** Confirm with the
> operator before running Step 2.

- [ ] **Step 1: Create `.env` and confirm compose renders**

```bash
cp servers/server-a6000-48gb.env .env
grep -q '^LITELLM_MASTER_KEY=' .env || \
  echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)" >> .env
sed -i 's/^ENABLE_LLAMACPP=false/ENABLE_LLAMACPP=true/' .env
docker compose --profile llamacpp --profile infinity --profile litellm config >/dev/null \
  && echo RENDER_OK
```
Expected: `RENDER_OK`.

- [ ] **Step 2: Download the weights**

```bash
mkdir -p ./data/llamacpp/models
pip install -U "huggingface_hub[cli]" 2>/dev/null || true
hf download unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF \
  Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf \
  --local-dir ./data/llamacpp/models
ls -lh ./data/llamacpp/models/*.gguf
```
Expected: one file, ~33 GiB.

- [ ] **Step 3: Deploy**

```bash
bash scripts/deploy.sh
```
Expected: `Enabling llama.cpp...`, no exclusivity error, containers start.

- [ ] **Step 4: Watch the model load and record what `fit` decided**

```bash
docker logs -f llamacpp 2>&1 | grep -iE 'fit|n_ctx|offload|cpu_moe|error' | head -40
```
Expected: `n_ctx` reflecting 131072 total, and a fit decision line. Record the
chosen `ncmoe` in `docs/LLAMACPP.md`.

- [ ] **Step 5: Verify the context assertion passes**

```bash
bash scripts/health-check.sh 2>&1 | grep -A6 'context per slot'
```
Expected: `✓ 32768 >= 32768`. If it reports a violation, that is the check
doing its job — raise `LLAMACPP_CTX_SIZE` or lower `LLAMACPP_PARALLEL`.

- [ ] **Step 6: Verify the contract end-to-end**

```bash
bash scripts/health-check.sh
```
Expected: `gpu/chat/interactive`, `gpu/chat/bulk`, `gpu/chat/fast`,
`gpu/embed/bge-m3`, `gpu/rerank/bge-reranker-v2-m3` all ✓;
`gpu/chat/vision` reported as unserved (expected on this box).

- [ ] **Step 7: Verify tool calling and JSON — what the contract actually promises**

```bash
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2)
BASE=http://100.117.227.40:8080

curl -s $BASE/v1/chat/completions -H "Authorization: Bearer $KEY" \
 -H 'Content-Type: application/json' -d '{
  "model":"gpu/chat/interactive",
  "messages":[{"role":"user","content":"What is the weather in Pune? Use the tool."}],
  "tools":[{"type":"function","function":{"name":"get_weather",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]
 }' | python3 -m json.tool | grep -A6 tool_calls

curl -s $BASE/v1/chat/completions -H "Authorization: Bearer $KEY" \
 -H 'Content-Type: application/json' -d '{
  "model":"gpu/chat/bulk",
  "messages":[{"role":"user","content":"Pune is in Maharashtra, India."}],
  "response_format":{"type":"json_schema","json_schema":{"name":"loc","schema":
    {"type":"object","properties":{"city":{"type":"string"},"state":{"type":"string"}},
     "required":["city","state"]}}}
 }' | python3 -c 'import sys,json;print(json.loads(json.load(sys.stdin)["choices"][0]["message"]["content"]))'
```
Expected: a populated `tool_calls` array, then a parsed dict with `city` and
`state`. These two are the contract's actual value; a green health check
without them proves little.

- [ ] **Step 8: Verify long context — the failure the short probes cannot see**

```bash
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2)
python3 -c "
import json,urllib.request
p='word '*30000  # ~30k tokens, above any 8k-per-slot misconfiguration
r=urllib.request.Request('http://100.117.227.40:8080/v1/chat/completions',
  data=json.dumps({'model':'gpu/chat/interactive','max_tokens':16,
    'messages':[{'role':'user','content':p+'\nReply with the single word OK.'}]}).encode(),
  headers={'Authorization':'Bearer $KEY','Content-Type':'application/json'})
print(json.load(urllib.request.urlopen(r,timeout=600))['choices'][0]['message'])
"
```
Expected: a normal completion. A 400 or truncation here is the §6 hazard
reproducing, and means per-slot context is below the contract floor.

- [ ] **Step 9: Verify Prometheus is scraping**

```bash
curl -s "http://localhost:9090/api/v1/targets?state=active" \
 | python3 -c 'import sys,json;print([(t["labels"]["job"],t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]])'
```
Expected: `('llamacpp','up')` present.

- [ ] **Step 10: Record measurements and commit the docs update**

Append the observed fit decision, decode tokens/sec, and prefill tokens/sec to
`docs/LLAMACPP.md`, then:

```bash
git add docs/LLAMACPP.md
git commit -m "docs(llamacpp): record measured bring-up numbers on the A6000"
```

---

## Self-Review

**Spec coverage:** §4 -> Task 1. §4.4 -> Task 1 Step 3. §5 -> Task 2. §5.1 ->
Tasks 1, 5. §6 -> Tasks 1 (routes 1-2) and 3 (route 3). §7.1 -> Task 5 + Task 7
Steps 7-8. §7.2 -> Task 5. §7.3 -> Task 5 (`LITELLM_BIND_ADDR`). §8 -> Tasks
1-6. §8.1 -> Task 6 Step 3 + Task 7 Step 2. §9 -> verification steps
throughout. §10.4 (quant quality) -> Task 7 Step 7.

**Known gap, accepted:** spec §2.7.2's hypothesis that `LAZY_MODE=off` makes
the b10644 pin unnecessary is **not** tested by this plan. It needs a prefill
measurement on the Blackwell box, which this plan does not touch. The
conservative pin stands until then.

**Type consistency:** every `LLAMACPP_*` name in Tasks 2, 3, 5 and 7 appears in
Task 1's Interfaces block. `LLAMACPP_CTX_PER_SLOT` is the floor read by Task 3
and set by Task 5. Alias `qwen3-next-80b` matches `CONTRACT_*_MODEL`'s
`openai/qwen3-next-80b` in Task 5 and Task 7's request bodies.
