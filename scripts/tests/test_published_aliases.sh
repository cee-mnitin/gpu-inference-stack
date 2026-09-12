#!/usr/bin/env bash
# Tests that NO alias is published unconditionally — every name in
# config/litellm/config.yaml must be switchable off by the box that cannot
# serve it.
#
# WHY THIS EXISTS. On 2026-09-12 an audit probed all nineteen aliases ddai4
# published and found THIRTEEN returned HTTP 500 or 404: the five `qwen3.6-*`
# vLLM entries named `openai/qwen3.6` while this box's engine serves
# `qwen3.6-35b-a3b`, the six Ollama entries pointed at an Ollama the profile
# disables, and the two `*-native` embed/rerank entries pointed at a TEI pair
# that only exists on server-85.
#
# config.yaml already argues, at length, that a published-but-dead alias is
# strictly WORSE than an absent one — a consumer routes AROUND a missing role
# but breaks on a dead one, having no way to tell "unserved" from "serving
# badly". It made that argument only about the six contract aliases and left
# thirteen others hardcoded.
#
# These aliases are NOT dead weight to be deleted: server-85.env pins
# VLLM_PORT, OLLAMA_PORT and VLLM_MODEL_NAME specifically to keep them
# resolving ("260 of the last 290 gateway requests were openai/qwen3.6"). So
# the fix is the same one the contract roles already use — an env-driven name
# with a historical default — and this test is what stops the next alias from
# being added hardcoded.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG="$REPO_ROOT/config/litellm/config.yaml"
COMPOSE="$REPO_ROOT/docker-compose.yml"

pass=0; fail=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31m✗\033[0m %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

echo ""
echo "config/litellm/config.yaml — every published alias is switchable"
echo ""

# ── 1. No hardcoded model_name, except the three REQUIRED roles ────────────
# `model_name:` is the CONSUMER-FACING name. A literal one cannot be turned
# off, which is the whole defect. Every entry must read its name from the
# environment so a profile can move it to the unserved/ namespace.
#
# gpu/chat/{interactive,bulk,fast} are exempt, and stay literal. They are
# `required: yes` in the contract — a box that cannot serve them is not a GPU
# stack, and consumers REFUSE TO BOOT when they are missing rather than
# routing around them. Making them switchable would offer an operator a way to
# publish a stack that no consumer can use, which is not a state worth
# reaching. The optional roles (vision, embed, rerank) are already env-driven.
hardcoded="$(grep -nE '^\s*-?\s*model_name:\s*' "$CONFIG" \
             | grep -v 'os\.environ/' \
             | grep -vE 'model_name:\s*gpu/chat/(interactive|bulk|fast)\s*$' \
             | sed 's/^\([0-9]*\):.*model_name:[[:space:]]*/    line \1: /' || true)"
if [ -z "$hardcoded" ]; then
    ok "every model_name: is env-driven (os.environ/...)"
else
    bad "these aliases are published unconditionally and cannot be disabled:" \
        "$(printf '%s' "$hardcoded")"
fi

# ── 2. No hardcoded served-model name on a vLLM-backed entry ───────────────
# `openai/qwen3.6` was correct on server-85 and wrong on every Blackwell box,
# where VLLM_MODEL_NAME is qwen3.6-35b-a3b. The served name belongs to the
# profile, never to this file.
stale_model="$(grep -nE '^\s*model:\s*openai/qwen3\.6' "$CONFIG" \
               | sed 's/^\([0-9]*\):.*/    line \1/' || true)"
if [ -z "$stale_model" ]; then
    ok "no entry hardcodes the served model name 'openai/qwen3.6'"
else
    bad "served model name hardcoded — breaks on any box whose VLLM_MODEL_NAME differs:" \
        "$(printf '%s' "$stale_model")"
fi

# ── 3. Every variable the config reads is forwarded by compose ─────────────
# scripts/check-contract-wiring.sh proves this against the RENDERED compose and
# is the authority; this is the same assertion done statically, so the suite
# catches an unforwarded variable with no docker and no running stack.
referenced="$(grep -oE 'os\.environ/[A-Za-z_][A-Za-z0-9_]*' "$CONFIG" \
              | sed 's|os\.environ/||' | sort -u)"
unforwarded=""
for name in $referenced; do
    grep -qE "^\s*-\s*${name}=" "$COMPOSE" || unforwarded="$unforwarded $name"
done
if [ -z "$unforwarded" ]; then
    n="$(printf '%s\n' "$referenced" | grep -c . || true)"
    ok "all $n os.environ/ name(s) are passed to the litellm service"
else
    bad "config.yaml reads variables docker-compose.yml never passes:" \
        "$(printf '   %s\n' $unforwarded)"
fi

# ── 4. Every forwarded alias variable has a non-empty default ──────────────
# A `${VAR}` with no `:-default` renders empty, and LiteLLM publishes an alias
# with an EMPTY name — which is the published-but-broken failure in its purest
# form. Historical defaults are also what keeps server-85 unchanged by this.
nodefault="$(grep -oE '^\s*-\s*(LEGACY|CONTRACT)_[A-Z0-9_]*=\$\{[A-Z0-9_]*\}' "$COMPOSE" \
             | sed 's/^\s*-\s*/    /' || true)"
if [ -z "$nodefault" ]; then
    ok "every CONTRACT_*/LEGACY_* variable has a default value"
else
    bad "these render empty when the profile does not set them:" \
        "$(printf '%s' "$nodefault")"
fi

# ── 5. A profile that disables a backend must unserve its aliases ──────────
# The Blackwell 32 GB profile sets ENABLE_OLLAMA=false and runs no native
# Ollama or TEI, so the ten aliases behind those services must be moved out of
# the consumable namespace there. This is the assertion that actually failed on
# ddai4 before the fix.
PROFILE="$REPO_ROOT/servers/common-blackwell-32gb.env"
missing_unserved=""
for v in LEGACY_OLLAMA_QWEN25_7B_DOCKER_ALIAS LEGACY_OLLAMA_GEMMA3_12B_DOCKER_ALIAS \
         LEGACY_OLLAMA_QWEN25_7B_NATIVE_ALIAS LEGACY_OLLAMA_QWEN36_NATIVE_ALIAS \
         LEGACY_OLLAMA_GEMMA3_12B_NATIVE_ALIAS LEGACY_OLLAMA_GRANITE33_8B_NATIVE_ALIAS \
         LEGACY_VLLM_ROUTER_HOST_ALIAS LEGACY_VLLM_DIRECT_HOST_ALIAS \
         LEGACY_EMBED_NATIVE_ALIAS LEGACY_RERANK_NATIVE_ALIAS; do
    grep -qE "^${v}=unserved/" "$PROFILE" || missing_unserved="$missing_unserved $v"
done
if [ -z "$missing_unserved" ]; then
    ok "blackwell-32gb unserves the ten aliases it has no backend for"
else
    bad "blackwell-32gb publishes aliases it cannot serve:" \
        "$(printf '   %s\n' $missing_unserved)"
fi

# ── 6. The router flag and the router alias must agree ─────────────────────
# vllm-router is an nginx hop that model-routes across up to three vLLM
# instances. On a one-instance box it routes 1->1 and buys nothing, so a
# profile may turn it off — but LEGACY_VLLM_ROUTER_ALIAS points THROUGH it, so
# turning it off while still publishing that alias recreates the very defect
# this file exists to prevent, one layer down.
for prof in "$REPO_ROOT"/servers/*.env; do
    grep -qE '^ENABLE_VLLM_ROUTER=false' "$prof" || continue
    name="$(basename "$prof")"
    if grep -qE '^LEGACY_VLLM_ROUTER_ALIAS=unserved/' "$prof"; then
        ok "$name: router off, and its alias is unserved"
    else
        bad "$name: ENABLE_VLLM_ROUTER=false but LEGACY_VLLM_ROUTER_ALIAS is still consumable" \
            "    add: LEGACY_VLLM_ROUTER_ALIAS=unserved/qwen3.6-new-router"
    fi
done

echo ""
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
