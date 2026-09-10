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
    errs = []
    def one(_):
        # Record WHY a request failed. Swallowing the exception turns a real
        # gateway fault into an unexplained "7/8" that looks like noise.
        try:
            out, total, ttft = post(
                {"model": MODEL, "max_tokens": 96, "stream": True,
                 "messages": [{"role": "user", "content": prompt}]}, stream=True)
            n = out["n"] or 1
            return ttft, total, n, True
        except urllib.error.HTTPError as e:
            try:
                detail = e.read()[:200].decode("utf-8", "replace")
            except Exception:
                detail = ""
            errs.append(f"HTTP {e.code}: {detail}")
            return None, None, 0, False
        except Exception as e:
            errs.append(f"{type(e).__name__}: {e}")
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
    if errs:
        from collections import Counter
        for msg, cnt in Counter(errs).most_common(3):
            print(f"      {R}{cnt} failed{N}: {msg}")
    results[label] = {"agg_tok_s": toks/wall, "ttft_p50_ms": pct(ttfts,50)*1000 if ttfts else None,
                      "tpot_p50_ms": pct(tpots,50) if tpots else None, "ok": len(ok), "sent": n_req,
                      "errors": errs[:3]}

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

# ------------------------------------------------------- task shapes
print(f"\n{C}== 5. Task shapes ==={N}")
print("   The work this stack actually serves. Each case has a checkable answer,")
print("   so this measures usable output rather than plausible-looking output.")

TASKS = [
    # (name, messages, extra params, checker)
    ("extraction",
     [{"role": "user", "content":
       "Extract the invoice fields as JSON.\n\n"
       "INVOICE\nVendor: Crimson Energy Pvt Ltd\nInvoice No: CE-2291\n"
       "Date: 2026-03-14\nSubtotal: 48200.00 INR\nGST 18%: 8676.00 INR\n"
       "Total: 56876.00 INR"}],
     {"response_format": {"type": "json_schema", "json_schema": {"name": "inv", "schema": {
         "type": "object", "properties": {
             "invoice_no": {"type": "string"}, "total": {"type": "number"},
             "currency": {"type": "string"}},
         "required": ["invoice_no", "total", "currency"], "additionalProperties": False}}}},
     lambda t: (lambda o: o.get("invoice_no") == "CE-2291" and abs(float(o.get("total", 0)) - 56876.0) < 0.5)(json.loads(t))),

    ("classification",
     [{"role": "user", "content":
       "Classify the support ticket into exactly one of: billing, outage, feature_request, security.\n\n"
       "Ticket: 'Our API keys appear in the response headers of /v1/status. Please advise urgently.'"}],
     {"response_format": {"type": "json_schema", "json_schema": {"name": "cls", "schema": {
         "type": "object", "properties": {"label": {"type": "string",
             "enum": ["billing", "outage", "feature_request", "security"]}},
         "required": ["label"], "additionalProperties": False}}}},
     lambda t: json.loads(t).get("label") == "security"),

    ("grounded QA (answer present)",
     [{"role": "user", "content":
       "Answer ONLY from the context. If the answer is not in the context, reply exactly: NOT_IN_CONTEXT\n\n"
       "Context: The Ratnagiri plant commissioned its second 40 MW turbine in "
       "August 2025. The first turbine, rated 25 MW, has run since 2019.\n\n"
       "Question: What is the rating of the turbine commissioned in August 2025?"}],
     {}, lambda t: "40" in t and "NOT_IN_CONTEXT" not in t),

    ("grounded QA (must refuse)",
     [{"role": "user", "content":
       "Answer ONLY from the context. If the answer is not in the context, reply exactly: NOT_IN_CONTEXT\n\n"
       "Context: The Ratnagiri plant commissioned its second 40 MW turbine in "
       "August 2025. The first turbine, rated 25 MW, has run since 2019.\n\n"
       "Question: Who is the plant manager at Ratnagiri?"}],
     {}, lambda t: "NOT_IN_CONTEXT" in t.upper()),

    # Two variants of the SAME arithmetic, deliberately. The gap between them
    # is the finding: this model cannot do multi-step arithmetic in one shot,
    # but is reliable when the schema gives it somewhere to work.
    # "forced terse" is EXPECTED to score poorly — it documents the trap, and
    # a sudden 100% there would mean the model changed, not that a bug is gone.
    ("arithmetic, forced terse [expected poor]",
     [{"role": "user", "content":
       "A turbine generates 40 MW. It runs at 82% capacity factor for a full "
       "365-day year. Electricity sells at 4.5 INR per kWh. What is the annual "
       "revenue in crore INR? Reply with just the number, rounded to one decimal."}],
     {"temperature": 0},
     lambda t: any(abs(float(n) - 129.3) < 1.0
                   for n in __import__("re").findall(r"\d+\.\d+|\d+", t.replace(",", "")))),

    ("arithmetic, steps+schema",
     [{"role": "user", "content":
       "A turbine generates 40 MW. It runs at 82% capacity factor for a full "
       "365-day year. Electricity sells at 4.5 INR per kWh. What is the annual "
       "revenue in crore INR? Show your steps."}],
     {"temperature": 0,
      "response_format": {"type": "json_schema", "json_schema": {"name": "calc", "schema": {
          "type": "object", "properties": {
              "steps": {"type": "array", "items": {"type": "string"}, "minItems": 2},
              "answer_crore_inr": {"type": "number"}},
          "required": ["steps", "answer_crore_inr"], "additionalProperties": False}}}},
     lambda t: abs(float(json.loads(t)["answer_crore_inr"]) - 129.3) < 1.0),

    ("tool selection among several",
     [{"role": "user", "content": "What will the weather be in Pune tomorrow?"}],
     {"tools": [
         {"type": "function", "function": {"name": "search_docs",
          "parameters": {"type": "object", "properties": {"q": {"type": "string"}}, "required": ["q"]}}},
         {"type": "function", "function": {"name": "get_weather",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}},
         {"type": "function", "function": {"name": "send_email",
          "parameters": {"type": "object", "properties": {"to": {"type": "string"}}, "required": ["to"]}}}]},
     "TOOL:get_weather"),

    ("code generation",
     [{"role": "user", "content":
       "Write a Python function `dedupe_keep_order(xs)` returning a list with "
       "duplicates removed, preserving first-seen order. Code only, no prose, no markdown fence."}],
     {}, lambda t: (lambda ns: (exec(t.replace("```python","").replace("```",""), ns),
                                ns["dedupe_keep_order"]([3,1,3,2,1]) == [3,1,2])[1])({})),
]

for name, msgs, extra, check in TASKS:
    lats, good = [], 0
    n = max(3, TRIALS // 3)
    for _ in range(n):
        try:
            payload = {"model": MODEL, "max_tokens": 400, "messages": msgs}
            payload.update(extra)
            d, dt, _ = post(payload, timeout=300)
            lats.append(dt)
            m = d["choices"][0]["message"]
            if isinstance(check, str) and check.startswith("TOOL:"):
                tc = m.get("tool_calls") or []
                if tc and tc[0]["function"]["name"] == check[5:]:
                    good += 1
            else:
                if check((m.get("content") or "").strip()):
                    good += 1
        except Exception:
            pass
    rate = good / n * 100
    col = G if rate >= 90 else (Y if rate >= 60 else R)
    lat = f"{statistics.median(lats):5.2f}s" if lats else "  n/a"
    print(f"  {col}{rate:5.0f}%{N} {name:30} {good}/{n}   median {lat}")
    results[f"task:{name}"] = rate

print(f"\n{C}== summary =={N}")
fails = [k for k, v in results.items()
         if v is False or (isinstance(v, (int, float)) and k.startswith(("tool:", "json:", "task:"))
                           and "expected poor" not in k and v < 70)]
print(f"  {G}all contract dimensions passed{N}" if not fails else f"  {R}attention: {', '.join(fails)}{N}")
print(json.dumps({k: (round(v, 2) if isinstance(v, float) else v) for k, v in results.items()
                  if not isinstance(v, dict)}, indent=2))
PYEOF
