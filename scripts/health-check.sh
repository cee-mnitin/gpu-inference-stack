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
    # Required roles: a consumer cannot run its text or retrieval plane
    # without these. Optional roles degrade to a cloud provider instead.
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
            echo -e "  ${YELLOW}-${NC} $_alias ${YELLOW}(optional, not served — consumers route this to cloud)${NC}"
        fi
    done
fi

echo ""
echo "GPU Status:"
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "nvidia-smi not available"

echo ""
echo "Resource Usage:"
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

echo ""
