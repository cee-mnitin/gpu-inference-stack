# Three engine knobs, measured: one removed, two deliberately left alone

**Status:** implemented 2026-09-12
**Touches:** `servers/common-blackwell-32gb.env` (comments + one inert flag removed)

An audit of the ember → GPU chain surfaced three suspicious things about the
vLLM engine on the ddai boxes. All three were measured before anything was
changed, and two of them turned out to be correct as they stood. Recording that
is the point of this document: the next person to read
`VLLM_GPU_MEMORY_UTILIZATION=0.84` beside a vLLM log line offering more KV
cache will otherwise re-litigate it from scratch.

## 1. `--block-size 128` was inert — removed

The profile passed `--block-size 128`. It never took effect. Qwen3.6 is a
hybrid GDN model, and `vllm/platforms/interface.py` does:

```python
if cache_config.block_size < attn_block_size:
    cache_config.block_size = attn_block_size
    logger.info("Setting attention block size to %d tokens "
                "to ensure that attention page size is >= mamba page size.")
```

`attn_block_size` resolves to **2176** here, so both the requested 128 and
vLLM's own default of 16 clamp to the same value. The flag changed nothing
while reading, in a committed profile, as a deliberate tuning choice.

**The 2176 is the part worth knowing**, because it is the granularity prefix
caching operates at. The engine reported a **0% prefix-cache hit rate over
77,000 queries**, which looks like a broken feature. It is not. Measured on
ddai4, the same system prompt sent four times:

| shared prefix | hit rate | TTFT first → later |
|---|---:|---|
| ~1.9k tokens | 0.0% | 0.18 s → 0.18 s |
| ~4.2k tokens | 39.0% | 0.33 s → 0.19 s |
| ~8.0k tokens | 67.8% | 0.49 s → 0.18 s |

Prefix caching works. It simply cannot hit a shared prefix shorter than one
block, and ember's graph chunks (~1200 tokens behind a short system prompt)
never reach it. The lever is prompt shape, not a flag — and there is no flag,
since the block size is model-derived.

One further consequence worth recording: **enabling prefix caching is what
makes the block this large.** The same function picks a smaller
alignment-only block when prefix caching is off. On a workload whose prefixes
are all under 2176 tokens, `--enable-prefix-caching` is therefore not free —
it buys nothing and coarsens allocation. Left on, because the cost is small and
a workload with longer shared prefixes is a prompt change away.

## 2. KV cache headroom — offered, declined

vLLM says on every boot:

```
Replace gpu_memory_utilization config with `--kv-cache-memory=2705341952` (2.52 GiB)
to fit into requested memory, or `--kv-cache-memory=3839180288` (3.58 GiB) to fully
utilize gpu memory. Current kv cache memory in use is 2.85 GiB.
```

Taking the offer means claiming the last of a card Infinity shares (26.1 GB
vLLM + 3.8 GB Infinity of 32.6 GB today). So the question is whether anything
wants the cache — and nothing does:

- 204,055 tokens of KV, "Maximum concurrency for 32,768 tokens per request: 6.23x".
- **6 concurrent ~26k-token prompts (77% of cache): 0 preemptions, 0 errors.**
- **12 concurrent ~26k-token prompts (154% of cache, deliberately
  oversubscribed): 0 preemptions, 0 errors** — the scheduler queues, which is
  the correct behaviour and costs 19.4 s wall for twelve 26k-token requests.
- The chat concurrency sweep preempts nothing at 64 in flight either.

Buying headroom nothing is asking for, at the price of the OOM margin on a
shared card, is a bad trade. Left at 0.84. The number to watch if this is ever
revisited is `vllm:num_preemptions_total`, which `scripts/chain-bench.sh`
records for every run.

Context behaves correctly at the contract floor: 26k-token prompts succeed,
32.7k is refused with a clean `ContextWindowExceededError` rather than a
truncation. The model's own `max_position_embeddings` is 262144, but 204k
tokens of total KV makes a 256k context academic, and the contract promises
≥32k.

## 3. FP4 falls back to Marlin — the checkpoint, not the card

```
WARNING [marlin.py:34] Your GPU does not have native support for FP4 computation
but FP4 quantization is being used. Weight-only FP4 compression will be used
leveraging the Marlin kernel. This may degrade performance for compute-heavy
workloads.
INFO Using 'MARLIN' NvFp4 MoE backend out of potential backends:
['FLASHINFER_TRTLLM', 'FLASHINFER_CUTEDSL', 'FLASHINFER_CUTEDSL_BATCHED',
 'FLASHINFER_CUTLASS', 'VLLM_CUTLASS', 'MARLIN', 'HUMMING', 'EMULATION']
```

The obvious reading — "sm_120 is too new / too small for the fast kernels" — is
wrong, and worth refuting explicitly so nobody spends a maintenance window on
`--kernel-config`. Evaluated in the running container:

```
capability        DeviceCapability(major=12, minor=0)
cutlass_fp4_supported()   True
has_flashinfer_cutlass_fused_moe()   True
```

The card supports CUTLASS FP4. The fallback is driven by the **checkpoint**:
`nvidia/Qwen3.6-35B-A3B-NVFP4` is `modelopt_mixed`, and vLLM detects
`NVFP4`, **`W4A16_NVFP4`** and `MXFP8` blocks in it. `W4A16` means 4-bit weights
against 16-bit activations — there is no FP4 GEMM for the tensor cores to do,
so weight-only Marlin is the correct kernel, not a degraded one.

The lever is a W4A4 checkpoint, which is a model change with accuracy
consequences and its own eval, not a flag. Not attempted here.

## Verification

No engine restart was needed for any of this: the removed flag was inert, and
the other two are unchanged. `scripts/chain-bench.sh --label <name>` records
the preemption and prefix-cache counters that back the two "leave it alone"
decisions, so a future change that invalidates them shows up in a comparison.
