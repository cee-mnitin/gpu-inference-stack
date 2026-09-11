#!/usr/bin/env bash
# Print the env files that make up this box's configuration, IN LOAD ORDER:
#
#     <base…>  <profile>  .env
#
# so a caller can `for f in $(scripts/profile-files.sh); do . "$f"; done` and
# end up with exactly what compose sees. Bases come first and .env last, the
# same last-wins order passed to `docker compose --env-file`.
#
# This exists because sourcing the profile file ALONE stopped being correct
# the moment profiles could inherit: a thin profile holds only EXTENDS and
# SERVER_NAME, so a caller reading ENABLE_VLLM from it got nothing and quietly
# decided the box runs no services.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-profile.sh
. "$SCRIPT_DIR/lib-profile.sh"

name="${SERVER_PROFILE:-$(profile_env_get SERVER_PROFILE)}"
[ -n "$name" ] && profile_chain "$name" | tac
[ -f "$PROJECT_ROOT/.env" ] && printf '%s\n' "$PROJECT_ROOT/.env"
exit 0
