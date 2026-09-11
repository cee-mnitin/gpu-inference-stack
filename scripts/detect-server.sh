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

# Read the fleet register from BOTH files, .env winning on a duplicate octet.
#
# NOT ".env if it exists, else .env.example". A box upgrading from an older
# checkout has a .env that predates the fleet block entirely, so preferring it
# yielded ZERO entries and detection failed on a host whose address was sitting
# right there — which is exactly what happened on crimson-llm2. .env.example is
# the committed register and is present on every checkout; .env only ever adds
# to it or overrides a line.
_fleet_lines() {
    local seen=" "
    local f line octet
    for f in "$PROJECT_ROOT/.env" "$PROJECT_ROOT/.env.example"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            octet="${line#GPU_}"; octet="${octet%%_URL=*}"
            case "$seen" in *" $octet "*) continue ;; esac
            seen="$seen$octet "
            printf '%s\n' "$line"
        done < <(grep -E '^GPU_[0-9A-Za-z_]+_URL=' "$f" 2>/dev/null)
    done
}

register="$PROJECT_ROOT/.env.example + .env"

matches=""
while IFS= read -r line; do
    # GPU_<octet>_URL=http://<addr>:<port>
    octet="${line#GPU_}"; octet="${octet%%_URL=*}"
    addr="$(printf '%s' "${line#*=}" | sed -E 's|https?://([^:/]+).*|\1|')"
    [ -n "$addr" ] || continue
    if printf '%s\n' "$my_addrs" | grep -qx -- "$addr"; then
        matches="$matches $octet"
    fi
done < <(_fleet_lines)

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
    _entries="$(_fleet_lines)"
    echo "${YELLOW}Could not match this host to a fleet entry.${NC}" >&2
    echo "${DIM}  Addresses found:$(printf ' %s' $my_addrs)${NC}" >&2
    if [ -z "$_entries" ]; then
        echo "${RED}  The fleet register is EMPTY — neither .env nor .env.example" >&2
        echo "  defines any GPU_<octet>_URL.${NC}" >&2
        echo "${DIM}  That block is what detection matches against. If this checkout" >&2
        echo "  predates it, 'git pull' brings it in via .env.example.${NC}" >&2
    else
        echo "${DIM}  Fleet entries (.env overriding .env.example):${NC}" >&2
        printf '%s\n' "$_entries" | sed 's/^/    /' >&2
        echo "${DIM}  None of them names an address this host holds.${NC}" >&2
    fi
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
