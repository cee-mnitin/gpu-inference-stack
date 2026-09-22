# Pre-flight Checks System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add comprehensive pre-flight checks to `make start` that auto-fix common issues (container conflicts, port conflicts) and warn about resource constraints before docker compose up runs.

**Architecture:** Bash script called from Makefile that runs 9 checks (3 tiers), auto-fixes where safe, warns where not, halts only on critical unfixable errors. Uses existing Makefile color codes for consistent UX.

**Tech Stack:** Bash, Docker CLI, nvidia-smi, ss/lsof, existing Makefile infrastructure

---

## Task 1: Create Script Foundation

**Files:**
- Create: `scripts/preflight-checks.sh`

**Step 1: Create script structure with color codes and main function**

```bash
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
main() {
    printf "Running pre-flight checks...\n\n"

    local warnings=0
    local errors=0

    # Placeholder for checks
    printf "  ${GRN}✓${RST} Checks not yet implemented\n"

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
```

**Step 2: Make script executable**

Run: `chmod +x scripts/preflight-checks.sh`

**Step 3: Test script runs**

Run: `./scripts/preflight-checks.sh`
Expected: Output shows "Running pre-flight checks..." and "✓ All checks passed"

**Step 4: Commit foundation**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add script foundation with color codes

- Main function structure with error/warning tracking
- Color code imports matching Makefile style
- Configuration from environment variables
- Return codes: 0=pass, 1=warning, 2=critical"
```

---

## Task 2: Implement Docker Daemon Check (Tier 2)

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add check_docker_daemon function**

Add before `main()`:

```bash
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
```

**Step 2: Call check from main**

In `main()`, replace the placeholder with:

```bash
    # Tier 2 - Critical
    check_docker_daemon || ((errors++))
```

**Step 3: Test with Docker running**

Run: `./scripts/preflight-checks.sh`
Expected: "✓ Docker daemon responsive"

**Step 4: Test with Docker stopped (optional manual test)**

If you want to verify the error path:
```bash
sudo systemctl stop docker
./scripts/preflight-checks.sh
sudo systemctl start docker
```
Expected: "✗ Docker daemon not responding"

**Step 5: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add Docker daemon responsiveness check

- Timeout after 5s if daemon doesn't respond
- Returns critical error (2) to halt startup
- Suggests systemctl command to fix"
```

---

## Task 3: Implement Disk Space Check (Tier 1)

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add check_disk_space function**

```bash
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
```

**Step 2: Call check from main**

Add after docker daemon check:

```bash
    check_disk_space || ((warnings++))
```

**Step 3: Test**

Run: `./scripts/preflight-checks.sh`
Expected: "✓ Disk space OK (XX GB free)" or warning if <5GB

**Step 4: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add disk space check

- Warns if <5GB free in current directory
- Returns warning (1) - doesn't halt startup
- Suggests docker system prune for cleanup"
```

---

## Task 4: Implement GPU Availability Check (Tier 2)

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add check_gpu_availability function**

```bash
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
```

**Step 2: Call check from main**

Add after disk space check:

```bash
    check_gpu_availability || ((warnings++))
```

**Step 3: Test**

Run: `./scripts/preflight-checks.sh`
Expected: "✓ GPU available (XXXX MB free)" or warning if <500MB

**Step 4: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add GPU availability check

- Checks free GPU memory using nvidia-smi
- Warns if <500MB free, shows processes with pmon
- Skips gracefully if nvidia-smi not available
- 10s timeout to avoid hanging on GPU issues"
```

---

## Task 5: Implement Container Conflict Check (Tier 1 - AUTO-FIX)

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add helper to get compose project name**

```bash
# Helper: Get compose project name
get_compose_project() {
    basename "$(pwd)"
}
```

**Step 2: Add check_container_conflicts function**

```bash
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
                ((fixed++))
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
```

**Step 3: Call check from main**

Add after GPU check:

```bash
    check_container_conflicts || ((errors++))
```

**Step 4: Test with no conflicts**

Run: `./scripts/preflight-checks.sh`
Expected: "✓ No container name conflicts"

**Step 5: Test with conflict (create one)**

```bash
docker run -d --name ollama alpine sleep 3600
./scripts/preflight-checks.sh
docker ps -a --filter "name=ollama"
```
Expected: "⚠ Container name conflict" followed by "→ Removing conflicting container... done"
Container should be gone after check runs.

**Step 6: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add container conflict check with auto-fix

- Detects containers with our service names not owned by project
- Auto-removes conflicting containers
- Shows container ID and creation time for transparency
- Respects PREFLIGHT_NO_AUTOFIX flag for dry-run mode"
```

---

## Task 6: Implement Port Conflict Check (Tier 1 - CONDITIONAL AUTO-FIX)

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add helper to get required ports**

```bash
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
```

**Step 2: Add check_port_conflicts function**

```bash
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
        ((checked++))

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
                ((conflicts++))
            else
                printf "  ${DIM}→${RST} Stopping old container... "
                if docker stop "$container_using" >/dev/null 2>&1; then
                    printf "done\n"
                else
                    printf "failed\n"
                    ((conflicts++))
                fi
            fi
        else
            # External process
            printf "  ${RED}✗${RST} Port conflict: $port in use by external process\n"
            printf "    ${DIM}Check with: sudo lsof -i :$port${RST}\n"
            printf "    ${DIM}Or change port in .env (e.g., LITELLM_PORT=$((port+1)))${RST}\n"
            ((conflicts++))
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
```

**Step 3: Call check from main**

Add after container conflicts:

```bash
    check_port_conflicts || ((errors++))
```

**Step 4: Test with no conflicts**

Run: `./scripts/preflight-checks.sh`
Expected: "✓ Ports available (X checked)"

**Step 5: Test with Docker container conflict**

```bash
docker run -d -p 8080:80 --name test-nginx nginx:alpine
./scripts/preflight-checks.sh
docker ps --filter "name=test-nginx"
```
Expected: "⚠ Port conflict: 8080 in use by test-nginx" and container stopped

**Step 6: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add port conflict check with conditional auto-fix

- Checks all ports needed by active profile
- Auto-stops if conflict is our own old container
- Errors with remediation if external process
- Uses ss (preferred) or falls back to lsof
- Sources profile files to get ENABLE_* flags"
```

---

## Task 7: Implement Remaining Tier 2/3 Checks

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add Docker Compose version check**

```bash
# Check 6: Docker Compose version
check_compose_version() {
    if ! command -v docker >/dev/null 2>&1; then
        printf "  ${RED}✗${RST} docker command not found\n"
        return 2
    fi

    local version
    if ! version=$(docker compose version --short 2>/dev/null); then
        printf "  ${YEL}!${RST} Could not determine Docker Compose version\n"
        return 1
    fi

    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)

    if [ "$major" -ge 2 ]; then
        printf "  ${GRN}✓${RST} Docker Compose ${version}\n"
        return 0
    else
        printf "  ${YEL}!${RST} Docker Compose ${version} is old (recommend 2.0+)\n"
        printf "    ${DIM}Install: https://docs.docker.com/compose/install/${RST}\n"
        return 1
    fi
}
```

**Step 2: Add volume paths check**

```bash
# Check 7: Volume mount paths exist (AUTO-CREATE)
check_volume_paths() {
    # Source profile to get volume path variables
    set -a
    for f in $(./scripts/profile-files.sh 2>/dev/null); do
        [ -f "$f" ] && . "$f"
    done
    set +a

    local paths=(
        "${VLLM_CACHE_DIR:-./data/vllm/cache}"
        "${HF_HOME:-./data/huggingface}"
        "${OLLAMA_MODELS_DIR:-./data/ollama/models}"
        "${LLAMACPP_MODELS_DIR:-./data/llamacpp/models}"
        "./data/postgres"
        "./config/litellm"
        "./config/prometheus"
        "./config/grafana/provisioning"
        "./config/grafana/dashboards"
    )

    local created=0

    for path in "${paths[@]}"; do
        if [ ! -d "$path" ]; then
            if [ "$NO_AUTOFIX" = "1" ]; then
                printf "  ${YEL}⚠${RST} Missing directory: $path\n"
                printf "    ${DIM}Would create (PREFLIGHT_NO_AUTOFIX=1)${RST}\n"
            else
                mkdir -p "$path"
                printf "  ${DIM}→${RST} Created directory: $path\n"
                ((created++))
            fi
        fi
    done

    if [ "$created" -eq 0 ] && [ "$NO_AUTOFIX" != "1" ]; then
        printf "  ${GRN}✓${RST} Volume paths exist\n"
    fi

    return 0
}
```

**Step 3: Add network conflicts check**

```bash
# Check 8: Network conflicts (AUTO-FIX)
check_network_conflicts() {
    local network_name="${NETWORK_NAME:-gpu-inference-net}"

    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        printf "  ${GRN}✓${RST} Network will be created\n"
        return 0
    fi

    # Check if any running containers are using it
    local containers_using
    containers_using=$(docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)

    if [ -z "$containers_using" ]; then
        # Network exists but unused - remove it so compose can recreate with correct settings
        printf "  ${YEL}⚠${RST} Stale network found: $network_name\n"

        if [ "$NO_AUTOFIX" = "1" ]; then
            printf "    ${DIM}Would remove (PREFLIGHT_NO_AUTOFIX=1): docker network rm $network_name${RST}\n"
        else
            printf "  ${DIM}→${RST} Removing stale network... "
            if docker network rm "$network_name" >/dev/null 2>&1; then
                printf "done\n"
            else
                printf "failed\n"
                return 1
            fi
        fi
    else
        printf "  ${GRN}✓${RST} Network exists (used by: ${containers_using})\n"
    fi

    return 0
}
```

**Step 4: Add images check (info only)**

```bash
# Check 9: Required images available (INFO ONLY)
check_images_available() {
    # This is informational - compose will pull missing images
    # Just note if large images need pulling

    local images=(
        "${VLLM_IMAGE:-vllm/vllm-openai:v0.23.0}"
        "ghcr.io/berriai/litellm:main-latest"
    )

    local missing=()

    for image in "${images[@]}"; do
        if ! docker images -q "$image" 2>/dev/null | grep -q .; then
            missing+=("$image")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf "  ${DIM}ℹ${RST} Will pull missing images:\n"
        for img in "${missing[@]}"; do
            printf "    ${DIM}$img${RST}\n"
        done
    fi

    return 0
}
```

**Step 5: Call all new checks from main**

Update the checks section in `main()`:

```bash
    # Tier 2 - Critical
    check_docker_daemon || ((errors++))
    check_compose_version || ((warnings++))

    # Tier 2 - Resources
    check_gpu_availability || ((warnings++))
    check_disk_space || ((warnings++))

    # Tier 1 - Conflicts (auto-fix)
    check_container_conflicts || ((errors++))
    check_port_conflicts || ((errors++))

    # Tier 3 - Nice to have
    check_volume_paths || ((warnings++))
    check_network_conflicts || ((warnings++))
    check_images_available || true  # Info only
```

**Step 6: Test all checks**

Run: `./scripts/preflight-checks.sh`
Expected: All checks pass or show appropriate warnings

**Step 7: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add remaining Tier 2/3 checks

- Docker Compose version check (warns if <2.0)
- Volume paths check (auto-creates missing dirs)
- Network conflicts check (removes stale networks)
- Images check (info only, shows what will be pulled)
- All checks integrated in logical order"
```

---

## Task 8: Integrate with Makefile

**Files:**
- Modify: `Makefile`

**Step 1: Add preflight check call to start target**

Find the `start:` target (around line 192) and add the preflight call:

```makefile
start: _require_profile
	@printf "$(BOLD)Starting$(RST) $(DIM)profile $(PROFILE_NAME)$(RST)\n"
	@# Run pre-flight checks (auto-fixes where possible)
	@if [ "$(SKIP_PREFLIGHT)" != "1" ]; then \
	  ./scripts/preflight-checks.sh || exit 1; \
	fi
	@# Check for .env overrides that shadow profile settings. This catches the
```

**Step 2: Update help text**

Find the `help:` target and add environment variable documentation:

```makefile
	@printf "  $(DIM)Environment variables:$(RST)\n"
	@printf "  $(DIM)  AUTO=1                take the default answer to every prompt$(RST)\n"
	@printf "  $(DIM)  SKIP_PREFLIGHT=1      skip pre-flight checks before start$(RST)\n"
	@printf "  $(DIM)  PREFLIGHT_STRICT=1    treat warnings as errors$(RST)\n"
	@printf "  $(DIM)  PREFLIGHT_NO_AUTOFIX=1 show fixes but don't apply them$(RST)\n"
	@printf "  $(DIM)  REBUILD=1             rebuild, reusing the Docker layer cache$(RST)\n"
```

**Step 3: Test integration**

Run: `make start`
Expected: Pre-flight checks run before docker compose up

**Step 4: Test SKIP_PREFLIGHT flag**

Run: `SKIP_PREFLIGHT=1 make start`
Expected: Pre-flight checks skipped, goes straight to docker compose

**Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(preflight): integrate checks into make start

- Calls preflight-checks.sh before docker compose up
- Respects SKIP_PREFLIGHT=1 to bypass checks
- Updates help text with new environment variables
- Halts on critical errors, continues on warnings"
```

---

## Task 9: Add Error Box for Critical Failures

**Files:**
- Modify: `scripts/preflight-checks.sh`

**Step 1: Add show_error_box helper function**

Add near the top after configuration variables:

```bash
# Helper: Show error box for critical failures
show_error_box() {
    local title="$1"
    local message="$2"
    local remediation="$3"

    local width=61
    local border_top="┌─────────────────────────────────────────────────────────┐"
    local border_mid="├─────────────────────────────────────────────────────────┤"
    local border_bot="└─────────────────────────────────────────────────────────┘"

    printf "\n%s\n" "$border_top"
    printf "│ ${RED}✗${RST} %-53s │\n" "$title"
    printf "%s\n" "$border_mid"
    printf "│ %-57s │\n" ""

    # Print message lines
    while IFS= read -r line; do
        printf "│ %-57s │\n" "$line"
    done <<< "$message"

    printf "│ %-57s │\n" ""

    if [ -n "$remediation" ]; then
        printf "│ ${BOLD}To fix:${RST}%-49s │\n" ""
        while IFS= read -r line; do
            printf "│   %-55s │\n" "$line"
        done <<< "$remediation"
        printf "│ %-57s │\n" ""
    fi

    printf "%s\n\n" "$border_bot"
}
```

**Step 2: Update check_port_conflicts to use error box**

Replace the external process error section:

```bash
        else
            # External process - show error box
            local process_info
            if command -v lsof >/dev/null 2>&1; then
                process_info=$(sudo lsof -i ":$port" 2>/dev/null | grep LISTEN | awk '{print $1 " (PID " $2 ")"}' | head -1)
            else
                process_info="Unknown process"
            fi

            show_error_box \
                "Pre-flight check failed: Port conflict" \
                "Port $port is already in use by:
  $process_info" \
                "1. Stop the conflicting process:
   sudo kill <PID>

2. Or change the port in .env:
   LITELLM_PORT=$((port+1))

3. Or force start anyway (not recommended):
   SKIP_PREFLIGHT=1 make start"

            ((conflicts++))
        fi
```

**Step 3: Test error box**

```bash
# Start something on port 8080 that's not Docker
python3 -m http.server 8080 &
./scripts/preflight-checks.sh
kill %1
```

Expected: Nice error box with remediation steps

**Step 4: Commit**

```bash
git add scripts/preflight-checks.sh
git commit -m "feat(preflight): add error box for critical failures

- Unicode box drawing for clear visual separation
- Shows title, message, and remediation steps
- Used for port conflicts with external processes
- Matches width of 61 chars for readability"
```

---

## Task 10: End-to-End Testing & Documentation

**Files:**
- Create: `docs/preflight-checks.md`

**Step 1: Create user documentation**

```markdown
# Pre-flight Checks

The `make start` command runs comprehensive pre-flight checks before starting containers.

## What Gets Checked

### Tier 1 - Critical (auto-fix where possible)
- **Container name conflicts** - Removes old containers blocking startup
- **Port conflicts** - Stops our old containers, errors on external processes
- **Disk space** - Warns if <5GB free

### Tier 2 - Important
- **Docker daemon** - Verifies Docker is running and responsive
- **GPU availability** - Checks nvidia-smi and free GPU memory
- **Docker Compose version** - Warns if <2.0

### Tier 3 - Nice to have
- **Volume paths** - Auto-creates missing directories
- **Network conflicts** - Removes stale Docker networks
- **Required images** - Shows what will be pulled

## Auto-fix Behavior

Checks auto-fix when safe:
- Container conflicts → removes old containers
- Port conflicts (our containers) → stops them
- Missing volume paths → creates directories
- Stale networks → removes and recreates

Checks that warn only:
- Low disk space → suggests cleanup
- GPU memory low → shows processes
- Old Compose version → suggests upgrade

Checks that error:
- Docker daemon down → suggests systemctl
- Port conflicts (external) → shows remediation

## Environment Variables

| Variable | Default | Effect |
|----------|---------|--------|
| `SKIP_PREFLIGHT` | `0` | Skip all pre-flight checks |
| `PREFLIGHT_STRICT` | `0` | Treat warnings as errors |
| `PREFLIGHT_NO_AUTOFIX` | `0` | Show fixes but don't apply (dry-run) |

## Examples

### Normal startup
```bash
make start
```

Output:
```
Starting profile 85
Running pre-flight checks...

  ✓ Docker daemon responsive
  ✓ GPU available (10245 MB free)
  ✓ Disk space OK (42 GB free)
  ✓ No container name conflicts
  ✓ Ports available (8 checked)
  ✓ All checks passed

[continues with docker compose up...]
```

### With auto-fix
```bash
make start
```

Output:
```
Running pre-flight checks...

  ✓ Docker daemon responsive
  ⚠ Container name conflict: ollama (eb67490a, created 3 months ago)
  → Removing conflicting container... done
  ✓ All checks passed
```

### Skip checks
```bash
SKIP_PREFLIGHT=1 make start
```

### Dry-run mode
```bash
PREFLIGHT_NO_AUTOFIX=1 make start
```

Shows what would be fixed without actually doing it.

### Strict mode
```bash
PREFLIGHT_STRICT=1 make start
```

Treats warnings (low disk, low GPU memory) as errors and halts.

## Troubleshooting

### Port conflict with external process

Error:
```
┌─────────────────────────────────────────────────────────┐
│ ✗ Pre-flight check failed: Port conflict                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ Port 8080 is already in use by:                        │
│   nginx (PID 1234)                                     │
│                                                         │
│ To fix:                                                │
│   1. Stop the conflicting process:                     │
│      sudo kill 1234                                    │
│   ...                                                  │
└─────────────────────────────────────────────────────────┘
```

Fix: Follow the remediation steps in the error box.

### GPU memory exhausted

Warning:
```
! GPU memory low: 234 MB free
  Current processes:
  GPU  PID    Process
  0    1234   python (32000 MB)
```

Fix: Stop other GPU processes or use `PREFLIGHT_STRICT=0` (default) to continue anyway.
```

**Step 2: Test complete workflow**

Create test scenarios and verify:

```bash
# Scenario 1: Clean start
make stop
make start

# Scenario 2: Container conflict
docker run -d --name ollama alpine sleep 3600
make start
# Should auto-remove and continue

# Scenario 3: Port conflict (our container)
make start  # Start normally
docker stop litellm
docker run -d -p 8080:80 --name old-litellm nginx:alpine
make start
# Should stop old-litellm and continue

# Scenario 4: Skip checks
SKIP_PREFLIGHT=1 make start

# Scenario 5: Dry-run mode
docker run -d --name ollama alpine sleep 3600
PREFLIGHT_NO_AUTOFIX=1 make start
# Should show what would be done but not do it
docker rm -f ollama

# Cleanup
make stop
```

**Step 3: Update main README**

Add a section to `README.md` (find appropriate location):

```markdown
### Pre-flight Checks

`make start` runs comprehensive checks before starting containers. It auto-fixes common issues like:

- Container name conflicts from previous runs
- Port conflicts with old containers
- Missing volume directories

See [docs/preflight-checks.md](docs/preflight-checks.md) for details.

Skip checks: `SKIP_PREFLIGHT=1 make start`
```

**Step 4: Commit documentation**

```bash
git add docs/preflight-checks.md README.md
git commit -m "docs: add pre-flight checks documentation

- User guide with examples and troubleshooting
- Environment variable reference
- Auto-fix behavior explanation
- Add reference to README"
```

**Step 5: Final integration test**

Run complete test suite:

```bash
# Test 1: Normal startup
make stop
make start
make stop

# Test 2: With container conflict (the original issue)
docker run -d --name ollama alpine sleep 3600
make start
# Verify ollama conflict is auto-fixed

# Test 3: Verify help text
make help | grep SKIP_PREFLIGHT

# Test 4: Verify all services healthy
docker ps --filter "label=com.docker.compose.project=gpu-inference-stack"
```

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: complete pre-flight checks system

Comprehensive pre-flight checks for make start:
- 9 checks across 3 tiers (critical/important/nice-to-have)
- Auto-fixes: container conflicts, port conflicts, missing paths
- Warnings: disk space, GPU memory, compose version
- Error boxes with remediation for unfixable issues
- Respects SKIP_PREFLIGHT, PREFLIGHT_STRICT, PREFLIGHT_NO_AUTOFIX
- Full documentation and test scenarios

Fixes the container name conflict issue that required
manual 'make stop' before 'make start'.

Tested:
- Container conflicts → auto-removed ✓
- Port conflicts (ours) → auto-stopped ✓
- Port conflicts (external) → error box shown ✓
- All flags working ✓

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Testing Checklist

Before marking complete, verify:

- [ ] `make start` runs pre-flight checks
- [ ] Container conflicts auto-removed (original issue fixed)
- [ ] Port conflicts (our containers) auto-stopped
- [ ] Port conflicts (external) show error box
- [ ] Low disk space shows warning but continues
- [ ] GPU check shows available memory
- [ ] Missing directories auto-created
- [ ] `SKIP_PREFLIGHT=1` bypasses all checks
- [ ] `PREFLIGHT_NO_AUTOFIX=1` shows dry-run mode
- [ ] `PREFLIGHT_STRICT=1` treats warnings as errors
- [ ] Help text updated and accurate
- [ ] Documentation complete and accurate
- [ ] All commits follow conventional commit format

## Success Criteria

1. Original issue solved: container conflicts auto-fixed
2. Clear error messages with actionable remediation
3. Auto-fixes are transparent (show what's happening)
4. Respects environment variable flags
5. Fast (<5s on healthy system)
6. Documentation complete

## Notes

- The script uses `set -euo pipefail` for safety but continues after check failures
- Each check returns 0/1/2 to allow aggregation in main()
- Color codes match existing Makefile style
- Error boxes use Unicode box-drawing (widely supported)
- Profile files sourced to get ENABLE_* and port variables
