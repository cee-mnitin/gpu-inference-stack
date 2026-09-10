#!/usr/bin/env bash
# `docker compose` with this box's server profile layered in.
#
# A bare `docker compose` reads .env only, so every value that lives in the
# profile silently falls back to its compose default — which was written for a
# different class of card. Use this instead for anything ad-hoc:
#
#     scripts/dc.sh ps
#     scripts/dc.sh logs -f litellm
#     scripts/dc.sh config | less
#     scripts/dc.sh exec litellm sh
#
# Service-selecting commands need the compose profiles too; pass them yourself
# when targeting a profiled service, e.g.
#     scripts/dc.sh --profile vllm up -d vllm
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-profile.sh
. "$SCRIPT_DIR/lib-profile.sh"

if ! profile_assert_resolvable >/dev/null; then
    profile_assert_resolvable   # re-run for the message on stderr
    exit 1
fi

# Unquoted on purpose: profile_env_file_args emits separate --env-file words.
# shellcheck disable=SC2046
exec docker compose $(profile_env_file_args) -f "$PROJECT_ROOT/docker-compose.yml" "$@"
