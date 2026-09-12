#!/usr/bin/env python3
"""Chain regression benchmark — driven by scripts/chain-bench.sh, which resolves
the server profile and passes the endpoints in the environment.

Kept as its own file rather than a heredoc inside the wrapper: at this length a
heredoc costs syntax highlighting, `python3 -m py_compile`, and the ability to
run one section under a debugger. Stdlib only (see the wrapper's header).

The gold set below is deliberately small and fixed. Its job is not to grade the
model — it is to catch a change that makes a role FASTER by extracting LESS,
which a latency-only harness reports as an unambiguous win.
"""
from __future__ import annotations

import json
import os
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

STACK_URL = os.environ["STACK_URL"].rstrip("/")
STACK_KEY = os.environ.get("STACK_KEY", "")
CONSUMER_URL = os.environ.get("CONSUMER_URL", "").rstrip("/")
CONSUMER_KEY = os.environ.get("CONSUMER_KEY", "")
VLLM_METRICS = os.environ.get("VLLM_METRICS", "")
TRIALS = int(os.environ.get("TRIALS", "20"))
OUT_DIR = os.environ.get("OUT_DIR", ".")
ONLY = {s.strip() for s in os.environ.get("ONLY", "").split(",") if s.strip()}

CHAT_ROLES = ("gpu/chat/interactive", "gpu/chat/bulk", "gpu/chat/fast")
EMBED_ALIAS = "gpu/embed/bge-m3"
RERANK_ALIAS = "gpu/rerank/bge-reranker-v2-m3"

# One paragraph with an unambiguous, hand-checked answer. Repeated to reach a
# realistic prompt length without inventing text whose gold set is arguable.
ARTICLE = (
    "Satellite imagery reviewed by analysts shows at least four sanctioned tankers conducting "
    "ship-to-ship transfers off Riau, Indonesia. The vessels - Sea Pearl, Nostos, Bright Star and "
    "Anna Maria - have all previously called at Kozmino. Analysts at the Centre for Maritime "
    "Security in Singapore say the pattern matches a widening dark-fleet network run through "
    "Dubai-based brokerages. The Indonesian Maritime Security Agency declined to comment. "
    "EU sanctions took effect 12 June. "
)
GOLD_VESSELS = {"sea pearl", "nostos", "bright star", "anna maria"}
GOLD_PLACES = {"riau", "indonesia", "kozmino", "singapore", "dubai"}
SYSTEM = "You are an OSINT extraction engine. Reply with JSON only."
EXTRACT_SCHEMA = {
    "type": "object",
    "properties": {
        "orgs": {"type": "array", "items": {"type": "string"}},
        "people": {"type": "array", "items": {"type": "string"}},
        "vessels": {"type": "array", "items": {"type": "string"}},
        "places": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["orgs", "people", "vessels", "places"],
    "additionalProperties": False,
}
KG_SCHEMA = {
    "type": "object",
    "properties": {
        "entities": {"type": "array", "items": {
            "type": "object",
            "properties": {"name": {"type": "string"}, "type": {"type": "string"}},
            "required": ["name", "type"], "additionalProperties": False}},
        "relations": {"type": "array", "items": {
            "type": "object",
            "properties": {"src": {"type": "string"}, "rel": {"type": "string"}, "dst": {"type": "string"}},
            "required": ["src", "rel", "dst"], "additionalProperties": False}},
    },
    "required": ["entities", "relations"],
    "additionalProperties": False,
}


def post(base, key, path, payload, timeout=900):
    req = urllib.request.Request(
        base + path, data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
    return json.loads(body), time.perf_counter() - t0


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1))))]


def response_format(mode, schema):
    if mode == "json_schema":
        return {"type": "json_schema",
                "json_schema": {"name": "o", "strict": True, "schema": schema}}
    return {"type": "json_object"}


def extraction(model, n, mode="json_schema", max_tokens=4096, base=None, key=None):
    """Latency, token spend, JSON-failure modes and recall for one role.

    `malformed` and `null_content` are counted separately on purpose: they have
    different causes (a corrupt reasoning->content handoff vs the token budget
    being spent reasoning) and different consumer symptoms (a parse error vs a
    silently empty result that some clients record as a success).
    """
    base = base or STACK_URL
    key = STACK_KEY if key is None else key
    lat, out, reasoning = [], [], []
    ok = bad = nul = 0
    vessel_recall, place_recall = [], []
    for i in range(n):
        try:
            d, dt = post(base, key, "/v1/chat/completions", {
                "model": model, "max_tokens": max_tokens, "temperature": 0.2,
                "response_format": response_format(mode, EXTRACT_SCHEMA),
                "messages": [
                    {"role": "system", "content": SYSTEM},
                    {"role": "user", "content": ARTICLE + f"\n\nExtract orgs, people, vessels, places. (case {i})"},
                ]})
        except urllib.error.HTTPError as exc:
            return {"model": model, "mode": mode, "error": f"HTTP {exc.code}: {exc.read()[:200]!r}"}
        lat.append(dt)
        usage = d.get("usage", {})
        out.append(usage.get("completion_tokens", 0))
        reasoning.append(usage.get("completion_tokens_details", {}).get("reasoning_tokens", 0))
        raw = d["choices"][0]["message"]["content"]
        if raw is None:
            nul += 1
            continue
        try:
            obj = json.loads(raw)
        except (ValueError, TypeError):
            bad += 1
            continue
        ok += 1
        got_v = {s.lower() for s in obj.get("vessels", []) if isinstance(s, str)}
        got_p = {s.lower() for s in obj.get("places", []) if isinstance(s, str)}
        vessel_recall.append(len(GOLD_VESSELS & got_v) / len(GOLD_VESSELS))
        # Substring match: a model may answer "Riau, Indonesia" as one place.
        place_recall.append(
            len([g for g in GOLD_PLACES if any(g in p for p in got_p)]) / len(GOLD_PLACES))
    return {
        "model": model, "mode": mode, "n": n,
        "p50_s": round(statistics.median(lat), 2), "p95_s": round(pct(lat, 95), 2),
        "p50_out_tok": int(statistics.median(out)),
        "p50_reasoning_tok": int(statistics.median(reasoning)),
        "total_out_tok": sum(out),
        "parse_ok": ok, "malformed": bad, "null_content": nul,
        "vessel_recall": round(statistics.mean(vessel_recall), 3) if vessel_recall else None,
        "place_recall": round(statistics.mean(place_recall), 3) if place_recall else None,
    }


def _fan_out(work, n_workers, n_items):
    """Run `work(i)` for i in range(n_items) across n_workers threads."""
    lock = threading.Lock()
    cursor = [0]
    results, errors = [], []

    def loop():
        while True:
            with lock:
                i = cursor[0]
                if i >= n_items:
                    return
                cursor[0] += 1
            try:
                r = work(i)
            except Exception as exc:  # noqa: BLE001 — a failed call is a datum
                with lock:
                    errors.append(repr(exc)[:120])
                continue
            with lock:
                results.append(r)

    threads = [threading.Thread(target=loop) for _ in range(n_workers)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results, errors, time.perf_counter() - t0


def concurrency(model, n, out_tokens=256):
    """Aggregate throughput at a fixed in-flight count — where the engine saturates."""
    def work(i):
        d, dt = post(STACK_URL, STACK_KEY, "/v1/chat/completions", {
            "model": model, "max_tokens": out_tokens, "temperature": 0.2,
            "messages": [{"role": "user", "content": ARTICLE * 2 + f"\nSummarise in 150 words. (#{i})"}]})
        return dt, d["usage"]["completion_tokens"]
    res, errs, wall = _fan_out(work, n, n)
    if not res:
        return {"n": n, "errors": errs[:2]}
    lat = [r[0] for r in res]
    return {"n": n, "wall_s": round(wall, 2),
            "p50_lat_s": round(statistics.median(lat), 2),
            "agg_tok_s": round(sum(r[1] for r in res) / wall, 1),
            "errors": len(errs)}


def graph_load(model, in_flight, chunks=96):
    """The shape ember's graph stage issues: many ~1200-token chunks -> KG JSON.

    Reported in chunks/min rather than tokens/s because that is the unit the
    stage is sized in, and because a config that emits fewer entities per chunk
    would look faster in tokens/s. `avg_entities` guards that.
    """
    chunk_text = ARTICLE * 14
    def work(i):
        d, dt = post(STACK_URL, STACK_KEY, "/v1/chat/completions", {
            "model": model, "max_tokens": 1024, "temperature": 0.2,
            "response_format": response_format("json_schema", KG_SCHEMA),
            "messages": [
                {"role": "system", "content": "You are a knowledge-graph extractor. Emit entities and relations as JSON."},
                {"role": "user", "content": chunk_text + f"\n\nChunk #{i}. Extract."},
            ]})
        try:
            n_ents = len(json.loads(d["choices"][0]["message"]["content"])["entities"])
        except Exception:  # noqa: BLE001
            n_ents = None
        return dt, d["usage"]["completion_tokens"], n_ents
    res, errs, wall = _fan_out(work, in_flight, chunks)
    if not res:
        return {"in_flight": in_flight, "errors": errs[:2]}
    lat = [r[0] for r in res]
    ents = [r[2] for r in res if r[2] is not None]
    return {"in_flight": in_flight, "chunks": chunks, "wall_s": round(wall, 1),
            "chunks_per_min": round(len(res) / wall * 60, 1),
            "p50_lat_s": round(statistics.median(lat), 2),
            "p95_lat_s": round(pct(lat, 95), 2),
            "agg_out_tok_s": round(sum(r[1] for r in res) / wall, 1),
            "avg_entities": round(statistics.mean(ents), 1) if ents else None,
            "errors": len(errs)}


def embed_rerank():
    doc = "Maritime interdiction operations in the Gulf of Aden have intensified. " * 10
    out = {}
    for batch in (1, 32, 128):
        try:
            d, dt = post(STACK_URL, STACK_KEY, "/v1/embeddings",
                         {"model": EMBED_ALIAS, "input": [doc + str(i) for i in range(batch)]})
        except Exception as exc:  # noqa: BLE001
            out[f"embed_b{batch}_docs_s"] = f"error: {exc!r}"[:80]
            continue
        out[f"embed_b{batch}_docs_s"] = round(batch / dt, 1)
        out.setdefault("embed_dim", len(d["data"][0]["embedding"]))
    try:
        _, dt = post(STACK_URL, STACK_KEY, "/v1/rerank",
                     {"model": RERANK_ALIAS, "query": "dark fleet sanctions evasion",
                      "documents": [doc + str(i) for i in range(50)], "top_n": 10})
        out["rerank_50_ms"] = round(dt * 1000, 1)
    except Exception as exc:  # noqa: BLE001
        out["rerank_50_ms"] = f"error: {exc!r}"[:80]
    return out


def hop_overhead():
    """Median round-trip of a trivial call at each tier, to attribute a regression.

    Thinking is forced off on the direct hop only: the aliases decide it for
    themselves, and overriding them here would measure a configuration this
    benchmark is supposed to be reporting on.
    """
    hops = [("stack_gateway", STACK_URL, STACK_KEY, "gpu/chat/bulk", False)]
    if CONSUMER_URL:
        hops.append(("consumer_gateway", CONSUMER_URL, CONSUMER_KEY, "gpu/chat/bulk", False))
    out = {}
    for name, base, key, model, force_nothink in hops:
        samples = []
        for _ in range(8):
            body = {"model": model, "messages": [{"role": "user", "content": "Say OK"}],
                    "max_tokens": 8}
            if force_nothink:
                body["chat_template_kwargs"] = {"enable_thinking": False}
            try:
                _, dt = post(base, key, "/v1/chat/completions", body)
            except Exception as exc:  # noqa: BLE001
                out[name + "_ms"] = f"error: {exc!r}"[:80]
                break
            samples.append(dt)
        if samples:
            out[name + "_ms"] = round(statistics.median(samples) * 1000, 1)
    return out


def vllm_metrics():
    """Prefix-cache and preemption counters, read straight from vLLM.

    Best effort: the engine port is loopback-bound on most profiles and absent
    on a box whose chat roles are delegated to a peer. A missing section is
    reported as such rather than failing the run.
    """
    if not VLLM_METRICS:
        return None
    try:
        with urllib.request.urlopen(VLLM_METRICS, timeout=15) as r:
            text = r.read().decode()
    except Exception as exc:  # noqa: BLE001
        return {"unavailable": repr(exc)[:100]}
    def counter(name):
        m = re.search(r"^vllm:%s\{[^}]*\} ([\d.e+]+)" % name, text, re.M)
        return float(m.group(1)) if m else None
    return {"prefix_cache_queries": counter("prefix_cache_queries_total"),
            "prefix_cache_hits": counter("prefix_cache_hits_total"),
            "preemptions": counter("num_preemptions_total")}


def run(label):
    result = {"label": label, "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
              "stack_url": STACK_URL, "trials": TRIALS}
    before = vllm_metrics()

    if "hops" in ONLY:
        print("  hops ...", flush=True)
        result["hop_overhead_ms"] = hop_overhead()
    if "extraction" in ONLY:
        print("  extraction (json_schema, each chat role) ...", flush=True)
        result["extraction"] = [extraction(m, TRIALS) for m in CHAT_ROLES]
        print("  extraction (json_object, each chat role) ...", flush=True)
        result["extraction_json_object"] = [extraction(m, TRIALS, mode="json_object") for m in CHAT_ROLES]
        if CONSUMER_URL:
            print("  extraction through the consumer gateway ...", flush=True)
            result["extraction_via_consumer"] = extraction(
                CHAT_ROLES[0], max(4, TRIALS // 2), base=CONSUMER_URL, key=CONSUMER_KEY)
    if "concurrency" in ONLY:
        print("  concurrency sweep ...", flush=True)
        result["concurrency"] = [concurrency("gpu/chat/bulk", n) for n in (1, 8, 16, 32, 64)]
    if "graph" in ONLY:
        print("  graph-shaped load ...", flush=True)
        result["graph_load"] = [graph_load("gpu/chat/bulk", n) for n in (8, 16, 24, 32, 48)]
    if "embed" in ONLY:
        print("  embeddings and rerank ...", flush=True)
        result["embed_rerank"] = embed_rerank()

    after = vllm_metrics()
    if before and after and "unavailable" not in before and "unavailable" not in after:
        queries = (after["prefix_cache_queries"] or 0) - (before["prefix_cache_queries"] or 0)
        hits = (after["prefix_cache_hits"] or 0) - (before["prefix_cache_hits"] or 0)
        result["vllm_during_run"] = {
            "prefix_cache_queries": queries, "prefix_cache_hits": hits,
            "prefix_hit_rate": round(hits / queries, 4) if queries else None,
            "preemptions": (after["preemptions"] or 0) - (before["preemptions"] or 0)}
    elif before:
        result["vllm_during_run"] = before
    return result


# --- comparison ------------------------------------------------------------

def _flatten(result):
    """One flat metric -> value map, so comparison needs no knowledge of shape."""
    flat = {}
    for cell in result.get("extraction", []) + result.get("extraction_json_object", []):
        prefix = "%s %s" % (cell["model"].replace("gpu/chat/", ""), cell.get("mode", ""))
        for k, v in cell.items():
            if k not in ("model", "mode", "n"):
                flat["%s %s" % (prefix, k)] = v
    cell = result.get("extraction_via_consumer")
    if cell:
        for k, v in cell.items():
            if k not in ("model", "mode", "n"):
                flat["via consumer gw %s" % k] = v
    for cell in result.get("concurrency", []):
        flat["conc=%s agg_tok_s" % cell["n"]] = cell.get("agg_tok_s")
    for cell in result.get("graph_load", []):
        flat["graph in_flight=%s chunks_per_min" % cell["in_flight"]] = cell.get("chunks_per_min")
        flat["graph in_flight=%s p95_lat_s" % cell["in_flight"]] = cell.get("p95_lat_s")
    for k, v in (result.get("hop_overhead_ms") or {}).items():
        flat["hop %s" % k] = v
    for k, v in (result.get("embed_rerank") or {}).items():
        flat[k] = v
    for k, v in (result.get("vllm_during_run") or {}).items():
        flat["vllm %s" % k] = v
    return flat


def compare(a, b):
    fa, fb = _flatten(a), _flatten(b)
    keys = list(fa) + [k for k in fb if k not in fa]
    width = max(len(k) for k in keys) if keys else 10
    la, lb = a.get("label", "A"), b.get("label", "B")
    print("%-*s  %14s  %14s   %s" % (width, "metric", la, lb, "change"))
    print("-" * (width + 52))
    for k in keys:
        va, vb = fa.get(k, "-"), fb.get(k, "-")
        change = ""
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)) and va and not isinstance(va, bool):
            ratio = vb / va
            # Only annotate a change worth reading; 5% is inside run-to-run noise.
            if ratio >= 1.05 or ratio <= 0.95:
                change = "%.2fx" % ratio
        elif va != vb:
            change = "changed"
        print("%-*s  %14s  %14s   %s" % (width, k, va, vb, change))


def main():
    label = os.environ.get("LABEL", "")
    cmp_a, cmp_b = os.environ.get("COMPARE_A", ""), os.environ.get("COMPARE_B", "")
    if cmp_a:
        paths = []
        for name in (cmp_a, cmp_b):
            path = name if os.path.isfile(name) else os.path.join(OUT_DIR, "%s.json" % name)
            if not os.path.isfile(path):
                print("chain-bench: no such result: %s" % path, file=sys.stderr)
                return 2
            paths.append(path)
        compare(json.load(open(paths[0])), json.load(open(paths[1])))
        return 0

    print("chain-bench: %s  (stack=%s, trials=%d)" % (label, STACK_URL, TRIALS))
    result = run(label)
    path = os.path.join(OUT_DIR, "%s.json" % label)
    with open(path, "w") as fh:
        json.dump(result, fh, indent=2)
    print("\nwrote %s" % path)
    print("compare with:  scripts/chain-bench.sh --compare <other> %s" % label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
