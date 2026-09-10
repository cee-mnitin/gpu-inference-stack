#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Load environment
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

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
check_endpoint "LiteLLM" "http://localhost:${LITELLM_PORT:-8080}/health"

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
    "http://localhost:${LITELLM_PORT:-8080}/v1/models" 2>/dev/null \
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
    _base="http://localhost:${LITELLM_PORT:-8080}"
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
