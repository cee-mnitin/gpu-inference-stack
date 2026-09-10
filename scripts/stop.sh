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
# shellcheck source=lib-profile.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-profile.sh"
# Same layering as deploy.sh. Without it compose resolves different port
# mappings than the ones the stack was started with, and `down` can miss
# containers on a box whose profile shifts ports.
# shellcheck disable=SC2046
docker compose $(profile_env_file_args) -f "$PROJECT_ROOT/docker-compose.yml" down

echo ""
echo -e "${GREEN}All services stopped${NC}"
echo ""
echo "To completely remove all data (including models), run:"
echo "  docker compose down -v"
echo "  rm -rf $PROJECT_ROOT/data"
echo ""
