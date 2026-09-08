#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo -e "${GREEN}GPU Inference Stack - Deployment Script${NC}"
echo "========================================"
echo ""

# Check if .env exists
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo -e "${YELLOW}Warning: .env file not found!${NC}"
    echo "Creating .env from .env.example..."
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "${YELLOW}Please edit .env with your configuration and run this script again.${NC}"
    exit 1
fi

# Load environment variables
source "$PROJECT_ROOT/.env"

echo "Configuration:"
echo "  Server Name: ${SERVER_NAME:-gpu-server-1}"
echo "  Server Profile: ${SERVER_PROFILE:-default}"
echo "  GPU Devices: ${GPU_DEVICES:-0}"
echo ""

# Check Docker and NVIDIA runtime
echo "Checking prerequisites..."
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

if ! docker info | grep -q "Runtimes.*nvidia"; then
    echo -e "${YELLOW}Warning: NVIDIA Docker runtime not detected${NC}"
    echo "Make sure nvidia-docker2 is installed for GPU support"
fi

echo -e "${GREEN}✓ Docker is available${NC}"
echo ""

# Create data directories
echo "Creating data directories..."
mkdir -p "$PROJECT_ROOT/data"/{ollama/models,vllm/cache,huggingface,prometheus,grafana,postgres}
# Try to set permissions, ignore errors for directories owned by Docker
chmod -R 755 "$PROJECT_ROOT/data" 2>/dev/null || true
echo -e "${GREEN}✓ Data directories created${NC}"
echo ""

# Determine which profiles to enable
# Note: redis and postgres always run (required by LiteLLM)
PROFILES="litellm,prometheus,grafana,node-exporter,dcgm-exporter"

if [ "${ENABLE_OLLAMA}" = "true" ]; then
    PROFILES="$PROFILES,ollama"
    echo "Enabling Ollama..."
fi

if [ "${ENABLE_VLLM}" = "true" ]; then
    PROFILES="$PROFILES,vllm"
    echo "Enabling vLLM..."
fi

if [ "${ENABLE_EMBEDDINGS}" = "true" ]; then
    PROFILES="$PROFILES,embeddings"
    echo "Enabling Text Embeddings..."
fi

echo ""
echo "Active profiles: $PROFILES"
echo ""

# Pull images
echo "Pulling Docker images..."
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" pull

echo ""
echo -e "${GREEN}Starting services...${NC}"
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d

echo ""
echo "Waiting for services to initialize (this may take 2-5 minutes for vLLM)..."
sleep 30

# Check service health
echo ""
echo "Service Status:"
docker compose -f "$PROJECT_ROOT/docker-compose.yml" ps

echo ""
echo -e "${GREEN}Deployment complete!${NC}"
echo ""
echo "Access points:"
echo "  LiteLLM API: http://localhost:${LITELLM_PORT:-8080}/v1"
echo "  LiteLLM UI:  http://localhost:${LITELLM_PORT:-8080}/ui"
echo "  Grafana:     http://localhost:${GRAFANA_PORT:-3000} (admin/***)"
echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT:-9090}"

if [ "${ENABLE_OLLAMA}" = "true" ]; then
    echo "  Ollama:      http://localhost:${OLLAMA_PORT:-11434}"
fi

if [ "${ENABLE_VLLM}" = "true" ]; then
    echo "  vLLM:        http://localhost:${VLLM_PORT:-8000}"
fi

echo ""
echo "To view logs: docker compose logs -f [service-name]"
echo "To stop: docker compose down"
echo ""
