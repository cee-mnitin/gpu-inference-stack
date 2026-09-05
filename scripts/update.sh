#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo -e "${GREEN}Updating GPU Inference Stack${NC}"
echo "============================="
echo ""

# Load environment
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

# Determine active profiles
PROFILES="litellm,prometheus,grafana,node-exporter,dcgm-exporter"
[ "${ENABLE_OLLAMA}" = "true" ] && PROFILES="$PROFILES,ollama"
[ "${ENABLE_VLLM}" = "true" ] && PROFILES="$PROFILES,vllm"
[ "${ENABLE_EMBEDDINGS}" = "true" ] && PROFILES="$PROFILES,embeddings"

echo "Pulling latest images..."
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" pull

echo ""
echo "Recreating containers with new images..."
COMPOSE_PROFILES="$PROFILES" docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d --force-recreate

echo ""
echo -e "${GREEN}Update complete!${NC}"
echo ""
echo "Check status with: ./scripts/health-check.sh"
echo ""
