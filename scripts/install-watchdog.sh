#!/usr/bin/env bash
# Install and enable the host watchdog timer. Idempotent; safe to re-run.
#
# This is the HOST half of engine recovery. healthprobe.py (the container
# healthcheck) only reports: `restart: unless-stopped` fires on process exit,
# never on health status, so an unhealthy container is otherwise labelled and
# left running. watchdog.sh is what acts on it.
#
# THREE THINGS HAVE TO BE TRUE, and each has failed in a way that looked fine:
#
#   1. The units must be installed as USER units. Running the restarter as root
#      would hand it more privilege than the thing it restarts.
#   2. The service must NOT declare a dependency on docker.service. It is a
#      system unit; a user manager cannot see it, and systemd refuses to queue
#      the job rather than treating it as a soft miss — which killed the TIMER
#      on activation and meant the watchdog never ran at all. Fixed in the unit
#      itself; noted here because it is invisible from `systemctl status`
#      unless you read the journal.
#   3. Lingering must be on, or the user manager — and this timer with it —
#      stops at logout and never starts at boot. A box would then be protected
#      exactly until the operator who set it up disconnected.
set -uo pipefail
GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RST=$'\033[0m'
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
rc=0

# A user manager needs a session bus. Over a bare `ssh host make setup` with no
# lingering yet there may be none, and `systemctl --user` then fails with
# "Failed to connect to bus" — which must not fail provisioning.
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    printf "  ${YEL}!${RST} no user systemd session here — skipping the watchdog timer\n"
    printf "  ${DIM}  install it from a login shell on this host:\n"
    printf "      ./scripts/install-watchdog.sh${RST}\n"
    exit 0
fi

# --no-legend, and read the field by name rather than by row number: on a timer
# that has never fired LAST is "-", which shifts every positional column and
# printed "next - - Sat" from an NR==2 parse.
next_fire() {
    # Read NEXT from list-timers, not from `systemctl show`: the
    # NextElapseUSec* properties are pretty-printed as a timespan
    # ("1month 2w 2d ...") with and without --value, so there is no raw number
    # to do arithmetic on. NEXT is the FIRST column of --no-legend output and
    # is "-" when the timer is not scheduled, which is the only case that
    # needs distinguishing; LAST/PASSED shift columns on a never-fired timer,
    # so nothing later than field 3 is safe to index.
    local n
    n="$(_next_col)"
    # On a FRESH install the timer fires the service immediately — OnBootSec is
    # long past by the time anyone runs setup — and NEXT stays blank until that
    # first run finishes. Querying straight after `restart` therefore reported
    # "active ... not scheduled", which reads like a failure and is not one.
    # One short retry is enough to tell the two apart.
    if [ "$n" = "-" ]; then sleep 3; n="$(_next_col)"; fi
    case "$n" in
        -)  if [ "$(systemctl --user is-active gis-watchdog.service 2>/dev/null)" = "activating" ]; then
                printf 'first run in progress'
            else printf 'no next elapse — check the unit'; fi ;;
        *)  printf 'next %s' "$n" ;;
    esac
}

_next_col() {
    systemctl --user list-timers gis-watchdog.timer --no-pager --no-legend 2>/dev/null \
        | awk 'NR==1{ if ($1=="-") print "-"; else print $2 " " $3 }'
}

mkdir -p "$UNIT_DIR" || exit 1
cp "$_DIR/systemd/gis-watchdog.service" "$_DIR/systemd/gis-watchdog.timer" "$UNIT_DIR/" || exit 1
systemctl --user daemon-reload || rc=1
# --now so a fresh install starts ticking without a reboot; restart so an
# already-enabled timer picks up a changed unit file instead of silently
# running the old one.
systemctl --user enable gis-watchdog.timer >/dev/null 2>&1 || rc=1
systemctl --user restart gis-watchdog.timer || rc=1

if [ "$(systemctl --user is-active gis-watchdog.timer 2>/dev/null)" = "active" ]; then
    printf "  ${GRN}✓${RST} watchdog timer active  ${DIM}%s${RST}\n" \
        "$(next_fire)"
else
    printf "  ${RED}✗${RST} watchdog timer did not start. Why:\n"
    journalctl --user -u gis-watchdog.timer -n 3 --no-pager 2>/dev/null | sed 's/^/      /'
    rc=1
fi

# Lingering. Enabling it for YOUR OWN user is usually allowed by polkit with no
# password (org.freedesktop.login1.set-self-linger); where a stricter policy
# applies it needs root, so ask for it rather than failing the install.
if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = "yes" ]; then
    printf "  ${GRN}✓${RST} lingering already enabled ${DIM}(survives logout, starts at boot)${RST}\n"
elif loginctl enable-linger 2>/dev/null && \
     [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = "yes" ]; then
    printf "  ${GRN}✓${RST} lingering enabled ${DIM}(survives logout, starts at boot)${RST}\n"
else
    printf "  ${YEL}!${RST} could not enable lingering — the timer will STOP when you log out\n"
    printf "  ${DIM}  run:  sudo loginctl enable-linger %s${RST}\n" "$(id -un)"
    rc=1
fi
exit $rc
