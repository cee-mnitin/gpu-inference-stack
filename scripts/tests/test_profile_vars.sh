#!/usr/bin/env bash
# Tests for profile_load_vars in scripts/lib-profile.sh.
#
# WHY THIS EXISTS. health-check.sh sourced .env alone, so every value that
# lives in a SERVER PROFILE — the ports, the bind address — fell back to a
# compose default written for a different box. On ddai4 that pointed the
# LiteLLM probe at :8080, which platform-traefik holds, and the check reported
# "LiteLLM ✗ FAILED (HTTP 404)" while LiteLLM was healthy on :8090. A check
# that is wrong in the reassuring direction is bad; one that is wrong in the
# alarming direction trains operators to ignore it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0; fail=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/servers"
cat > "$FIX/servers/common-test.env" <<'PROF'
# base of the EXTENDS chain
LITELLM_PORT=8090
LITELLM_BIND_ADDR=0.0.0.0
GRAFANA_PORT=3400
INFINITY_CMD="v2 --model-id BAAI/bge-m3 --port 7997"
PROF
cat > "$FIX/servers/server-64.env" <<'PROF'
EXTENDS=common-test
SERVER_NAME=ddai4
REDIS_PORT=6379
PROF
cat > "$FIX/.env" <<'ENV'
SERVER_PROFILE=64
GRAFANA_PORT=3999
LITELLM_MASTER_KEY=sk-secret
ENV

run_load() {
    # Fresh subshell per case: exported vars must not leak between assertions.
    ( PROJECT_ROOT="$FIX"; unset SERVER_PROFILE LITELLM_PORT LITELLM_BIND_ADDR GRAFANA_PORT \
        REDIS_PORT INFINITY_CMD LITELLM_MASTER_KEY SERVER_NAME
      # shellcheck source=../lib-profile.sh
      . "$REPO_ROOT/scripts/lib-profile.sh"
      profile_load_vars
      eval "printf '%s\n' \"\${$1-<unset>}\"" )
}

echo "profile_load_vars"
is "reads a value from the profile itself"          "ddai4"    "$(run_load SERVER_NAME)"
is "reads a value from the EXTENDS base"            "8090"     "$(run_load LITELLM_PORT)"
is "reads the bind address from the base"           "0.0.0.0"  "$(run_load LITELLM_BIND_ADDR)"
is ".env wins over the profile chain"               "3999"     "$(run_load GRAFANA_PORT)"
is "still reads .env-only keys"                     "sk-secret" "$(run_load LITELLM_MASTER_KEY)"
is "a quoted value with spaces survives intact"     "v2 --model-id BAAI/bge-m3 --port 7997" "$(run_load INFINITY_CMD)"
is "an absent key stays unset"                      "<unset>"  "$(run_load NO_SUCH_KEY)"

# The pre-existing caller's environment must win over both: an operator running
# LITELLM_PORT=9999 ./scripts/health-check.sh is overriding on purpose.
got="$( PROJECT_ROOT="$FIX" LITELLM_PORT=9999 bash -c '
    . "'"$REPO_ROOT"'/scripts/lib-profile.sh"; profile_load_vars; printf "%s" "$LITELLM_PORT"' )"
is "an already-set env var is not clobbered"        "9999"     "$got"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
