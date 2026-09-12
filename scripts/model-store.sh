#!/usr/bin/env bash
# Shared model store on the NAS: look there before the internet.
#
# WHY. Every box in the fleet serves the same handful of public checkpoints, and
# each one was fetching them from Hugging Face independently. Qwen3.6-35B-A3B
# in NVFP4 is 23.5 GB and took 37 minutes over this site's ~13 MB/s link; five
# boxes doing that is five times the wait and five times the egress for bytes
# that are byte-identical. The NAS is on the LAN. Pull from there instead.
#
# LAYOUT. The store is a VALID HF_HOME — $MODEL_STORE_DIR/hub/models--<org>--<name>,
# exactly the layout huggingface_hub writes. That is deliberate: the repo id
# stays the identifier, so a profile still says
# `VLLM_MODEL=nvidia/Qwen3.6-35B-A3B-NVFP4` and nothing downstream learns about
# the NAS. A human can also just point HF_HOME at the store to inspect it.
#
# WHY COPY RATHER THAN SERVE FROM THE NAS. Pointing HF_HOME at the mount would
# work and save disk, but vLLM reads the whole checkpoint at every start; 23.5 GB
# over NFS on each restart, multiplied by the boxes, is worse than one copy.
# Local disk is the working set, the NAS is the distribution channel.
#
# CONCURRENCY, AND WHY THERE IS NO flock HERE. The mount options are
# `local_lock=all` (see `mount | grep shared-nas`), so flock on an NFS file is
# local to one host and two boxes would BOTH believe they held it — worse than
# no lock, because it reads as safe. Publishing therefore stages into a
# per-host, per-pid directory on the same filesystem and finishes with a single
# rename, which NFS does atomically. If the destination already exists the
# rename fails, which means another box published first; that is a success, not
# an error, and the staging copy is discarded.
#
# The mount also caches attributes for up to 120s (acregmin/acregmax=120), so a
# model published seconds ago may be invisible to another box for a couple of
# minutes. The cost of losing that race is one redundant download, never a
# corrupt cache, so it is not worth defending against.
set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_DIR/.." && pwd)}"

# Default store. Empty disables every NAS interaction and leaves plain
# download-from-the-internet behaviour, which is what a box with no NAS mount
# needs — it must degrade to "slow", never to "broken".
MODEL_STORE_DIR="${MODEL_STORE_DIR-/media/NAS/shared-nas/ml_models/public_llm_models}"

# ── why the copy runs inside a container ─────────────────────────────────────
# The HF cache is written by ROOT: vLLM runs as root and populates the cache
# itself when a model is missing at start, and so does the downloader below.
# Some of what it writes is not world-readable — huggingface_hub 1.30 writes
# its xet metadata as `trees/<sha>.json` mode 0600 — so a plain `rsync` run by
# the invoking user dies with:
#
#     rsync: [sender] send_files failed to open ".../trees/<sha>.json":
#            Permission denied (13)
#     rsync error: some files/attrs were not transferred (code 23)
#
# and, because exit 23 is a PARTIAL transfer, it takes 22 GB of successfully
# copied bytes down with it. There is no passwordless sudo on these boxes to
# chown around it.
#
# So the invariant is: whoever writes the cache runs as root, therefore whoever
# copies it runs as root too. `cp -a` rather than rsync because the vLLM image
# ships coreutils and not rsync, and -a preserves the snapshot's relative
# symlinks, which is the one property that must survive (copying them as files
# would double the size and defeat HF's blob de-duplication).
#
# Writing to the NAS as root is safe here: the export squashes every write to
# uid 1024 regardless of who makes it, verified by probe.
#
# --no-preserve=ownership is NOT optional, and it is the SAME TRAP that `rsync
# -a`'s chgrp fell into: `cp -a` implies -p, which tries to chown each file to
# root, and the export squashes ownership so that chown returns EPERM even for
# root. cp copies every byte correctly, prints "failed to preserve ownership",
# and then EXITS NON-ZERO — so a caller that checks the exit status throws away
# a perfectly good 22 GB copy. Ownership is meaningless on a share that
# squashes it; mode, timestamps and symlinks are what have to survive.
copy_tree() {   # copy_tree <abs src dir> <abs dst dir>
    local src="$1" dst="$2"
    docker run --rm \
        -v "$LOCAL_HF:$LOCAL_HF" \
        -v "$MODEL_STORE_DIR:$MODEL_STORE_DIR" \
        --entrypoint sh "${VLLM_IMAGE:-vllm/vllm-openai:v0.29.0}" \
        -c 'mkdir -p "$2" && cp -a --no-preserve=ownership "$1/." "$2/"' _ "$src" "$dst"
}

# The move and the delete run as root for the same reason the copy does. A
# staged tree the container wrote is owned by root with 0755 subdirectories, so
# `rm -rf` as the invoking user CANNOT unlink anything inside it — it needs
# write permission on each subdirectory, not just on the parent. Cleaning up a
# failed fetch from the host would leave a half-copy behind and report success.
move_tree() {   # move_tree <abs src> <abs dst>  — exit status is mv's
    docker run --rm \
        -v "$LOCAL_HF:$LOCAL_HF" \
        -v "$MODEL_STORE_DIR:$MODEL_STORE_DIR" \
        --entrypoint sh "${VLLM_IMAGE:-vllm/vllm-openai:v0.29.0}" \
        -c 'mv -T "$1" "$2"' _ "$1" "$2" 2>/dev/null
}
rm_tree() {     # rm_tree <abs path>
    [ -n "${1:-}" ] || return 0
    docker run --rm \
        -v "$LOCAL_HF:$LOCAL_HF" \
        -v "$MODEL_STORE_DIR:$MODEL_STORE_DIR" \
        --entrypoint sh "${VLLM_IMAGE:-vllm/vllm-openai:v0.29.0}" \
        -c 'rm -rf "$1"' _ "$1" >/dev/null 2>&1
}

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'

# ── profile-aware environment ────────────────────────────────────────────────
# An HF_HOME already exported by the caller WINS over the profile's. Sourcing
# the profile files would otherwise clobber it, and there are two real reasons
# to point this at a different cache: verifying a store copy without touching
# the cache a running engine is reading from, and staging models for a box
# whose disk is mounted elsewhere.
_HF_HOME_OVERRIDE="${HF_HOME:-}"

load_env() {
    set -a
    local f
    for f in $("$_DIR/profile-files.sh" 2>/dev/null); do . "$f" 2>/dev/null; done
    set +a
    [ -n "$_HF_HOME_OVERRIDE" ] && HF_HOME="$_HF_HOME_OVERRIDE"
    # HF_HOME in a profile is relative to the repo root (it is a compose bind
    # mount source). Resolve it here so the script can be run from anywhere.
    local h="${HF_HOME:-./data/huggingface}"
    case "$h" in /*) LOCAL_HF="$h" ;; *) LOCAL_HF="$PROJECT_ROOT/${h#./}" ;; esac
    LOCAL_HUB="$LOCAL_HF/hub"
}

# repo id -> hub directory name, huggingface_hub's own rule: ONLY the slash
# becomes `--`. Hyphens inside the org or the name are left alone —
# BAAI/bge-reranker-v2-m3 is models--BAAI--bge-reranker-v2-m3, not
# models--BAAI--bge--reranker--v2--m3. Getting this wrong yields a directory
# name nothing looks for, so the cache silently never hits.
repo_dir() { printf 'models--%s' "${1//\//--}"; }

# Every model the ACTIVE profile will actually ask for. Parsed from the same
# variables compose reads, so this cannot drift from what starts.
needed_models() {
    local m
    [ "${ENABLE_VLLM:-false}"  = "true" ] && m="${VLLM_MODEL:-}"  && [ -n "$m" ] && printf '%s\n' "$m"
    [ "${ENABLE_VLLM2:-false}" = "true" ] && m="${VLLM2_MODEL:-}" && [ -n "$m" ] && printf '%s\n' "$m"
    [ "${ENABLE_VLLM3:-false}" = "true" ] && m="${VLLM3_MODEL:-}" && [ -n "$m" ] && printf '%s\n' "$m"
    # Infinity takes its models as repeated --model-id flags inside one string.
    if [ "${ENABLE_INFINITY:-false}" = "true" ]; then
        printf '%s\n' "${INFINITY_CMD:-}" | tr ' ' '\n' | grep -A1 -x -- '--model-id' | grep -vx -- '--model-id' | grep -v '^--$' | grep -v '^$'
    fi
    [ "${ENABLE_EMBEDDINGS:-false}" = "true" ] && m="${EMBEDDINGS_MODEL:-}" && [ -n "$m" ] && printf '%s\n' "$m"
    return 0
}

# A cache entry is usable only if the download actually finished. `.incomplete`
# files are huggingface_hub's own partial-download marker, and refs/main is what
# resolves a repo id to a snapshot — a directory with blobs but no ref is the
# shape an interrupted download leaves behind, and vLLM would re-download it.
cache_complete() {
    local d="$1"
    [ -d "$d" ] || return 1
    [ -s "$d/refs/main" ] || return 1
    ! find "$d" -name '*.incomplete' -print -quit | grep -q . || return 1
    local sha; sha="$(cat "$d/refs/main")"
    [ -d "$d/snapshots/$sha" ] || return 1
    # A snapshot is symlinks into ../../blobs; a dangling one means the blob was
    # never written, which `du` and a file count both report as fine.
    ! find "$d/snapshots/$sha" -xtype l -print -quit | grep -q . || return 1
    return 0
}

store_enabled() {
    [ -n "$MODEL_STORE_DIR" ] || return 1
    [ -d "$MODEL_STORE_DIR" ] || return 1
    return 0
}

# ── fetch: store -> local cache ──────────────────────────────────────────────
fetch_one() {
    local repo="$1" d; d="$(repo_dir "$repo")"
    local src="$MODEL_STORE_DIR/hub/$d" dst="$LOCAL_HUB/$d"
    cache_complete "$src" || return 2          # not in the store (or half-written there)
    mkdir -p "$LOCAL_HUB" || return 1
    local stage="$LOCAL_HUB/.staging-$d.$$"
    rm_tree "$stage"
    # -a keeps the snapshot's relative symlinks as symlinks; copying them as
    # files would double the size and break HF's blob de-duplication.
    if ! copy_tree "$src" "$stage"; then
        printf "  ${RED}x${RST} %s: copy from the store failed\n" "$repo"
        rm_tree "$stage"; return 1
    fi
    if ! cache_complete "$stage"; then
        printf "  ${RED}x${RST} %s copied from the store but is incomplete — discarding\n" "$repo"
        rm_tree "$stage"; return 1
    fi
    rm_tree "$dst"
    move_tree "$stage" "$dst" || { rm_tree "$stage"; return 1; }
    return 0
}

# ── publish: local cache -> store ────────────────────────────────────────────
publish_one() {
    local repo="$1" d; d="$(repo_dir "$repo")"
    local src="$LOCAL_HUB/$d" dst="$MODEL_STORE_DIR/hub/$d"
    if ! cache_complete "$src"; then
        printf "  ${YEL}!${RST} %s is not completely cached locally — nothing to publish\n" "$repo"
        return 1
    fi
    if cache_complete "$dst"; then
        printf "  ${DIM}= %s already in the store${RST}\n" "$repo"
        return 0
    fi
    mkdir -p "$MODEL_STORE_DIR/hub" || return 1
    # Stage INSIDE the store so the finishing move is a rename on one
    # filesystem, not a copy across a mount boundary — a cross-device `mv`
    # falls back to copy+delete, which is neither atomic nor cheap at 23 GB.
    local stage="$MODEL_STORE_DIR/hub/.staging-$d.$(hostname -s).$$"
    rm_tree "$stage"
    if ! copy_tree "$src" "$stage"; then
        printf "  ${RED}x${RST} %s: copy to the store failed — store left unchanged\n" "$repo"
        rm_tree "$stage"; return 1
    fi
    if ! cache_complete "$stage"; then
        printf "  ${RED}x${RST} %s staged to the store but is incomplete — discarding\n" "$repo"
        rm_tree "$stage"; return 1
    fi
    if move_tree "$stage" "$dst"; then
        printf "  ${GRN}+${RST} published %s\n" "$repo"
        return 0
    fi
    # mv onto a non-empty directory fails — which is how another box publishing
    # the same model mid-copy shows up, and that is a success.
    #
    # But DO NOT read every mv failure that way. A full filesystem or a dropped
    # mount fails here too, and reporting those as "another host won" would
    # announce a store that does not contain the model as if it did — the next
    # box would then silently fall back to a 37-minute download with nothing in
    # the log explaining why. Only a complete destination proves the race story.
    if cache_complete "$dst"; then
        rm_tree "$stage"
        printf "  ${DIM}= %s was published by another host while copying${RST}\n" "$repo"
        return 0
    fi
    printf "  ${RED}x${RST} %s: could not move the staged copy into place, and the\n" "$repo"
    printf "      destination is not complete either. Staging kept for inspection:\n        %s\n" "$stage"
    return 1
}

# ── sync: make sure everything the profile needs is cached locally ───────────
cmd_sync() {
    load_env
    local models; models="$(needed_models | sort -u)"
    [ -n "$models" ] || { printf "  ${DIM}profile names no models${RST}\n"; return 0; }
    if ! store_enabled; then
        printf "  ${YEL}!${RST} model store %s not present — models will come from Hugging Face\n" \
            "${MODEL_STORE_DIR:-<disabled>}"
    fi
    local repo d rc=0
    while read -r repo; do
        [ -n "$repo" ] || continue
        d="$(repo_dir "$repo")"
        if cache_complete "$LOCAL_HUB/$d"; then
            printf "  ${GRN}ok${RST}   %s ${DIM}(already local)${RST}\n" "$repo"
            store_enabled && ! cache_complete "$MODEL_STORE_DIR/hub/$d" && publish_one "$repo"
            continue
        fi
        if store_enabled && cache_complete "$MODEL_STORE_DIR/hub/$d"; then
            printf "  ${BLD}<-${RST}   %s ${DIM}(from the store)${RST}\n" "$repo"
            if fetch_one "$repo"; then continue; fi
            printf "  ${YEL}!${RST} store copy failed, falling back to Hugging Face\n"
        fi
        printf "  ${BLD}..${RST}   %s ${DIM}(downloading from Hugging Face)${RST}\n" "$repo"
        if download_one "$repo"; then
            store_enabled && publish_one "$repo"
        else
            printf "  ${RED}x${RST}   %s FAILED to download\n" "$repo"; rc=1
        fi
    done <<< "$models"
    return $rc
}

# Download with the vLLM image's own huggingface_hub, so this script needs no
# Python packages on the host — the boxes do not have huggingface-cli and
# installing it on each is one more thing to drift.
download_one() {
    local repo="$1"
    local img="${VLLM_IMAGE:-vllm/vllm-openai:v0.29.0}"
    docker run --rm \
        -v "$LOCAL_HF:/root/.cache/huggingface" \
        ${HF_TOKEN:+-e HF_TOKEN="$HF_TOKEN"} \
        --entrypoint python3 "$img" \
        -c "from huggingface_hub import snapshot_download; snapshot_download('$repo', max_workers=8)" >/dev/null 2>&1
}

cmd_status() {
    load_env
    printf "${BLD}model store${RST}  %s\n" "${MODEL_STORE_DIR:-<disabled>}"
    store_enabled && printf "  ${GRN}reachable${RST}, %s free\n" "$(df -h "$MODEL_STORE_DIR" 2>/dev/null | awk 'NR==2{print $4}')" \
                  || printf "  ${YEL}not present${RST} — every model would come from Hugging Face\n"
    printf "${BLD}local cache${RST}  %s\n\n" "$LOCAL_HUB"
    printf "  %-46s %-9s %s\n" "MODEL" "LOCAL" "STORE"
    local repo d l s
    while read -r repo; do
        [ -n "$repo" ] || continue
        d="$(repo_dir "$repo")"
        cache_complete "$LOCAL_HUB/$d" && l="${GRN}yes${RST}" || l="${DIM}no${RST}"
        if store_enabled; then
            cache_complete "$MODEL_STORE_DIR/hub/$d" && s="${GRN}yes${RST}" || s="${YEL}no${RST}"
        else s="${DIM}-${RST}"; fi
        printf "  %-46s %-20b %b\n" "$repo" "$l" "$s"
    done <<< "$(needed_models | sort -u)"
}

cmd_list() {
    load_env
    store_enabled || { printf "${YEL}store %s not present${RST}\n" "${MODEL_STORE_DIR:-<disabled>}"; return 1; }
    printf "${BLD}%s/hub${RST}\n" "$MODEL_STORE_DIR"
    local d n
    shopt -s nullglob
    for d in "$MODEL_STORE_DIR"/hub/models--*; do
        n="$(basename "$d")"; n="${n#models--}"
        # Reverse repo_dir: the LAST `--` separates org from name.
        printf "  %-46s %-7s %s\n" "${n/--//}" "$(du -sh "$d" 2>/dev/null | cut -f1)" \
            "$(cache_complete "$d" && echo "" || echo "${RED}INCOMPLETE${RST}")"
    done
    shopt -u nullglob
}

case "${1:-status}" in
    sync)    cmd_sync ;;
    status)  cmd_status ;;
    list)    cmd_list ;;
    publish) load_env; shift; for r in "$@"; do publish_one "$r"; done ;;
    fetch)   load_env; shift; for r in "$@"; do fetch_one "$r" || printf "  ${RED}x${RST} %s not in the store\n" "$r"; done ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \?//'
       printf "\nUsage: %s {sync|status|list|publish <repo>...|fetch <repo>...}\n" "$(basename "$0")" ;;
esac
