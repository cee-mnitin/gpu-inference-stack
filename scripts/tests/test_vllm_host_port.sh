#!/usr/bin/env bash
# vLLM's host port must not default to 8000.
#
# WHY THIS EXISTS. 8000 is deepdarshak-backend's API host port (API_EXT_PORT)
# on every deepdarshak host, and this stack runs on those same boxes. With
# VLLM_PORT defaulting to 8000, whichever stack started second failed to bind;
# vllm-new is `restart: unless-stopped`, so after a reboot the API usually
# lost (ddai3, 2026-09-28). The CONTAINER port stays 8000 — only the host
# mapping moves. Spec: docs/superpowers/specs/2026-09-28-vllm-host-port-off-8000.md
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT=8100
# Host ports the deepdarshak workspace defaults to on the same boxes.
RESERVED="8000"

pass=0; fail=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "vLLM host port"

got="$(grep -oE '\$\{VLLM_PORT:-[0-9]+\}:8000' "$REPO_ROOT/docker-compose.yml")"
is "compose publishes \${VLLM_PORT:-$DEFAULT}:8000" "\${VLLM_PORT:-$DEFAULT}:8000" "$got"

got="$(grep -rnoE '\$\{VLLM_PORT:-[0-9]+\}' "$REPO_ROOT/scripts" "$REPO_ROOT/Makefile" \
        --exclude-dir=tests | grep -v ":-$DEFAULT}" || true)"
is "every script/Makefile fallback is $DEFAULT" "" "$got"

got=""
for f in "$REPO_ROOT"/servers/*.env; do
    v="$(sed -nE 's/^VLLM_PORT=([0-9]+).*/\1/p' "$f")"
    for r in $RESERVED; do
        [ "$v" = "$r" ] && got="$got $(basename "$f")=$v"
    done
done
is "no profile pins a workspace-reserved port ($RESERVED)" "" "${got# }"

got="$(sed -nE 's/^#? *VLLM_PORT=([0-9]+).*/\1/p' "$REPO_ROOT/.env.example")"
is ".env.example documents $DEFAULT" "$DEFAULT" "$got"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
