#!/bin/sh
# Generate reference framemd5 files with a baseline (single-threaded) ffmpeg.
# Usage: tools/make_refs.sh [CLIP...]   (default: all clips in $CORPUS/clips)
# Env:   CORPUS  corpus directory (default: repo root); needs clips/ and ref/
#        FFMPEG  baseline ffmpeg binary (default: $CORPUS/baseline-build/ffmpeg)
#        JOBS    parallel decodes (default 6)
ROOT=${CORPUS:-$(cd "$(dirname "$0")/.." && pwd)}
FFMPEG=${FFMPEG:-$ROOT/baseline-build/ffmpeg}
[ -x "$FFMPEG" ] || { echo "make_refs.sh: FFMPEG ($FFMPEG) is not executable" >&2; exit 1; }
cd "$ROOT" || exit 1
mkdir -p ref
[ $# -gt 0 ] || set -- clips/*
for c in "$@"; do
    printf '%s\0' "$c"
done | xargs -0 -P "${JOBS:-6}" -I{} sh -c '
    n=$(basename "{}"); n=${n%.*}
    "$0" -nostdin -v error -threads 1 -i "{}" -map 0:v:0 -f framemd5 "ref/$n.framemd5" 2> "ref/$n.errors.txt"
    echo "$n exit=$?"' "$FFMPEG"
