# Benchmarking a chat backend on this stack

Three layers, because no single tool covers what matters here.

| layer | tool | answers |
|---|---|---|
| raw engine | `llama-bench` | how fast can this quant prefill and decode on this card, with no server in the way |
| serving | `vllm bench serve` / `guidellm` | TTFT, TPOT, throughput under concurrency, against the OpenAI endpoint |
| **contract** | `scripts/benchmark.sh` | do tool calls parse, does JSON validate, does ≥32k context actually work |

The third layer is the one that is easy to skip and the one most likely to be
broken. `gpu/chat/interactive`, `/bulk` and `/fast` promise **tool calling,
JSON `response_format`, and ≥32k context** — none of which a tokens/sec
benchmark measures. A backend can hit 40 tok/s and still drop every tool call.

## Layer 3: contract dimensions

```bash
scripts/benchmark.sh                        # through LiteLLM's contract aliases
scripts/benchmark.sh --direct               # straight at llama.cpp, no gateway
scripts/benchmark.sh --model gpu/chat/bulk  # a specific role
scripts/benchmark.sh --trials 20            # more samples per correctness case
scripts/benchmark.sh --quick                # skip the concurrency sweep and deep context
```

Run it **both ways**. Comparing `--direct` against the LiteLLM path isolates
gateway overhead, and a difference in *correctness* between the two points at
alias configuration rather than the model — a wrong `chat_template_kwargs` or
a parser mismatch shows up as tool calls that work direct and vanish through
the gateway.

What it measures:

1. **Latency / throughput** — streamed, at concurrency 1, 4 and 8, with a
   short and a long prompt. Streaming matters: TTFT is invisible to a
   non-streaming timer, and TTFT is what `interactive` and `fast` are judged
   on. Concurrency 8 against 4 slots deliberately oversubscribes, to show
   queueing rather than hide it.
2. **Tool calling** — including a negative case. A model that calls tools when
   told not to is as broken as one that fails to call them, and only the
   negative case catches it. A dropped tool call does not error: the request
   succeeds with the call silently missing.
3. **Structured output** — flat, nested-with-array, and enum+integer schemas.
   Reported as both "parsed as JSON" and "required keys present", because
   valid-but-wrong-shape is a distinct failure a consumer still has to handle.
4. **Long context** — a passphrase buried mid-prompt at increasing depths.
   Retrieval, not just acceptance: a backend can accept a 30k prompt, silently
   truncate it, and answer confidently from the wrong half.

It uses only the Python standard library. That is deliberate — this box's
system Python is PEP 668 externally-managed and has no `ensurepip`, so
anything pip-installed would have to run in a container and lose easy access
to `localhost`.

## Layer 1: raw engine (`llama-bench`)

The `server-cuda` image ships the bench shared libraries but not the
executables; use the `full-cuda` image at the same build:

```bash
docker run --rm --gpus all \
  -v "$PWD/data/llamacpp/models:/models:ro" \
  --entrypoint /app/llama-bench \
  ghcr.io/ggml-org/llama.cpp:full-cuda-b10884 \
  -m /models/Qwen3-Next-80B-A3B-Instruct-UD-Q3_K_XL.gguf \
  -p 512,4096 -n 128 -r 3
```

`-p` is prefill batch size, `-n` decode tokens, `-r` repetitions. Note that
`llama-bench` does **not** read `LLAMA_ARG_*`, so pass `-ngl`/`--n-cpu-moe`
explicitly if you want to reproduce the server's placement — otherwise it
benchmarks a different configuration than you are serving.

## Layer 2: serving under load

`guidellm` 0.7.3's CLI is `guidellm run` with `kind=`-style arguments — not
the `guidellm benchmark --target ...` form that older docs show. It also needs
a real HF tokenizer to synthesise prompts, and defaults to the *served* model
name, which is not a repo id — so `--tokenizer` is mandatory here:

```bash
docker build -t local/guidellm:0.7.3 - <<'DF'
FROM python:3.12-slim
RUN pip install --no-cache-dir guidellm==0.7.3
ENTRYPOINT ["guidellm"]
DF

docker run --rm --network host -v "$PWD/data/huggingface:/hf" -e HF_HOME=/hf \
  local/guidellm:0.7.3 run \
  --backend kind=openai_http,target=http://localhost:8083,model=qwen3-next-80b \
  --profile kind=concurrent,streams=4 \
  --data kind=synthetic_text,prompt_tokens=256,output_tokens=128 \
  --constraint kind=max_requests,count=16 \
  --tokenizer kind=hf_auto,model=Qwen/Qwen3-Next-80B-A3B-Instruct \
  --disable-console-interactive
```

`--network host` is required because port 8083 is bound to loopback.
Run one invocation per `streams` value; a comma list is not parsed there.

It reports TTFT/ITL/TPOT/throughput distributions but does not validate
output, which is why layer 3 exists.

## Interpreting results against the roles

| role | what to look at | why |
|---|---|---|
| `gpu/chat/fast` | TTFT p95 at concurrency 1 | it carries a 60s timeout in `config.yaml` |
| `gpu/chat/interactive` | TPOT p50, and ≥32k context | perceived typing speed |
| `gpu/chat/bulk` | aggregate tok/s at concurrency = `LLAMACPP_PARALLEL` | throughput-tuned |
| all three | tool + JSON rates | the contract's actual promise |

A tool-call or JSON rate below ~90% is a reason to change quant before
changing anything else — see the quant table in
[LLAMACPP.md](LLAMACPP.md#choosing-a-quant-for-a-48-gb-card).

## Recorded results

**A6000 48GB (`sm_86`) · Qwen3-Next-80B-A3B-Instruct `UD-Q3_K_XL` · llama.cpp
b10884 · 2026-09-10**

Config as deployed: `CTX_SIZE=163840`, `PARALLEL=4` (40960/slot), f16 KV,
`fit on` with `NCMOE`/`NGL` unset, `LAZY_MODE=off`. Infinity co-resident.
Weights fully GPU-resident — `fit` chose `ncmoe 0`.

### Layer 1 — raw engine (`llama-bench`, `-ngl 999 -fa 1 -r 3`)

| test | t/s |
|---|---|
| `pp512` (prefill) | **2102.7 ± 160.3** |
| `pp4096` (prefill) | **2180.5 ± 6.3** |
| `tg128` (decode) | **122.9 ± 0.8** |

Prefill does not degrade from 512 to 4096 — it slightly improves, which is the
batching working. Model reported as 33.18 GiB / 79.67 B params.

### Layer 2 — serving (streamed, `scripts/benchmark.sh`)

| case | TTFT p50 | TPOT p50 | per-stream | aggregate |
|---|---|---|---|---|
| direct, concurrency 1, 200 tok | 281 ms | 9.6 ms | 104 t/s | 63 t/s |
| direct, concurrency 4, 200 tok | 307 ms | 20.9 ms | 48 t/s | **123 t/s** |
| direct, concurrency 8 (oversubscribed) | 1235 ms | 23.5 ms | 43 t/s | 143 t/s |
| direct, concurrency 1, 8k tok | 1555 ms | 9.0 ms | 111 t/s | 24 t/s |
| gateway, concurrency 4, 200 tok | 430 ms | 21.1 ms | 48 t/s | 129 t/s |
| gateway, concurrency 1, 8k tok | 517 ms | 9.7 ms | 103 t/s | 48 t/s |

**Gateway overhead: +78 ms TTFT p50** (359 vs 281 ms warm, 8 samples after 2
warmup). Per-token latency is unaffected, as it should be.

Decode is 123 t/s raw (`tg128`) against 104 t/s through HTTP at concurrency 1
— the gap is HTTP framing and sampling, not the model.

Concurrency 8 against 4 slots shows the queueing honestly: aggregate rises
(143 t/s) while TTFT p50 jumps 4x. Past 4 concurrent requests this box trades
latency for throughput, which is the right shape for `bulk` and the wrong one
for `fast`.

### Layer 2b — `guidellm` 0.7.3, controlled concurrency (direct, 256→128 tok)

| streams | TTFT p50 | TTFT p95 | ITL p50 | TPOT p50 | output t/s |
|---|---|---|---|---|---|
| 1 | 383 ms | 445 ms | 8.5 ms | 11.3 ms | 90.3 |
| **4** | 933 ms | 1304 ms | 17.3 ms | 24.5 ms | **166.4** |
| 8 | 4623 ms | 4958 ms | 17.1 ms | 53.0 ms | 158.7 |

**Throughput peaks at concurrency 4 and declines at 8**, while TTFT rises 5x.
Past 4 slots there is no trade — you lose latency *and* throughput. This puts
`LLAMACPP_PARALLEL=4` exactly at the knee, and gives consumers a hard ceiling:
**do not exceed 4 in-flight requests to this box.**

Worth noting the two tools disagree in a useful way. `scripts/benchmark.sh`
showed aggregate throughput still *rising* from concurrency 4 to 8 (123→143
t/s) because it fires unpaced bursts; guidellm's paced load exposes the
decline. Cross-checking with an independent tool is what surfaced the knee —
neither number is wrong, they measure different arrival patterns.

TTFT/ITL otherwise corroborate layer 2 closely (383 ms vs 281 ms at
concurrency 1; the gap is guidellm's 264-token prompt against ~200, plus
tokenization).

### Layer 3 — contract dimensions

| dimension | result |
|---|---|
| tool call, single arg | **100%** (10/10) |
| tool call, two args | **100%** (10/10) |
| tool call, negative case | **100%** (10/10) |
| JSON flat object | **100%** parsed + conformant |
| JSON nested + array | **100%** parsed + conformant |
| JSON enum + integer | **100%** parsed + conformant |
| context 4.5k tokens | ✓ needle retrieved |
| context 17.8k tokens | ✓ needle retrieved |
| context 33.4k tokens | ✓ needle retrieved |
| context 37.8k tokens | ✓ needle retrieved |

Identical direct and through the gateway — no correctness is lost in the
LiteLLM path.

### Layer 3b — task shapes (the work this stack actually serves)

| task | result | median latency |
|---|---|---|
| extraction (invoice → JSON) | **100%** | 0.58 s |
| classification (enum label) | **100%** | 0.46 s |
| grounded QA, answer present | **100%** | 0.16 s |
| grounded QA, must refuse | **100%** | 0.14 s |
| tool selection among 3 tools | **100%** | 0.30 s |
| code generation (executed and asserted) | **100%** | 0.46 s |
| arithmetic, forced terse | **0%** | 0.21 s |
| arithmetic, steps + schema | **100%** | 3.81 s |

The grounded-QA pair matters most for a stack feeding a retrieval plane: the
model answers from context when the answer is there **and** returns
`NOT_IN_CONTEXT` when it is not. Hallucinating under a "answer only from
context" instruction would be the expensive failure, and it does not.

Code generation is checked by `exec`-ing the output and asserting behaviour,
not by looking for plausible-looking code.

#### The arithmetic finding — read this before writing prompts

Same calculation, three ways:

| prompting | correct | tokens | terminates |
|---|---|---|---|
| "reply with just the number" | **0/5** | 6 | ✓ |
| "work step by step" | 3/3 | 2500+ | ✗ `finish=length` |
| **schema with `steps[]` + `answer`** | **4/4** | 398 | ✓ |

Forced terse, it answers in 6 tokens and is confidently wrong — 136.3, 137.2,
163.1, 216.7 against a true 129.3. Given room to work it is correct, but keeps
deliberating past 2500 tokens and never emits a clean final line.

A JSON schema with a working field fixes both: it gives the model somewhere to
compute and forces termination. **This is the pattern to use for any computed
value**, and it matters here because `gpu/chat/bulk` and `gpu/chat/fast` set
`enable_thinking: false` — which is precisely the terse regime.

This is not a quant artifact to fix by moving to `IQ4_XS`; it is how the model
behaves when denied working space.

`UD-Q3_K_XL` was chosen for residency over fidelity, so 100% on tool calling
and structured output at Q3 is the load-bearing result: it removes the reason
to move to `IQ4_XS` and accept expert offload.

### Two findings this produced

3. **Concurrency beyond `PARALLEL` is strictly worse**, not a latency /
   throughput trade — throughput fell from 166.4 to 158.7 t/s while TTFT went
   from 933 ms to 4623 ms.
4. **Computed values need a schema with a working field.** Forced-terse
   arithmetic was 0/5 and confidently wrong.

1. **Per-slot context must exceed the contract floor.** At exactly 32768 a
   real 32k prompt was rejected — `request (33366 tokens) exceeds the
   available context size (32768 tokens)` — because prompt and generation
   share the slot. Raised to 40960/slot for ~0.75 GiB more KV.
2. **`--detailed_debug` cost 3.2x TTFT and dropped requests.** 917 ms vs
   290 ms with identical TPOT, and 7/8 and 15/16 completions where llama.cpp
   itself logged no errors. Now off by default.

### Reproducing

```bash
scripts/benchmark.sh --direct --trials 10   # engine + contract
scripts/benchmark.sh --trials 10            # through the contract aliases
```

`llama-bench` needs the model to itself — stop the service first, since it
holds 36.8 GiB:

```bash
docker compose --profile llamacpp stop llamacpp
# ... run llama-bench as shown above ...
docker compose --profile llamacpp up -d llamacpp
```
