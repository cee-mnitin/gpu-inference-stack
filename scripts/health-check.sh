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

# Check Embeddings if enabled
if [ "${ENABLE_EMBEDDINGS}" = "true" ]; then
    check_endpoint "Embeddings" "http://localhost:${EMBEDDINGS_PORT:-8082}/health"
fi

# Check Redis
check_endpoint "Redis" "http://localhost:6379" 000  # Redis doesn't respond to HTTP

echo ""
echo "GPU Status:"
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "nvidia-smi not available"

echo ""
echo "Resource Usage:"
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

echo ""
