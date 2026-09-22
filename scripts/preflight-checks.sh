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

# Helper: Get compose project name
get_compose_project() {
    basename "$(pwd)"
}

# Helper: Get ports needed by active profile
get_required_ports() {
    # Source profile files to get port configuration
    local ports=""

    # Always check LiteLLM and base services
    ports="${LITELLM_PORT:-8080} ${REDIS_PORT:-6379} ${PROMETHEUS_PORT:-9090} ${GRAFANA_PORT:-3000}"

    # Check enabled services from environment
    [ "${ENABLE_VLLM:-false}" = "true" ] && ports="$ports ${VLLM_PORT:-8000}"
    [ "${ENABLE_VLLM2:-false}" = "true" ] && ports="$ports ${VLLM2_PORT:-8010}"
    [ "${ENABLE_VLLM3:-false}" = "true" ] && ports="$ports ${VLLM3_PORT:-8011}"
    [ "${ENABLE_OLLAMA:-false}" = "true" ] && ports="$ports ${OLLAMA_PORT:-11434}"
    [ "${ENABLE_LLAMACPP:-false}" = "true" ] && ports="$ports ${LLAMACPP_PORT:-8083}"
    [ "${ENABLE_INFINITY:-false}" = "true" ] && ports="$ports ${INFINITY_PORT:-7997}"
    [ "${ENABLE_EMBEDDINGS:-false}" = "true" ] && ports="$ports ${EMBEDDINGS_PORT:-8082}"

    echo "$ports" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

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

# Check 4: Container name conflicts (AUTO-FIX)
check_container_conflicts() {
    local project
    project=$(get_compose_project)

    # Get container names we care about from docker-compose.yml
    local our_containers
    our_containers="ollama|vllm-new|vllm2|vllm3|vllm-router-new|litellm|redis|postgres|prometheus|grafana|node-exporter|dcgm-exporter|redis-exporter|llamacpp|embeddings|infinity|nginx"

    # Find containers matching our names that aren't part of our compose project
    local conflicts
    conflicts=$(docker ps -a --format '{{.Names}}\t{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.CreatedAt}}' \
        | grep -E "^($our_containers)\s" \
        | grep -v "$project" \
        | awk '{print $1 "\t" $2 "\t" $4 " " $5 " " $6}' || true)

    if [ -z "$conflicts" ]; then
        printf "  ${GRN}✓${RST} No container name conflicts\n"
        return 0
    fi

    # Auto-fix: remove conflicting containers
    local fixed=0
    while IFS=$'\t' read -r name id created; do
        printf "  ${YEL}⚠${RST} Container name conflict: ${name} (${id:0:8}, created ${created})\n"

        if [ "$NO_AUTOFIX" = "1" ]; then
            printf "    ${DIM}Would remove (PREFLIGHT_NO_AUTOFIX=1): docker rm -f ${name}${RST}\n"
        else
            printf "  ${DIM}→${RST} Removing conflicting container... "
            if docker rm -f "$name" >/dev/null 2>&1; then
                printf "done\n"
                fixed=$((fixed + 1))
            else
                printf "failed\n"
                return 2
            fi
        fi
    done <<< "$conflicts"

    if [ "$NO_AUTOFIX" = "1" ]; then
        return 2
    fi

    return 0
}

# Check 5: Port conflicts (CONDITIONAL AUTO-FIX)
check_port_conflicts() {
    # Source profile to get ENABLE_* flags
    set -a
    for f in $(./scripts/profile-files.sh 2>/dev/null); do
        [ -f "$f" ] && . "$f"
    done
    set +a

    local ports
    ports=$(get_required_ports)

    local conflicts=0
    local checked=0

    for port in $ports; do
        [ -z "$port" ] && continue
        checked=$((checked + 1))

        # Use ss (preferred) or fall back to lsof
        local listening
        if command -v ss >/dev/null 2>&1; then
            listening=$(ss -tlnp 2>/dev/null | grep ":$port " | head -1 || true)
        elif command -v lsof >/dev/null 2>&1; then
            listening=$(lsof -i ":$port" -sTCP:LISTEN 2>/dev/null | grep -v PID | head -1 || true)
        else
            printf "  ${YEL}!${RST} Port check skipped (neither ss nor lsof available)\n"
            return 1
        fi

        if [ -z "$listening" ]; then
            continue
        fi

        # Port is in use - check if it's our old container
        local container_using
        container_using=$(docker ps --format '{{.Names}}' --filter "publish=$port" 2>/dev/null | head -1 || true)

        if [ -n "$container_using" ]; then
            # Our container is using it
            printf "  ${YEL}⚠${RST} Port conflict: $port in use by $container_using (old container)\n"

            if [ "$NO_AUTOFIX" = "1" ]; then
                printf "    ${DIM}Would stop (PREFLIGHT_NO_AUTOFIX=1): docker stop $container_using${RST}\n"
                conflicts=$((conflicts + 1))
            else
                printf "  ${DIM}→${RST} Stopping old container... "
                if docker stop "$container_using" >/dev/null 2>&1; then
                    printf "done\n"
                else
                    printf "failed\n"
                    conflicts=$((conflicts + 1))
                fi
            fi
        else
            # External process
            printf "  ${RED}✗${RST} Port conflict: $port in use by external process\n"
            printf "    ${DIM}Check with: sudo lsof -i :$port${RST}\n"
            printf "    ${DIM}Or change port in .env (e.g., LITELLM_PORT=$((port+1)))${RST}\n"
            conflicts=$((conflicts + 1))
        fi
    done

    if [ "$checked" -eq 0 ]; then
        printf "  ${DIM}○${RST} Port check skipped (no ports configured)\n"
        return 0
    fi

    if [ "$conflicts" -gt 0 ]; then
        return 2
    fi

    printf "  ${GRN}✓${RST} Ports available ($checked checked)\n"
    return 0
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

    # Tier 1 - Conflicts (auto-fix)
    check_container_conflicts || errors=$((errors + 1))
    check_port_conflicts || errors=$((errors + 1))

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
