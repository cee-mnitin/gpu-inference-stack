#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

BACKUP_DIR="$PROJECT_ROOT/backups/$(date +%Y%m%d_%H%M%S)"

echo -e "${GREEN}Backing up configuration...${NC}"
echo ""

mkdir -p "$BACKUP_DIR"

# Backup config files
cp -r "$PROJECT_ROOT/config" "$BACKUP_DIR/"
cp "$PROJECT_ROOT/.env" "$BACKUP_DIR/.env" 2>/dev/null || true
cp "$PROJECT_ROOT/docker-compose.yml" "$BACKUP_DIR/"
cp "$PROJECT_ROOT/docker-compose.override.yml" "$BACKUP_DIR/" 2>/dev/null || true

# Backup Grafana dashboards from running container
if docker ps | grep -q grafana; then
    echo "Exporting Grafana dashboards..."
    docker exec grafana grafana-cli admin export-dashboard > "$BACKUP_DIR/grafana-export.json" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}Backup created: $BACKUP_DIR${NC}"
echo ""
echo "To restore:"
echo "  cp -r $BACKUP_DIR/config/* $PROJECT_ROOT/config/"
echo "  cp $BACKUP_DIR/.env $PROJECT_ROOT/"
echo ""
