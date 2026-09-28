#!/usr/bin/env bash
# Tests for scripts/model-store.sh.
#
# WHY THIS EXISTS. A host's .env can pin Infinity to exact snapshots —
# `--model-id /app/.cache/hub/models--BAAI--bge-m3/snapshots/<sha>` — and
# needed_models passed that container path on as if it were a repo id. sync
# then looked for a cache dir named after the path, found none, and tried to
# snapshot_download() the path itself: every `make setup` printed
# "FAILED to download" for two models that were complete on disk.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0; fail=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

SHA_MAIN=1111111111111111111111111111111111111111
SHA_PIN=2222222222222222222222222222222222222222

# A complete HF cache entry: refs/main -> SHA_MAIN, plus a second snapshot.
mk_cache() {
    local d="$1/models--BAAI--bge-m3"
    mkdir -p "$d/refs" "$d/blobs" "$d/snapshots/$SHA_MAIN" "$d/snapshots/$SHA_PIN"
    printf '%s' "$SHA_MAIN" > "$d/refs/main"
    echo w > "$d/blobs/abc"
    ln -s ../../blobs/abc "$d/snapshots/$SHA_MAIN/model.safetensors"
    ln -s ../../blobs/abc "$d/snapshots/$SHA_PIN/model.safetensors"
}
mk_cache "$FIX/hub"

# Source the script's functions only (no subcommand runs when sourced).
run() {
    ( . "$REPO_ROOT/scripts/model-store.sh"
      ENABLE_VLLM=false; ENABLE_VLLM2=false; ENABLE_VLLM3=false; ENABLE_EMBEDDINGS=false
      ENABLE_INFINITY=true
      eval "$1" )
}

echo "needed_models"
is "a repo id passes through unchanged" \
   "BAAI/bge-m3" \
   "$(run 'INFINITY_CMD="v2 --model-id BAAI/bge-m3 --port 7997"; needed_models')"
is "a pinned snapshot path becomes repo@revision" \
   "BAAI/bge-m3@$SHA_PIN" \
   "$(run "INFINITY_CMD='v2 --model-id /app/.cache/hub/models--BAAI--bge-m3/snapshots/$SHA_PIN --port 7997'; needed_models")"
is "a hyphenated repo name survives the reverse mapping" \
   "BAAI/bge-reranker-v2-m3@$SHA_PIN" \
   "$(run "INFINITY_CMD='v2 --model-id /app/.cache/hub/models--BAAI--bge-reranker-v2-m3/snapshots/$SHA_PIN'; needed_models")"

echo "cache_complete"
d="$FIX/hub/models--BAAI--bge-m3"
is "no revision: complete via refs/main"          "yes" "$(run "cache_complete '$d' && echo yes || echo no")"
is "pinned revision present: complete"            "yes" "$(run "cache_complete '$d' $SHA_PIN && echo yes || echo no")"
is "pinned revision absent: incomplete"           "no"  "$(run "cache_complete '$d' 3333333333333333333333333333333333333333 && echo yes || echo no")"

echo "cmd_sync"
out="$(run "
    load_env() { LOCAL_HF='$FIX'; LOCAL_HUB='$FIX/hub'; MODEL_STORE_DIR=''; }
    download_one() { echo \"DOWNLOAD \$*\"; }
    INFINITY_CMD='v2 --model-id /app/.cache/hub/models--BAAI--bge-m3/snapshots/$SHA_PIN'
    cmd_sync" 2>&1)"
case "$out" in *DOWNLOAD*|*FAILED*) got=downloaded ;; *"already local"*) got=local ;; *) got="$out" ;; esac
is "a pinned snapshot already on disk is reported local, not downloaded" "local" "$got"

out="$(run "
    load_env() { LOCAL_HF='$FIX'; LOCAL_HUB='$FIX/hub'; MODEL_STORE_DIR=''; }
    download_one() { echo \"DOWNLOAD \$*\"; }
    INFINITY_CMD='v2 --model-id /app/.cache/hub/models--BAAI--bge-m3/snapshots/4444444444444444444444444444444444444444'
    cmd_sync" 2>&1)"
case "$out" in *"DOWNLOAD BAAI/bge-m3 4444444444444444444444444444444444444444"*) got=pinned ;; *) got="$out" ;; esac
is "a missing pinned snapshot downloads that exact revision" "pinned" "$got"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
