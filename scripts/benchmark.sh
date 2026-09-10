#!/bin/bash
#
# Benchmark a chat backend against what the gpu/<task>/<role> contract
# actually promises: tool calling, JSON schema compliance, >=32k context, and
# latency/throughput separated into the interactive vs bulk cases.
#
# Standard serving benchmarks (llama-bench, vllm bench serve, guidellm) measure
# tokens/sec and TTFT but say nothing about whether tool calls parse or JSON
# validates — which is the whole value of the contract's chat roles. Run this
# ALONGSIDE one of those, not instead of it. See docs/BENCHMARKS.md.
#
# Usage:
#   scripts/benchmark.sh                          # via LiteLLM contract aliases
#   scripts/benchmark.sh --direct                 # straight at llama.cpp
#   scripts/benchmark.sh --model gpu/chat/bulk    # a specific alias
#   scripts/benchmark.sh --trials 20 --quick
#
# Uses only the Python standard library, deliberately: this box's system Python
# is PEP 668 externally-managed AND lacks ensurepip, so anything needing pip
# would have to run in a container and lose access to localhost networking.

set -uo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
[ -f "$PROJECT_ROOT/.env" ] && set -a && . "$PROJECT_ROOT/.env" && set +a

MODE=litellm; MODEL=""; TRIALS=10; QUICK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --direct)  MODE=direct; shift ;;
        --model)   MODEL="$2"; shift 2 ;;
        --trials)  TRIALS="$2"; shift 2 ;;
        --quick)   QUICK=1; shift ;;
        -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

if [ "$MODE" = "direct" ]; then
    BASE="http://localhost:${LLAMACPP_PORT:-8083}"
    KEY=""
    MODEL="${MODEL:-${LLAMACPP_MODEL_NAME:-llamacpp}}"
else
    _host="${LITELLM_BIND_ADDR:-localhost}"
    case "$_host" in ""|0.0.0.0|"[::]"|"::") _host="localhost" ;; esac
    BASE="http://${_host}:${LITELLM_PORT:-8080}"
    KEY="${LITELLM_MASTER_KEY:-}"
    MODEL="${MODEL:-gpu/chat/interactive}"
fi

echo "Benchmark: $MODE"
echo "  base   : $BASE"
echo "  model  : $MODEL"
echo "  trials : $TRIALS"
echo ""

BASE="$BASE" KEY="$KEY" MODEL="$MODEL" TRIALS="$TRIALS" QUICK="$QUICK" python3 - <<'PYEOF'
import json, os, statistics, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

BASE   = os.environ["BASE"].rstrip("/")
KEY    = os.environ.get("KEY") or ""
MODEL  = os.environ["MODEL"]
TRIALS = int(os.environ["TRIALS"])
QUICK  = os.environ["QUICK"] == "1"

G, R, Y, C, N = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0;36m", "\033[0m"

def post(payload, timeout=600, stream=False):
    body = json.dumps(payload).encode()
    h = {"Content-Type": "application/json"}
    if KEY:
        h["Authorization"] = f"Bearer {KEY}"
    req = urllib.request.Request(f"{BASE}/v1/chat/completions", data=body, headers=h)
    t0 = time.perf_counter()
    if not stream:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r), time.perf_counter() - t0, None
    ttft, chunks = None, []
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            data = line[6:]
            if data == "[DONE]":
                break
            if ttft is None:
                ttft = time.perf_counter() - t0
            try:
                d = json.loads(data)
                delta = d["choices"][0].get("delta", {})
                if delta.get("content"):
                    chunks.append(delta["content"])
            except Exception:
                pass
    return {"content": "".join(chunks), "n": len(chunks)}, time.perf_counter() - t0, ttft

def pct(vals, p):
    if not vals: return float("nan")
    s = sorted(vals); k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)

results = {}

# ---------------------------------------------------------------- latency
def latency(concurrency, prompt_tokens, label):
    """Streamed TTFT + inter-token latency. Streaming is what a chat UI does,
    and TTFT is invisible to a non-streaming timer."""
    prompt = "word " * prompt_tokens + "\nWrite exactly three short sentences about rain."
    def one(_):
        try:
            out, total, ttft = post(
                {"model": MODEL, "max_tokens": 96, "stream": True,
                 "messages": [{"role": "user", "content": prompt}]}, stream=True)
            n = out["n"] or 1
            return ttft, total, n, True
        except Exception as e:
            return None, None, 0, False
    n_req = max(concurrency, concurrency * (1 if QUICK else 2))
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        rows = list(ex.map(one, range(n_req)))
    wall = time.perf_counter() - t0
    ok = [r for r in rows if r[3]]
    if not ok:
        print(f"  {R}✗{N} {label}: all {n_req} requests failed")
        return
    ttfts = [r[0] for r in ok if r[0] is not None]
    toks  = sum(r[2] for r in ok)
    tpots = [((r[1] - r[0]) / max(r[2] - 1, 1)) * 1000 for r in ok if r[0] is not None and r[2] > 1]
    print(f"  {label}")
    print(f"      requests {len(ok)}/{n_req}   wall {wall:6.2f}s   output {toks/wall:7.1f} tok/s aggregate")
    if ttfts:
        print(f"      TTFT     p50 {pct(ttfts,50)*1000:7.0f} ms   p95 {pct(ttfts,95)*1000:7.0f} ms")
    if tpots:
        print(f"      TPOT     p50 {pct(tpots,50):7.1f} ms   -> {1000/pct(tpots,50):5.1f} tok/s per stream")
    results[label] = {"agg_tok_s": toks/wall, "ttft_p50_ms": pct(ttfts,50)*1000 if ttfts else None,
                      "tpot_p50_ms": pct(tpots,50) if tpots else None, "ok": len(ok), "sent": n_req}

print(f"{C}== 1. Latency / throughput ==={N}")
print("   interactive+fast care about TTFT and per-stream TPOT; bulk cares about aggregate.")
latency(1, 200,  "concurrency 1,  ~200 tok prompt   (interactive / fast)")
if not QUICK:
    latency(4, 200,  "concurrency 4,  ~200 tok prompt   (bulk, = LLAMACPP_PARALLEL)")
    latency(8, 200,  "concurrency 8,  ~200 tok prompt   (oversubscribed: 8 > 4 slots)")
latency(1, 8000, "concurrency 1,  ~8k tok prompt    (prefill-dominated)")

# ------------------------------------------------------------ tool calling
print(f"\n{C}== 2. Tool calling ==={N}")
print("   Promised by interactive/bulk/fast. A dropped tool call does not error —")
print("   the request succeeds and the call is silently missing.")
TOOL = [{"type": "function", "function": {
    "name": "get_weather", "description": "Get current weather for a city",
    "parameters": {"type": "object",
                   "properties": {"city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}},
                   "required": ["city"]}}}]
cases = [
    ("single arg",     "What is the weather in Pune? Use the tool.",                    {"city"}),
    ("two args",       "Weather in Mumbai in fahrenheit? Use the tool.",                {"city", "unit"}),
    ("negative case",  "Say the word BLUE. Do not call any tool.",                      None),
]
for name, prompt, want in cases:
    good = 0; parsed_ok = 0
    for _ in range(TRIALS):
        try:
            d, _, _ = post({"model": MODEL, "max_tokens": 160, "tools": TOOL,
                            "messages": [{"role": "user", "content": prompt}]})
            m = d["choices"][0]["message"]
            tc = m.get("tool_calls") or []
            if want is None:
                good += 1 if not tc else 0
                parsed_ok += 1
            else:
                if tc:
                    parsed_ok += 1
                    args = json.loads(tc[0]["function"]["arguments"])
                    if tc[0]["function"]["name"] == "get_weather" and want <= set(args):
                        good += 1
        except Exception:
            pass
    rate = good / TRIALS * 100
    col = G if rate >= 90 else (Y if rate >= 70 else R)
    extra = "" if want is None else f"  (emitted a call in {parsed_ok}/{TRIALS})"
    print(f"  {col}{rate:5.0f}%{N} {name:16} {good}/{TRIALS}{extra}")
    results[f"tool:{name}"] = rate

# ----------------------------------------------------------- json schema
print(f"\n{C}== 3. Structured output (response_format json_schema) ==={N}")
print("   Promised by interactive/bulk/fast. This is the failure the stack's")
print("   xgrammar/disable_any_whitespace note is about: invalid JSON costs a")
print("   full generation plus a repair retry.")
SCHEMAS = [
    ("flat object", {"type": "object", "properties": {"city": {"type": "string"}, "state": {"type": "string"}},
                     "required": ["city", "state"], "additionalProperties": False},
     "Pune is a city in the state of Maharashtra, India."),
    ("nested+array", {"type": "object", "properties": {
        "country": {"type": "string"},
        "cities": {"type": "array", "items": {"type": "object", "properties": {
            "name": {"type": "string"}, "pop_millions": {"type": "number"}},
            "required": ["name", "pop_millions"]}}},
        "required": ["country", "cities"], "additionalProperties": False},
     "India has Mumbai (21 million) and Delhi (32 million)."),
    ("enum+int", {"type": "object", "properties": {
        "sentiment": {"type": "string", "enum": ["positive", "negative", "neutral"]},
        "score": {"type": "integer"}},
        "required": ["sentiment", "score"], "additionalProperties": False},
     "This product is fantastic, I love it."),
]
for name, schema, text in SCHEMAS:
    valid = 0; conform = 0
    for _ in range(TRIALS):
        try:
            d, _, _ = post({"model": MODEL, "max_tokens": 300,
                            "messages": [{"role": "user", "content": text}],
                            "response_format": {"type": "json_schema",
                                                "json_schema": {"name": "s", "schema": schema}}})
            c = d["choices"][0]["message"]["content"]
            obj = json.loads(c)
            valid += 1
            if set(schema["required"]) <= set(obj):
                conform += 1
        except Exception:
            pass
    rate = conform / TRIALS * 100
    col = G if rate >= 95 else (Y if rate >= 80 else R)
    print(f"  {col}{rate:5.0f}%{N} {name:14} parsed {valid}/{TRIALS}, required keys present {conform}/{TRIALS}")
    results[f"json:{name}"] = rate

# ---------------------------------------------------------- long context
print(f"\n{C}== 4. Long context ==={N}")
print("   interactive/bulk promise >=32k PER SLOT. Short probes cannot see this;")
print("   a misconfigured pool fails only here.")
for depth in ([4000] if QUICK else [4000, 16000, 30000]):
    secret = f"PLUM-{depth}"
    filler = "The quick brown fox jumps over the lazy dog. " * (depth // 9)
    mid = len(filler) // 2
    prompt = (filler[:mid] + f"\n\nIMPORTANT: the passphrase is {secret}.\n\n" + filler[mid:]
              + "\n\nWhat is the passphrase? Answer with the passphrase only.")
    try:
        d, dt, _ = post({"model": MODEL, "max_tokens": 24,
                         "messages": [{"role": "user", "content": prompt}]}, timeout=900)
        got = (d["choices"][0]["message"]["content"] or "").strip()
        u = d.get("usage", {}) or {}
        hit = secret in got
        col = G if hit else R
        print(f"  {col}{'✓' if hit else '✗'}{N} ~{depth//1000:2d}k words  "
              f"prompt_tokens={u.get('prompt_tokens','?'):>6}  {dt:6.2f}s  "
              f"needle={'found' if hit else repr(got[:40])}")
        results[f"ctx:{depth}"] = hit
    except urllib.error.HTTPError as e:
        print(f"  {R}✗{N} ~{depth//1000:2d}k words  HTTP {e.code}: {e.read()[:120].decode('utf-8','replace')}")
        results[f"ctx:{depth}"] = False
    except Exception as e:
        print(f"  {R}✗{N} ~{depth//1000:2d}k words  {type(e).__name__}: {e}")
        results[f"ctx:{depth}"] = False

print(f"\n{C}== summary =={N}")
fails = [k for k, v in results.items() if v is False or (isinstance(v, (int, float)) and k.startswith(("tool:", "json:")) and v < 70)]
print(f"  {G}all contract dimensions passed{N}" if not fails else f"  {R}attention: {', '.join(fails)}{N}")
print(json.dumps({k: (round(v, 2) if isinstance(v, float) else v) for k, v in results.items()
                  if not isinstance(v, dict)}, indent=2))
PYEOF
