# Pre-flight Check System Design

**Date:** 2026-09-22
**Status:** Approved
**Context:** Container name conflicts and other startup failures should be detected and auto-fixed before `docker compose up` runs.

## Problem Statement

Users encounter cryptic Docker Compose errors when running `make start`:
- Container name conflicts from previous runs
- Port conflicts with other services
- Low disk space causing pulls to fail
- GPU memory exhaustion
- Missing volume paths

These errors require the user to:
1. Read the Docker error
2. Diagnose the root cause
3. Figure out the fix command
4. Re-run `make start`

This creates friction, especially for the container conflict case where `make stop` is the obvious fix but the user has to discover it.

## Solution: Pre-flight Check System

Add comprehensive pre-flight checks before `docker compose up` that:
- **Auto-fix** where possible (with transparency)
- **Warn** when issues are non-critical
- **Halt with clear remediation** when unfixable

## Architecture

### Structure

```
make start
  ↓
scripts/preflight-checks.sh (new)
  ↓
Run all checks in order (Tier 1 → Tier 2 → Tier 3)
  ↓
Auto-fix where possible (show what we're doing)
Warn where we can't fix (show remediation)
Halt only on critical unfixable errors
  ↓
Continue to existing docker compose up flow
```

### Check Return Codes

Each check function returns:
- `0` - Pass (continue)
- `1` - Warning (show, but continue)
- `2` - Critical error (halt)

### Visual Design

Use existing Makefile color variables:
- **Status indicators**: ✓ (pass), ! (warning), ✗ (critical)
- **Auto-fix actions**: `→ Fixing: <action>... done`
- **Error boxes**: Unicode line-drawing for critical failures

## Check Catalog

### Tier 1 - Critical Checks

#### 1. Container Name Conflicts
**Check:** Query running containers for names that match our services but aren't owned by the current compose project.

```bash
docker ps -a --format '{{.Names}}\t{{.ID}}\t{{.CreatedAt}}' \
  --filter "name=^/(ollama|vllm-new|litellm|redis|postgres)$"
```

Filter out containers with label `com.docker.compose.project=gpu-inference-stack`.

**Auto-fix:** `docker rm -f <container>`

**Output:**
```
⚠ Container name conflict: ollama (eb67490a, created 3 months ago)
→ Removing conflicting container... done
```

#### 2. Port Conflicts
**Check:** For each port the active profile needs (derived from enabled services), verify nothing is listening.

Ports to check (based on enabled profiles):
- LiteLLM: `${LITELLM_PORT:-8080}`
- vLLM: `${VLLM_PORT:-8000}`
- Ollama: `${OLLAMA_PORT:-11434}`
- Prometheus: `${PROMETHEUS_PORT:-9090}`
- Grafana: `${GRAFANA_PORT:-3000}`
- etc.

Use `ss -tlnp` (preferred) or fall back to `lsof -i` if not available.

**Auto-fix:**
- If our own old container: stop it
- If external process: cannot auto-fix, show error box

**Output (auto-fixable):**
```
⚠ Port conflict: 8080 in use by litellm (old container)
→ Stopping old container... done
```

**Output (not auto-fixable):**
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
│                                                         │
│   2. Or change LiteLLM port in .env:                   │
│      LITELLM_PORT=8081                                 │
│                                                         │
│   3. Or force start anyway (not recommended):          │
│      SKIP_PREFLIGHT=1 make start                       │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

#### 3. Disk Space
**Check:** `df -BG .` for <5GB free in current directory.

**Auto-fix:** None (warning only)

**Output:**
```
⚠ Low disk space: 2.1 GB free (recommend 5GB+)
  Suggestion: docker system prune -a
```

### Tier 2 - Important Checks

#### 4. Docker Daemon Responsiveness
**Check:** `timeout 5 docker info`

**Auto-fix:** None (critical error if fails)

**Output (failure):**
```
✗ Docker daemon not responding (timeout after 5s)
  Is Docker running? Try: sudo systemctl start docker
```

#### 5. GPU Availability
**Check:** `nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits`

**Auto-fix:** None (warning only if <500MB free)

**Output:**
```
! GPU memory low: 234 MB free
  Current processes:
  GPU  PID    Process
  0    1234   python (5432 MB)
  0    5678   vllm (32000 MB)
```

Use `nvidia-smi pmon -c 1` to show top processes.

#### 6. Docker Compose Version
**Check:** `docker compose version --short` and verify >= 2.0.0

**Auto-fix:** None (warning if too old)

**Output:**
```
! Docker Compose version 1.29.2 is old (recommend 2.0+)
  Install: https://docs.docker.com/compose/install/
```

### Tier 3 - Nice to Have

#### 7. Required Images Available
**Check:** Parse `docker-compose.yml` for image references, check `docker images -q <image>`.

**Auto-fix:** None (compose will pull them, just inform)

**Output:**
```
ℹ Will pull missing images: vllm/vllm-openai:v0.29.0 (12 GB)
```

#### 8. Volume Mount Paths Exist
**Check:** Verify directories like `${VLLM_CACHE_DIR}`, `${HF_HOME}` exist.

**Auto-fix:** `mkdir -p <path>` silently

**Output (only if created):**
```
→ Created cache directory: ./data/vllm/cache
```

#### 9. Network Conflicts
**Check:** Verify `gpu-inference-net` doesn't exist from old deployment with conflicting settings.

```bash
docker network inspect gpu-inference-net 2>/dev/null
```

**Auto-fix:** If unused by running containers, remove and recreate.

**Output:**
```
⚠ Stale network found: gpu-inference-net
→ Removing and will recreate... done
```

## Consolidated Output Format

When all checks pass with some auto-fixes:

```
Starting profile 85
Running pre-flight checks...

  ✓ Docker daemon responsive
  ✓ GPU available (10245 MB free)
  ✓ Disk space OK (42 GB free)
  ⚠ Container name conflict: ollama (eb67490a, created 3 months ago)
  → Removing conflicting container... done
  ✓ Ports available (8080, 11434, 11502)
  ✓ Volume paths exist
  ✓ All checks passed

[existing docker compose up output continues...]
```

When checks fail:

```
Starting profile 85
Running pre-flight checks...

  ✓ Docker daemon responsive
  ✓ GPU available (10245 MB free)
  ! Low disk space: 2.1 GB free (recommend 5GB+)
  ✗ Port 8080 in use by nginx (PID 1234)

[error box shown above]
```

## Integration

### Makefile Changes

Modify the `start` target (around line 192):

```makefile
start: _require_profile
	@printf "$(BOLD)Starting$(RST) $(DIM)profile $(PROFILE_NAME)$(RST)\n"
	@# Run pre-flight checks (auto-fixes where possible)
	@if [ "$(SKIP_PREFLIGHT)" != "1" ]; then \
	  ./scripts/preflight-checks.sh || exit 1; \
	fi
	@# Check for .env overrides (existing check continues...)
	@if ! ./scripts/check-env-overrides.sh; then \
```

Add to `help` target:

```makefile
	@printf "  $(DIM)Environment variables:$(RST)\n"
	@printf "  $(DIM)  SKIP_PREFLIGHT=1      skip pre-flight checks before start$(RST)\n"
	@printf "  $(DIM)  PREFLIGHT_STRICT=1    treat warnings as errors$(RST)\n"
	@printf "  $(DIM)  PREFLIGHT_NO_AUTOFIX=1 show fixes but don't apply$(RST)\n"
```

### Script Structure

Create `scripts/preflight-checks.sh`:

```bash
#!/usr/bin/env bash
# Pre-flight checks for make start
# Auto-fixes common issues, warns on others, halts on critical failures

set -euo pipefail

# Import color codes from Makefile pattern
BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
GRN=$(tput setaf 2 2>/dev/null || true)
YEL=$(tput setaf 3 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)

# Configuration
STRICT=${PREFLIGHT_STRICT:-0}
NO_AUTOFIX=${PREFLIGHT_NO_AUTOFIX:-0}
AUTO=${AUTO:-0}

# Check functions
check_docker_daemon() { ... }
check_container_conflicts() { ... }
check_port_conflicts() { ... }
check_disk_space() { ... }
check_gpu_availability() { ... }
check_compose_version() { ... }
check_images_available() { ... }
check_volume_paths() { ... }
check_network_conflicts() { ... }

# Main orchestration
main() {
    printf "Running pre-flight checks...\n\n"

    local warnings=0
    local errors=0

    # Run checks in order
    check_docker_daemon || ((errors++))
    check_gpu_availability || ((warnings++))
    check_disk_space || ((warnings++))
    check_container_conflicts || ((errors++))
    check_port_conflicts || ((errors++))
    check_compose_version || ((warnings++))
    check_volume_paths || ((warnings++))
    check_network_conflicts || ((errors++))
    check_images_available || true  # Info only

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

## Configuration Options

Environment variables supported:

| Variable | Default | Effect |
|----------|---------|--------|
| `SKIP_PREFLIGHT` | `0` | Skip all pre-flight checks |
| `PREFLIGHT_STRICT` | `0` | Treat warnings as errors |
| `PREFLIGHT_NO_AUTOFIX` | `0` | Show what would be fixed, don't apply |
| `AUTO` | `0` | No interactive prompts (existing) |

## Error Handling & Edge Cases

### Multiple Failures
- Show all failures in sequence
- Only halt if any are critical (return code 2)
- Warnings don't block startup unless `PREFLIGHT_STRICT=1`

### Check Timeouts
- Every external command gets a timeout (5s for most, 10s for GPU checks)
- Timeout treated as warning, not critical failure
- Output: `! GPU check timed out (continuing anyway)`

### Permissions
- Non-root user can't `lsof -i`: fall back to `ss -tlnp`
- If both fail: skip port check with warning
- Docker socket access required (already a requirement for the stack)

### Container Ownership Ambiguity
- Container has same name but different compose project label
- More careful: show warning, don't auto-remove
- Suggest `docker rm -f <name>` manually

### Performance
- Run checks sequentially (easier to read output)
- Target <5 seconds total on healthy system
- Use timeouts on every check
- Cache results where possible (e.g., `docker ps` once, parse multiple times)

## Testing Plan

### Manual Testing Scenarios

1. **Clean system**: All checks pass, no output clutter
2. **Container conflict**: Old ollama container blocks startup → auto-removed
3. **Port conflict (our container)**: Old litellm on port 8080 → auto-stopped
4. **Port conflict (external)**: nginx on port 8080 → error box shown
5. **Low disk space**: <5GB free → warning shown, continues
6. **GPU exhausted**: <500MB free → warning with process list
7. **Missing volume paths**: Auto-created silently
8. **Stale network**: Recreated automatically
9. **`SKIP_PREFLIGHT=1`**: All checks bypassed
10. **`PREFLIGHT_STRICT=1`**: Warning causes failure

### Success Criteria

- Container conflict auto-fixed in <2s
- Port conflict detected and explained clearly
- Error boxes are readable and actionable
- Total check time <5s on healthy system
- No false positives on fresh install
- Respects `AUTO=1` for unattended runs

## Future Enhancements

Not in initial scope, but could add:

1. **Profile-specific checks**: Only check ports/resources needed by active profile
2. **Health history**: Track common failures per box, surface patterns
3. **Remediation automation**: `make fix-preflight` to run suggested fixes
4. **Remote checks**: Verify connectivity to peer GPU boxes for delegated roles
5. **Check plugins**: Allow custom checks via `scripts/preflight-checks.d/`

## References

- Makefile existing error handling: lines 157-164, 219-220, 235-236
- Container conflict documented: Makefile:283-284
- Color variables defined: Makefile:18-23
