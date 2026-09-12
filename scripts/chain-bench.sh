#!/bin/bash
#
# Layer 4: a SAVED, COMPARABLE baseline of the whole consumer-visible chain.
#
# scripts/benchmark.sh answers "does this backend honour the contract, right
# now". This answers "did anything get better or worse", by writing a JSON
# result you re-run and diff after a change. That is a different job, and it
# is the one an alias-layer edit needs: on 2026-09-12 turning thinking off for
# gpu/chat/interactive took its json_object p95 from 22.71s to 0.56s and its
# malformed-JSON rate from 8-in-20 to 0-in-20, and neither number is visible
# without a before to compare against.
#
# What it adds over benchmark.sh, and why each earned its place:
#   reasoning tokens     a hybrid-thinking model can spend 20x the output
#                        budget invisibly; total latency alone does not say so
#   malformed / null     the two ways a JSON role fails WITHOUT erroring —
#                        a corrupt reasoning->content handoff, and content:null
#                        at finish_reason:length. A consumer sees both as data
#   recall               a fixed gold set, so a "faster" config that quietly
#                        extracts less is caught rather than celebrated
#   graph load           many ~1200-token chunks, the shape ember's heaviest
#                        stage actually issues — its knee is not the knee of a
#                        short-prompt sweep
#   prefix cache delta   read from vLLM's own metrics across the run; this box
#                        reports 0% because a hybrid GDN model forces a
#                        2176-token attention block, which nothing else shows
#   hop overhead         engine vs stack gateway vs consumer gateway, so a
#                        regression is attributed to a tier
#
# Usage:
#   scripts/chain-bench.sh --label before
#   ... change something ...
#   scripts/chain-bench.sh --label after
#   scripts/chain-bench.sh --compare before after
#
#   --only extraction,concurrency,graph,embed,hops   run a subset
#   --trials N          samples per extraction cell (default 20)
#   --consumer URL      also measure through a consumer gateway (ember's)
#   --consumer-key KEY
#   --out DIR           where results land (default ./data/chain-bench)
#
# Results are JSON so a comparison is mechanical rather than eyeballed from
# two terminal scrollbacks.
#
# Stdlib-only Python, for the reason benchmark.sh gives: this box's system
# Python is PEP 668 externally-managed and lacks ensurepip.

set -uo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# The PROFILE CHAIN, not .env alone — ports and the bind address live in
# servers/server-<name>.env. Sourcing .env by itself is what had health-check
# probing :8080 (see 2026-09-12-health-check-reads-the-profile.md).
# shellcheck source=lib-profile.sh
. "$SCRIPT_DIR/lib-profile.sh"
profile_load_vars

LABEL=""; COMPARE_A=""; COMPARE_B=""; ONLY="extraction,concurrency,graph,embed,hops"
TRIALS=20; OUT_DIR="$PROJECT_ROOT/data/chain-bench"
CONSUMER_URL="${CONSUMER_URL:-}"; CONSUMER_KEY="${CONSUMER_KEY:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --label)        LABEL="$2"; shift 2 ;;
        --compare)      COMPARE_A="$2"; COMPARE_B="$3"; shift 3 ;;
        --only)         ONLY="$2"; shift 2 ;;
        --trials)       TRIALS="$2"; shift 2 ;;
        --consumer)     CONSUMER_URL="$2"; shift 2 ;;
        --consumer-key) CONSUMER_KEY="$2"; shift 2 ;;
        --out)          OUT_DIR="$2"; shift 2 ;;
        -h|--help)      sed -n '3,46p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$LABEL" ] && [ -z "$COMPARE_A" ]; then
    echo "chain-bench: pass --label <name> to record a run, or --compare <a> <b>" >&2
    exit 2
fi

_host="${LITELLM_BIND_ADDR:-localhost}"
case "$_host" in ""|0.0.0.0|"[::]"|"::") _host="localhost" ;; esac
STACK_URL="http://${_host}:${LITELLM_PORT:-8080}"
STACK_KEY="${LITELLM_MASTER_KEY:-}"
# vLLM's own metrics, for the prefix-cache and preemption deltas. Bound to
# localhost on most profiles, so this is a best-effort read: absent, the run
# simply omits that section rather than failing.
VLLM_METRICS="http://localhost:${VLLM_PORT:-8000}/metrics"

mkdir -p "$OUT_DIR"

STACK_URL="$STACK_URL" STACK_KEY="$STACK_KEY" VLLM_METRICS="$VLLM_METRICS" \
LABEL="$LABEL" COMPARE_A="$COMPARE_A" COMPARE_B="$COMPARE_B" ONLY="$ONLY" \
TRIALS="$TRIALS" OUT_DIR="$OUT_DIR" \
CONSUMER_URL="$CONSUMER_URL" CONSUMER_KEY="$CONSUMER_KEY" \
python3 "$SCRIPT_DIR/chain_bench.py"
