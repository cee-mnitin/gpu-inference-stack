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

# Infinity serves the contract's embed + rerank roles. Defaults ON: a stack
# with no embedder cannot serve a consumer's retrieval plane at all.
if [ "${ENABLE_INFINITY:-true}" = "true" ]; then
    PROFILES="$PROFILES,infinity"
    echo "Enabling Infinity (embeddings + reranking)..."
fi

if [ "${ENABLE_EMBEDDINGS}" = "true" ]; then
    PROFILES="$PROFILES,embeddings"
    echo "Enabling Text Embeddings (TEI)..."
fi

echo ""
echo "Active profiles: $PROFILES"
echo ""

# Pull images.
# --ignore-buildable: litellm is built from config/litellm/Dockerfile (it needs
# Pillow for the Ollama vision path), so it has no upstream tag to pull. Under
# `set -e` a pull that trips over a locally-built image aborts the whole deploy.
echo "Pulling Docker images..."
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" \
    pull --ignore-buildable

echo ""
echo "Building local images..."
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" build

echo ""
echo -e "${GREEN}Starting services...${NC}"
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d

echo ""
echo "Waiting for services to initialize (this may take 2-5 minutes for vLLM)..."
sleep 30

# ---------------------------------------------------------------------------
# Pull the Ollama models this box is configured to serve.
#
# Nothing else does this. OLLAMA_PRELOAD_MODELS and OLLAMA_VISION_MODEL were
# documented as configuration but never acted on, so a fresh deploy published
# the gpu/chat/vision alias in front of a model Ollama did not have — LiteLLM
# resolves the alias, Ollama 404s on the pull-less model name, and the
# consumer sees a vision failure that looks like a routing bug.
# ---------------------------------------------------------------------------
if [ "${ENABLE_OLLAMA}" = "true" ]; then
    OLLAMA_MODELS_TO_PULL="${OLLAMA_PRELOAD_MODELS:-} ${OLLAMA_VISION_MODEL:-}"
    if [ -n "${OLLAMA_MODELS_TO_PULL// /}" ]; then
        echo ""
        echo "Pulling Ollama models..."
        # Wait for the API before pulling; a cold container is not up at +30s.
        for _ in $(seq 1 30); do
            docker exec ollama ollama list >/dev/null 2>&1 && break
            sleep 5
        done
        for model in $(echo "$OLLAMA_MODELS_TO_PULL" | tr -d '"' | tr ' ' '\n' | sort -u); do
            [ -z "$model" ] && continue
            if docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$model"; then
                echo -e "  ${GREEN}✓${NC} $model (already present)"
                continue
            fi
            echo "  pulling $model ..."
            if docker exec ollama ollama pull "$model"; then
                echo -e "  ${GREEN}✓${NC} $model"
            else
                echo -e "  ${RED}✗ $model failed to pull${NC} — gpu/chat/vision will not serve"
            fi
        done
    fi
fi

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
