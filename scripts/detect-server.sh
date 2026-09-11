#!/usr/bin/env bash
# Work out which server profile this machine should use.
#
# Prints ONE line to stdout: the profile name (e.g. `85`), or nothing if it
# cannot tell. Diagnostics go to stderr, so a caller can do:
#     PROFILE="$(scripts/detect-server.sh)"
#
# Detection is by IP ADDRESS, matched against the GPU_<octet>_URL entries in
# .env.example. That file is the fleet register and is identical on every box,
# so the mapping needs no second list to drift out of step — the same reason
# the fleet block is named by octet in the first place.
#
# Hostname is used only to CORROBORATE, never to decide: hostnames get changed,
# and a box renamed mid-migration would otherwise silently pick up another
# machine's model and VRAM split.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'

# Every address this host actually holds.
my_addrs="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
[ -n "$my_addrs" ] || my_addrs="$(hostname -I 2>/dev/null | tr ' ' '\n')"

register="$PROJECT_ROOT/.env.example"
[ -f "$PROJECT_ROOT/.env" ] && register="$PROJECT_ROOT/.env"

matches=""
while IFS= read -r line; do
    # GPU_<octet>_URL=http://<addr>:<port>
    octet="${line#GPU_}"; octet="${octet%%_URL=*}"
    addr="$(printf '%s' "${line#*=}" | sed -E 's|https?://([^:/]+).*|\1|')"
    [ -n "$addr" ] || continue
    if printf '%s\n' "$my_addrs" | grep -qx -- "$addr"; then
        matches="$matches $octet"
    fi
done < <(grep -E '^GPU_[0-9A-Za-z_]+_URL=' "$register" 2>/dev/null)

# Deduplicate; a host legitimately holds both a LAN and a Netbird address, and
# both can point at the same octet entry.
matches="$(printf '%s\n' $matches | sort -u | tr '\n' ' ' | sed 's/ *$//')"
n="$(printf '%s\n' $matches | grep -c . || true)"

if [ "$n" -gt 1 ]; then
    echo "${RED}✗ This host matches more than one fleet entry:${NC} $matches" >&2
    echo "${DIM}  Refusing to guess. Pass one explicitly:  make setup PROFILE=<name>${NC}" >&2
    exit 2
fi

if [ "$n" -eq 0 ]; then
    echo "${YELLOW}Could not match this host to a fleet entry in ${register##*/}.${NC}" >&2
    echo "${DIM}  Addresses found:$(printf ' %s' $my_addrs)${NC}" >&2
    echo "${DIM}  Fleet entries:${NC}" >&2
    grep -E '^GPU_[0-9A-Za-z_]+_URL=' "$register" 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi

profile="$matches"
if [ ! -f "$PROJECT_ROOT/servers/server-$profile.env" ]; then
    echo "${RED}✗ Detected fleet entry '$profile' but servers/server-$profile.env does not exist.${NC}" >&2
    exit 1
fi

# Corroborate against the profile's own SERVER_NAME. A mismatch is a warning,
# not a veto — the address is the authority — but it is exactly what you want
# to see before a deploy writes this box's identity.
want="$(sed -n 's/^SERVER_NAME=//p' "$PROJECT_ROOT/servers/server-$profile.env" | tail -1)"
have="$(hostname -s 2>/dev/null)"
if [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ]; then
    echo "${YELLOW}Note: hostname is '$have' but servers/server-$profile.env says SERVER_NAME=$want.${NC}" >&2
    echo "${DIM}  Matched on IP address, which is authoritative. Check this is the box you mean.${NC}" >&2
fi

printf '%s\n' "$profile"
