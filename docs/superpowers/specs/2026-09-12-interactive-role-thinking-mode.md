# `gpu/chat/interactive` must serve with thinking OFF

**Status:** implemented 2026-09-12
**Touches:** `config/litellm/config.yaml` (alias layer only — no engine restart)

## Problem

On 2026-09-12 `gpu/chat/bulk`, `gpu/chat/fast` and `gpu/chat/vision` each gained
`chat_template_kwargs: {enable_thinking: false}`. `gpu/chat/interactive` was left
as the one chat role that still serves a hybrid-thinking model in thinking mode.

The contract this stack publishes for that alias is *"tool-calling, ≥32k ctx,
JSON `response_format`, latency-tuned"*. Measured on ddai4 against
`nvidia/Qwen3.6-35B-A3B-NVFP4` (vLLM 0.29.0, n=20 per cell, identical OSINT
entity-extraction prompt), thinking-on breaks two of those four promises:

| metric | `gpu/chat/interactive` | `gpu/chat/bulk` |
|---|---|---|
| `json_schema` p50 latency | **8.65 s** | 0.52 s |
| `json_schema` p95 latency | **9.70 s** | 0.56 s |
| p50 output tokens | **1537** (1466 reasoning) | 70 (0 reasoning) |
| `json_object` p50 / p95 | **10.39 s / 22.71 s** | 0.17 s |
| `json_object` parse failures | **8 / 20 (40%)** | 0 / 20 |
| entity recall (vessels, places) | 1.00 / **0.58** on the malformed runs | 1.00 |

Two distinct failure modes, both of which the other three roles were fixed for:

1. **Malformed JSON.** vLLM applies the JSON grammar from the first *content*
   token while `enable_in_reasoning=False` leaves the reasoning span
   unconstrained; the reasoning→content handoff intermittently emits a corrupt
   prefix (observed: `{": {": {"orgs": [...` and
   `{": ": "CMS Singapore", "Sovcomflot": "Singapore", ...`). A consumer sees an
   intermittent structured-output parse failure and burns a full generation plus
   its retries on it.
2. **`content: null` with `finish_reason: length`.** The model spends the token
   budget reasoning before emitting any content, so a modest `max_tokens`
   returns an empty answer rather than an error. Reproduced at `max_tokens` 64
   and 300; median reasoning spend on a routine extraction is ~1.5k tokens.

The second mode is the dangerous one for this stack's main consumer: ember-ai's
sync `process_gpt` path runs `extract_json(None)`, which returns `{}` — recorded
as a **successful** call with an empty extraction.

Reasoning bought no accuracy on the measured task: vessel and place recall were
1.00 both with and without it.

## Decision

Add `chat_template_kwargs: {enable_thinking: false}` to `gpu/chat/interactive`,
with the same rationale as the other three roles.

This is not a claim that reasoning is worthless — it is that a *published role*
whose contract promises JSON and low latency must not have it on by default. A
consumer that wants reasoning for a specific call sends
`extra_body: {"chat_template_kwargs": {"enable_thinking": true}}`, which wins by
the router's merge order. On a non-thinking model the kwarg is inert.

## Non-goals

- Changing engine flags. This is an alias-layer change; no vLLM restart.
- Removing the `qwen3` reasoning parser. It stays, so a consumer that opts back
  in still gets `reasoning_content` split out of `content`.

## Verification

`./scripts/health-check.sh` (probes the alias names, not the backends) plus the
before/after table above. The harness is `scripts/chain-bench.sh` — the table
is its `--compare` output, and re-measuring after a model or box change is:

```bash
scripts/chain-bench.sh --label before   # ... change ...   --label after
scripts/chain-bench.sh --compare before after
```

Confirmed after the change, n=20 per cell: `json_schema` p50 0.52 s, output 70
tokens with 0 reasoning; `json_object` 20/20 parsed with recall back to 1.00;
`bulk`, `fast`, embeddings, rerank and the concurrency curve all unchanged.
Tool calling still works, and `extra_body {"chat_template_kwargs":
{"enable_thinking": true}}` still opts back in (146 reasoning tokens).
