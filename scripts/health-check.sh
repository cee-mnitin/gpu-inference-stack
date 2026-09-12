#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Load environment.
#
# The PROFILE CHAIN, not .env alone. Ports, the bind address and which engines
# are enabled all live in servers/server-<name>.env — .env carries only
# SERVER_PROFILE and the secrets. Sourcing .env by itself left every one of
# those at a compose default written for a different class of box: on ddai4
# this probed LiteLLM at :8080, which platform-traefik holds, and reported
# "✗ FAILED (HTTP 404)" from that unrelated proxy while LiteLLM was healthy on
# :8090 — the very failure the LITELLM_BIND_ADDR note below describes, with the
# host half fixed and the port half missed. Prometheus and Grafana were wrong
# the same way.
#
# profile_load_vars parses rather than sources (INFINITY_CMD is a quoted
# multi-word command) and leaves anything the caller already exported alone.
# shellcheck source=lib-profile.sh
. "$SCRIPT_DIR/lib-profile.sh"
profile_load_vars

# ---------------------------------------------------------------------------
# Where is LiteLLM actually listening?
#
# `localhost` is WRONG on any box that pins LITELLM_BIND_ADDR — and pinning it
# is mandatory wherever something else already holds :8080 (the A6000 box runs
# a reverse proxy on 127.0.0.1:8080). Probing localhost there does not merely
# fail, it probes THAT service and reports its answer: an HTTP 404 from an
# unrelated proxy, indistinguishable from a broken LiteLLM.
#
# 0.0.0.0 means "all interfaces", so loopback is correct in that case.
_litellm_host="${LITELLM_BIND_ADDR:-localhost}"
case "$_litellm_host" in
    ""|0.0.0.0|"[::]"|"::") _litellm_host="localhost" ;;
esac
LITELLM_BASE="http://${_litellm_host}:${LITELLM_PORT:-8080}"

echo "GPU Inference Stack - Health Check"
echo "==================================="
echo ""

# Check if services are running
echo "Docker Services:"
docker compose -f "$PROJECT_ROOT/docker-compose.yml" ps
echo ""

# Function to check endpoint
check_endpoint() {
    local name=$1
    local url=$2
    local expected_code=${3:-200}

    echo -n "Checking $name... "

    response=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

    if [ "$response" = "$expected_code" ]; then
        echo -e "${GREEN}✓ OK (HTTP $response)${NC}"
        return 0
    else
        echo -e "${RED}✗ FAILED (HTTP $response)${NC}"
        return 1
    fi
}

# Check LiteLLM
# /health/liveliness, not /health: /health is the ADMIN endpoint — it requires
# a key and fires a real request at every configured backend on every probe.
# The compose healthcheck for this service carries the same note.
check_endpoint "LiteLLM" "${LITELLM_BASE}/health/liveliness"

# Check Prometheus
check_endpoint "Prometheus" "http://localhost:${PROMETHEUS_PORT:-9090}/-/healthy"

# Check Grafana
check_endpoint "Grafana" "http://localhost:${GRAFANA_PORT:-3000}/api/health"

# Check Ollama if enabled
if [ "${ENABLE_OLLAMA}" = "true" ]; then
    check_endpoint "Ollama" "http://localhost:${OLLAMA_PORT:-11434}/api/tags"
fi

# Check vLLM if enabled
if [ "${ENABLE_VLLM}" = "true" ]; then
    check_endpoint "vLLM" "http://localhost:${VLLM_PORT:-8000}/health"
fi

# Check llama.cpp if enabled (the alternative chat engine)
if [ "${ENABLE_LLAMACPP}" = "true" ]; then
    check_endpoint "llama.cpp" "http://localhost:${LLAMACPP_PORT:-8083}/health"

    # ------------------------------------------------------------------------
    # CONTEXT-PER-SLOT ASSERTION
    #
    # llama-server's --ctx-size is a POOL divided across --parallel slots, so
    # -c 32768 with -np 4 serves 8k per slot while gpu/chat/interactive and
    # gpu/chat/bulk promise >=32k. NOTHING else in this script catches that:
    # the container is healthy, /v1/models lists the alias, and the contract
    # call probe below sends a SHORT prompt that succeeds at any context size.
    # The failure surfaces only on real long prompts, in production, as a
    # consumer-side 400 or a silent truncation.
    #
    # There is a second route in: -fit defaults to `on` and adjusts *unset*
    # arguments to fit device memory, with --fit-ctx (default 4096) as the
    # floor it may shrink context to. docker-compose.yml pins --ctx-size
    # explicitly to immunise against that, but neither that pin nor the .env
    # can catch a later edit that breaks the CTX_SIZE/PARALLEL ratio.
    #
    # So assert the LIVE value the server is actually serving, not the config.
    # /props reports default_generation_settings.n_ctx, which is llama-server's
    # PER-SLOT figure. /slots is the fallback: it is enabled by default,
    # whereas --props gates only the POST form.
    # ------------------------------------------------------------------------
    echo -n "Checking llama.cpp context per slot... "
    _lcbase="http://localhost:${LLAMACPP_PORT:-8083}"
    _lcfloor="${LLAMACPP_CTX_PER_SLOT:-32768}"
    _perslot=$(curl -s --max-time 5 "$_lcbase/props" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get("default_generation_settings", {}).get("n_ctx")
    print(int(v) if v is not None else "")
except Exception:
    print("")
' 2>/dev/null)
    if [ -z "$_perslot" ]; then
        _perslot=$(curl -s --max-time 5 "$_lcbase/slots" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(int(d[0]["n_ctx"]) if isinstance(d, list) and d and "n_ctx" in d[0] else "")
except Exception:
    print("")
' 2>/dev/null)
    fi

    case "$_perslot" in
        ''|*[!0-9]*)
            echo -e "${YELLOW}UNKNOWN${NC}"
            echo "  Neither /props nor /slots returned an n_ctx. The server may"
            echo "  still be loading (weights take minutes off a rotational"
            echo "  disk). Re-run once 'llama.cpp' above reports OK."
            ;;
        *)
            if [ "$_perslot" -lt "$_lcfloor" ]; then
                echo -e "${RED}✗ $_perslot < $_lcfloor${NC}"
                echo -e "  ${RED}CONTRACT VIOLATION${NC} — gpu/chat/interactive and gpu/chat/bulk"
                echo "  promise >=32768 tokens of context; gpu/chat/fast promises >=16384."
                echo "  llama-server divides LLAMACPP_CTX_SIZE across LLAMACPP_PARALLEL"
                echo "  slots, so raise CTX_SIZE to PARALLEL x $_lcfloor, or lower PARALLEL."
                echo "    LLAMACPP_CTX_SIZE=${LLAMACPP_CTX_SIZE:-unset}  LLAMACPP_PARALLEL=${LLAMACPP_PARALLEL:-unset}"
                echo "  Note: the contract probe below will still PASS — its prompts are"
                echo "  short. Only real long prompts fail, which is why this check exists."
            else
                echo -e "${GREEN}✓ $_perslot >= $_lcfloor${NC}"
                # A floor check alone is not enough: something can silently
                # REDUCE per-slot context and still clear 32768. Two known
                # culprits — -fit shrinking an unset --ctx-size, and
                # --kv-unified-per-slot acting as a cap rather than a floor.
                # A 1-slot/128k deployment capped to 32k passes the floor
                # while losing 4x the context it exists to provide. So also
                # check the live value against the configured ratio.
                if [ -n "${LLAMACPP_CTX_SIZE:-}" ] && [ -n "${LLAMACPP_PARALLEL:-}" ]; then
                    _expect=$(( LLAMACPP_CTX_SIZE / LLAMACPP_PARALLEL ))
                    if [ "$_perslot" -ne "$_expect" ]; then
                        echo -e "  ${YELLOW}but expected $_expect${NC} (LLAMACPP_CTX_SIZE/LLAMACPP_PARALLEL)"
                        echo "  Something reduced the live context below what .env asks for."
                        echo "  Check the server log for 'capping per-slot context' or a fit"
                        echo "  adjustment:  docker logs llamacpp 2>&1 | grep -iE 'cap|fit|n_ctx'"
                    fi
                fi
            fi
            ;;
    esac
fi

# Check Infinity if enabled (contract embed + rerank roles)
if [ "${ENABLE_INFINITY:-true}" = "true" ]; then
    check_endpoint "Infinity" "http://localhost:${INFINITY_PORT:-7997}/health"
fi

# Check Embeddings (TEI) if enabled
if [ "${ENABLE_EMBEDDINGS}" = "true" ]; then
    check_endpoint "Embeddings (TEI)" "http://localhost:${EMBEDDINGS_PORT:-8082}/health"
fi

# Check Redis
echo -n "Checking Redis... "
if docker exec redis redis-cli ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
fi

# Check Postgres
echo -n "Checking Postgres... "
if docker exec postgres pg_isready -U litellm > /dev/null 2>&1; then
    echo -e "${GREEN}✓ OK${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
fi

# ============================================================================
# EMBER CONTRACT CHECK
# ============================================================================
# The aliases below are what consumers actually address. A backend can be
# healthy while the alias in front of it is misconfigured (wrong served-model
# name, wrong api_base, unresolved env var), so probe the NAMES, not just the
# services. This is the same check consumers run at their own boot; running it
# here means the box can prove it honours the contract before anyone points a
# consumer at it.
echo ""
echo "Ember contract aliases (what consumers address):"
_served=$(curl -s -m 10 -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    "${LITELLM_BASE}/v1/models" 2>/dev/null \
    | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')

if [ -z "$_served" ]; then
    echo -e "  ${RED}✗ could not list models — is LiteLLM up and is LITELLM_MASTER_KEY set?${NC}"
else
    # Required roles: no consumer can run its text or retrieval plane without
    # these. The "optional" roles below are optional for a BOX to publish, not
    # optional for a consumer that routes a category here — nothing falls back,
    # so a consumer pointed at an unserved role fails that category. Leaving
    # one unserved is fine; the consumer must then use a preset that routes
    # that category elsewhere (ember: `gpu_cloud_vision`).
    for _alias in gpu/chat/interactive gpu/chat/bulk gpu/chat/fast \
                  gpu/embed/bge-m3 gpu/rerank/bge-reranker-v2-m3; do
        if echo "$_served" | grep -qx "$_alias"; then
            echo -e "  ${GREEN}✓${NC} $_alias"
        else
            echo -e "  ${RED}✗ $_alias  (REQUIRED — consumers will refuse to boot)${NC}"
        fi
    done
    for _alias in gpu/chat/vision gpu/ocr/paddleocr-vl; do
        if echo "$_served" | grep -qx "$_alias"; then
            echo -e "  ${GREEN}✓${NC} $_alias ${YELLOW}(optional)${NC}"
        else
            echo -e "  ${YELLOW}-${NC} $_alias ${YELLOW}(not served — consumers must route this category elsewhere, e.g. ember preset gpu_cloud_vision)${NC}"
        fi
    done
fi


# ============================================================================
# CONTRACT CALL PROBE  —  does each alias actually SERVE, not just resolve?
# ============================================================================
# A name in /v1/models proves routing config exists. It does not prove a
# single request through it succeeds, and the gap is not theoretical: with a
# LiteLLM that lacks Pillow, gpu/chat/vision lists fine, Ollama is healthy and
# holds the model, the listing check above prints ✓ — and every real vision
# call dies with "ollama image conversion failed please run `pip install
# Pillow`". Same shape for a wrong served-model-name behind a healthy vLLM, or
# an Infinity started embed-only (400 on /rerank).
#
# So issue the smallest real request of each KIND. Skip with CONTRACT_PROBE=0.
if [ "${CONTRACT_PROBE:-1}" = "1" ] && [ -n "$_served" ]; then
    echo ""
    echo "Contract call probe (one real request per alias):"
    _base="$LITELLM_BASE"
    _auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"

    # Reports one line per alias. $1 alias, $2 endpoint path, $3 JSON body.
    # A pass is a 200 whose body carries no "error" key: LiteLLM answers some
    # upstream failures 200-with-error-body, so status alone is not enough.
    _probe_call() {
        local alias="$1" path="$2" body="$3"
        if ! echo "$_served" | grep -qx "$alias"; then
            echo -e "  ${YELLOW}-${NC} $alias ${YELLOW}(not served — skipped)${NC}"
            return 0
        fi
        printf '  probing %s ... ' "$alias"
        local out
        out=$(curl -s -m 300 -X POST "$_base$path" \
              -H "$_auth" -H 'Content-Type: application/json' -d "$body" 2>&1)
        if echo "$out" | grep -q '"error"'; then
            echo -e "${RED}✗ FAILED${NC}"
            # First line of the message is what an operator needs; the rest is
            # a Python traceback that buries it.
            echo "$out" | tr ',' '\n' | grep -m1 '"message"' | cut -c1-200 | sed 's/^/      /'
            _probe_failed=1
            return 1
        fi
        if [ -z "$out" ]; then
            echo -e "${RED}✗ FAILED (empty response / timeout)${NC}"
            _probe_failed=1
            return 1
        fi
        echo -e "${GREEN}✓${NC}"
    }

    _probe_failed=0

    # One chat probe covers interactive/bulk/fast: they are the same KIND of
    # call and often the same deployment, but each is probed because the whole
    # point of separate aliases is that they MAY differ per server.
    for _a in gpu/chat/interactive gpu/chat/bulk gpu/chat/fast; do
        _probe_call "$_a" /v1/chat/completions \
          "{\"model\":\"$_a\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":2048,\"temperature\":0}"
    done

    _probe_call gpu/embed/bge-m3 /v1/embeddings \
      '{"model":"gpu/embed/bge-m3","input":["health check"]}'

    # Rerank is probed separately because it is the asymmetric URL: LiteLLM
    # appends /v1 itself, so a base that already ends in /v1 makes this the
    # ONLY call type that breaks (404 on /v1/v1/rerank) — silently degrading a
    # consumer's retrieval to un-reranked order rather than erroring.
    _probe_call gpu/rerank/bge-reranker-v2-m3 /v1/rerank \
      '{"model":"gpu/rerank/bge-reranker-v2-m3","query":"q","documents":["a","b"],"top_n":2}'

    # A 1x1 red PNG, inline: the vision path's real failure is image DECODING
    # in the proxy, so the probe has to carry an actual image.
    _px='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=='
    _probe_call gpu/chat/vision /v1/chat/completions \
      "{\"model\":\"gpu/chat/vision\",\"max_tokens\":2048,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"describe\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,$_px\"}}]}]}"

    if [ "$_probe_failed" = "1" ]; then
        echo -e "  ${RED}One or more aliases resolve but do not serve.${NC}"
        echo -e "  ${YELLOW}Do not point a consumer at this box until they pass:${NC}"
        echo -e "  ${YELLOW}a listed-but-broken alias passes a consumer's boot check and fails at request time.${NC}"
    fi
fi

echo ""
echo "GPU Status:"
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "nvidia-smi not available"

echo ""
echo "Resource Usage:"
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

echo ""
