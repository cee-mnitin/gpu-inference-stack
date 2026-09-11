# Shared profile resolution. SOURCE this, do not execute it.
#
# One knob activates a server: `SERVER_PROFILE=<name>` in .env. Everything that
# differs between boxes — GPU, engine, models, VRAM split, ports, which roles
# are served locally and which are delegated to a peer — lives in
# servers/server-<name>.env, which is committed. .env keeps only what is
# genuinely per-host: the profile name, secrets, and the peer address block
# (identical on every box, so it never needs editing).
#
# HOW THE LAYERING WORKS
#   docker compose --env-file servers/server-<name>.env --env-file .env
# Compose unions the keys of every --env-file and the LAST file wins on a
# conflict (verified on compose 5.1.4), so the profile supplies the defaults
# and .env overrides them. That ordering is the whole design: a profile can be
# committed and shared, while a host keeps its own secrets and any one-off
# override without editing a tracked file.
#
# WHY A HELPER RATHER THAN A COPIED .env
# The previous flow was `cp servers/server-x.env .env`, which forks the profile
# the moment anything is tuned: the box drifts from the committed profile and
# nothing can tell you how. Layering keeps the profile authoritative.
#
# ⚠️  A BARE `docker compose` COMMAND DOES NOT SEE THE PROFILE. It reads .env
# only, so every profile value falls back to its compose default. Use
# scripts/dc.sh (a thin wrapper that adds these flags) for ad-hoc commands:
#     scripts/dc.sh ps
#     scripts/dc.sh logs -f litellm

# Resolve repo root from THIS file, so a caller's cwd is irrelevant.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_LIB_DIR/.." && pwd)}"

# Read a key from .env WITHOUT sourcing it: .env legitimately contains values
# with spaces and shell metacharacters (INFINITY_CMD is a quoted multi-word
# command), and sourcing it to learn one variable has already caused a deploy
# to abort with `--model-id: command not found`.
profile_env_get() {
    local key="$1" file="${2:-$PROJECT_ROOT/.env}"
    [ -f "$file" ] || return 1
    sed -n "s/^${key}=//p" "$file" | tail -1 | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

# Absolute path of the active profile file, or empty if none is selected.
# Accepts either a bare name (63) or the full filename, so both
# SERVER_PROFILE=63 and SERVER_PROFILE=server-63.env work.
profile_path() {
    local name="${SERVER_PROFILE:-$(profile_env_get SERVER_PROFILE)}"
    [ -n "$name" ] || return 1
    local candidate
    for candidate in \
        "$PROJECT_ROOT/servers/$name" \
        "$PROJECT_ROOT/servers/$name.env" \
        "$PROJECT_ROOT/servers/server-$name.env"
    do
        if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 2   # named but not found — callers must report this, not ignore it
}

# Resolve a profile's EXTENDS chain, base first.
#
# A profile may declare `EXTENDS=<name>` to inherit another profile's settings,
# which is what stops a fleet of identical boxes becoming N copies of one file.
# The five ddai* machines share a GPU, a model and a VRAM split; without this,
# changing the model would mean editing five files and missing one — the exact
# drift the profile system exists to prevent.
#
# Emitted BASE FIRST so the deriving profile overrides it, the same last-wins
# rule compose already applies between the profile and .env. The full order is
#     base -> profile -> .env
#
# Chains are followed to a depth of 8 and a repeated name stops the walk, so a
# cycle (A extends B extends A) terminates instead of hanging.
profile_chain() {
    local name="$1" depth=0 seen=" " f base
    while [ -n "$name" ] && [ "$depth" -lt 8 ]; do
        case "$seen" in *" $name "*)
            echo "profile EXTENDS cycle at '$name' — stopping" >&2; break ;;
        esac
        seen="$seen$name "
        f=""
        for f in "$PROJECT_ROOT/servers/$name" \
                 "$PROJECT_ROOT/servers/$name.env" \
                 "$PROJECT_ROOT/servers/server-$name.env"; do
            [ -f "$f" ] && break || f=""
        done
        [ -n "$f" ] || { echo "profile '$name' not found (EXTENDS chain)" >&2; break; }
        printf '%s\n' "$f"
        base="$(sed -n 's/^EXTENDS=//p' "$f" | tail -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
        name="$base"
        depth=$((depth + 1))
    done
}

# The --env-file arguments: bases first, then the profile, then .env — so .env
# always wins and a profile always beats what it extends. Emitted as separate
# words on purpose; callers use it unquoted.
profile_env_file_args() {
    local name p
    name="${SERVER_PROFILE:-$(profile_env_get SERVER_PROFILE)}"
    if [ -n "$name" ]; then
        # profile_chain lists derived-first; reverse it so the base is passed
        # first and the deriving profile overrides it.
        profile_chain "$name" | tac | while IFS= read -r p; do
            printf -- '--env-file %s ' "$p"
        done
    fi
    [ -f "$PROJECT_ROOT/.env" ] && printf -- '--env-file %s ' "$PROJECT_ROOT/.env"
}

# Warn once, loudly, when SERVER_PROFILE names a file that does not exist.
# Silence here would mean every profile value quietly falling back to a compose
# default that was written for a different class of card.
profile_assert_resolvable() {
    local name p rc
    name="${SERVER_PROFILE:-$(profile_env_get SERVER_PROFILE)}"
    p="$(profile_path)"; rc=$?
    if [ -z "$name" ]; then
        echo "  Server Profile: (none — using compose defaults)"
        return 0
    fi
    if [ "$rc" = "2" ] || [ -z "$p" ]; then
        echo "" >&2
        echo "✗ SERVER_PROFILE=$name but no such profile exists." >&2
        echo "  Looked for servers/{$name,$name.env,server-$name.env}" >&2
        echo "  Available:" >&2
        ls -1 "$PROJECT_ROOT"/servers/server-*.env 2>/dev/null \
        | sed -E 's|.*/server-(.*)\.env|    \1|' >&2
        echo "" >&2
        return 1
    fi
    echo "  Server Profile: $name  (${p#$PROJECT_ROOT/})"
}
