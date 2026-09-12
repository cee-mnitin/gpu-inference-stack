#!/usr/bin/env bash
# Restart stack containers that Docker reports unhealthy.
#
# THE HALF THAT ACTS. `scripts/healthprobe.py` detects a wedged engine from
# inside the container; nothing inside a container can restart it. Docker's
# `restart: unless-stopped` fires on process EXIT and never on health status,
# so an unhealthy container is labelled and then left running indefinitely —
# on 2026-09-12 an Infinity container served no embeddings for 11 minutes and
# would have continued until someone noticed by hand.
#
# Runs on the HOST rather than as an autoheal sidecar because the sidecar
# pattern needs /var/run/docker.sock mounted into a container, and a mounted
# socket is root-equivalent on a box that also runs the platform stack. Here
# the privilege is the operator's own, already-present docker access.
#
# Reluctant by design. An engine under load is slow, not hung, so a container
# must be unhealthy across CONSECUTIVE polls before it is touched, and each
# restart is rate-limited: restarting a busy vLLM costs minutes of model load,
# and a watchdog that flaps is worse than the fault it chases.
#
#   watchdog.sh                  one pass, restart what qualifies
#   watchdog.sh --dry-run        report only
#   watchdog.sh --once           alias for one pass (systemd timer default)
#
# Install as a timer:  see docs/TROUBLESHOOTING.md
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${WATCHDOG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gpu-inference-stack}"
#: Consecutive unhealthy observations before restarting. With a 60s timer that
#: is ~3 minutes of confirmed failure, on top of the 5 failed probes Docker
#: already needs to call a container unhealthy at all.
THRESHOLD="${WATCHDOG_THRESHOLD:-3}"
#: Never restart the same container more often than this, whatever the state
#: says. A container that is unhealthy again 60s after a restart is not being
#: fixed by restarting, and hammering it hides that.
COOLDOWN_S="${WATCHDOG_COOLDOWN_S:-900}"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --once) ;;                      # one pass is the only mode
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "watchdog: unknown argument $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" 2>/dev/null

log() { printf '%s watchdog: %s\n' "$(date -Is)" "$*"; }

# Only this project's containers: the host runs other stacks, and restarting
# somebody else's unhealthy container is not this script's business.
mapfile -t unhealthy < <(
    docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-gpu-inference-stack}" \
              --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null
)

if [ "${#unhealthy[@]}" -eq 0 ]; then
    # Clear every streak: nothing is unhealthy, so no partial streak should
    # survive to combine with a future unrelated blip.
    rm -f "$STATE_DIR"/streak.* 2>/dev/null
    exit 0
fi

for name in "${unhealthy[@]}"; do
    [ -n "$name" ] || continue
    streak_file="$STATE_DIR/streak.$name"
    last_file="$STATE_DIR/last_restart.$name"

    streak=$(cat "$streak_file" 2>/dev/null || echo 0)
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
    streak=$((streak + 1))
    echo "$streak" > "$streak_file"

    if [ "$streak" -lt "$THRESHOLD" ]; then
        log "$name unhealthy ($streak/$THRESHOLD) — waiting"
        continue
    fi

    now=$(date +%s)
    last=$(cat "$last_file" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $((now - last)) -lt "$COOLDOWN_S" ]; then
        log "$name unhealthy but restarted $((now - last))s ago (cooldown ${COOLDOWN_S}s) — NOT restarting; this needs a human"
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$name unhealthy ($streak) — would restart (dry run)"
        continue
    fi

    log "$name unhealthy for $streak consecutive checks — restarting"
    if docker restart "$name" >/dev/null 2>&1; then
        echo "$now" > "$last_file"
        rm -f "$streak_file"
        log "$name restarted"
    else
        log "$name RESTART FAILED — leaving it alone"
    fi
done
