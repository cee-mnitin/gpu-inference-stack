#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo -e "${YELLOW}Stopping GPU Inference Stack...${NC}"
echo ""

# Stop all services
docker compose -f "$PROJECT_ROOT/docker-compose.yml" down

echo ""
echo -e "${GREEN}All services stopped${NC}"
echo ""
echo "To completely remove all data (including models), run:"
echo "  docker compose down -v"
echo "  rm -rf $PROJECT_ROOT/data"
echo ""
