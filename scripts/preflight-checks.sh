#!/usr/bin/env bash
# Pre-flight checks for make start
# Auto-fixes common issues, warns on others, halts on critical failures

set -euo pipefail

# Import color codes (same pattern as Makefile)
BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
GRN=$(tput setaf 2 2>/dev/null || true)
YEL=$(tput setaf 3 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)

# Configuration from environment
STRICT=${PREFLIGHT_STRICT:-0}
NO_AUTOFIX=${PREFLIGHT_NO_AUTOFIX:-0}
AUTO=${AUTO:-0}

# Return codes: 0=pass, 1=warning, 2=critical error

# Check 1: Docker daemon responsive
check_docker_daemon() {
    if timeout 5 docker info >/dev/null 2>&1; then
        printf "  ${GRN}✓${RST} Docker daemon responsive\n"
        return 0
    else
        printf "  ${RED}✗${RST} Docker daemon not responding (timeout after 5s)\n"
        printf "    ${DIM}Is Docker running? Try: sudo systemctl start docker${RST}\n"
        return 2
    fi
}

# Check 2: Disk space >= 5GB free
check_disk_space() {
    local free_gb
    free_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')

    if [ "$free_gb" -ge 5 ]; then
        printf "  ${GRN}✓${RST} Disk space OK (${free_gb} GB free)\n"
        return 0
    else
        printf "  ${YEL}!${RST} Low disk space: ${free_gb} GB free (recommend 5GB+)\n"
        printf "    ${DIM}Suggestion: docker system prune -a${RST}\n"
        return 1
    fi
}

# Check 3: GPU available with reasonable free memory
check_gpu_availability() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf "  ${DIM}○${RST} GPU check skipped (nvidia-smi not found)\n"
        return 0
    fi

    local free_mb
    if ! free_mb=$(timeout 10 nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1); then
        printf "  ${YEL}!${RST} GPU check timed out (continuing anyway)\n"
        return 1
    fi

    if [ "$free_mb" -ge 500 ]; then
        printf "  ${GRN}✓${RST} GPU available (${free_mb} MB free)\n"
        return 0
    else
        printf "  ${YEL}!${RST} GPU memory low: ${free_mb} MB free\n"
        printf "    ${DIM}Current processes:${RST}\n"
        nvidia-smi pmon -c 1 2>/dev/null | grep -v '^#' | head -5 || true
        return 1
    fi
}

main() {
    printf "Running pre-flight checks...\n\n"

    local warnings=0
    local errors=0

    # Tier 2 - Critical
    check_docker_daemon || errors=$((errors + 1))

    # Tier 2 - Resources
    check_gpu_availability || warnings=$((warnings + 1))
    check_disk_space || warnings=$((warnings + 1))

    printf "\n"

    if [ "$errors" -gt 0 ]; then
        printf "  ${RED}✗${RST} Pre-flight checks failed\n"
        return 2
    elif [ "$warnings" -gt 0 ] && [ "$STRICT" = "1" ]; then
        printf "  ${YEL}!${RST} Pre-flight checks completed with warnings (PREFLIGHT_STRICT=1)\n"
        return 1
    else
        printf "  ${GRN}✓${RST} All checks passed\n\n"
        return 0
    fi
}

main "$@"
