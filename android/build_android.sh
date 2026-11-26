#!/bin/bash
# Build the minimal VC-1 ffmpeg CLI for Android (armeabi-v7a, arm64-v8a) and
# the same component set for macOS (to prove the reduced set decodes).
#
# Usage: build_android.sh [variant|variant=/path/to/worktree ...] [-- target ...]
#   variants: any name; built from ${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/<name>
#             unless NAME=PATH is given. tv_bench.sh expects "base" (single-threaded
#             reference) and "threaded" by default, e.g.
#               build_android.sh base=$HOME/src/ffmpeg-base threaded=$HOME/src/ffmpeg-mt
#   targets:  armeabi-v7a arm64-v8a macos (default all)
# Local files: config/worktrees (name=path map), config/local.env (DEFAULT_VARIANTS).
# Env: ANDROID_NDK_HOME (required for the Android targets), FFMPEG_WORKTREES,
#      ANDROID_API (default 26)
# Output: bin/ffmpeg-<variant>-<target> (+ .commit) next to this script.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
NDK=${ANDROID_NDK_HOME:-}
API=${ANDROID_API:-26}
TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64

# Variant name -> source tree. An explicit NAME=/path/to/worktree argument wins;
# otherwise the tree is ${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/NAME.
# NAME=PATH arguments are collected in OVERRIDES, one "name=path" per line.
OVERRIDES=
# Optional local map (git-ignored), "name=path" per line, '#' comments, $HOME
# expanded; command-line NAME=PATH arguments win over it.
WORKTREE_MAP=${VC1_WORKTREE_MAP:-$HERE/../config/worktrees}
MAP_LINES=
[ -f "$WORKTREE_MAP" ] && MAP_LINES=$(grep -v '^[[:space:]]*#' "$WORKTREE_MAP" | grep = | sed "s|\$HOME|$HOME|g; s|\${HOME}|$HOME|g")
LOCAL_ENV=${VC1_LOCAL_ENV:-$HERE/../config/local.env}
# shellcheck disable=SC1090
[ -f "$LOCAL_ENV" ] && . "$LOCAL_ENV"
src_for() {
    local name path
    while IFS='=' read -r name path; do
        [ "$name" = "$1" ] && { echo "$path"; return; }
    done < <(printf '%s\n%s\n' "$OVERRIDES" "$MAP_LINES")
    echo "${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/$1"
}

variants=()
targets=()
while [ $# -gt 0 ]; do
    [ "$1" = "--" ] && { shift; targets=("$@"); break; }
    case $1 in
    *=*) OVERRIDES="$OVERRIDES
$1"; variants+=("${1%%=*}") ;;
    *) variants+=("$1") ;;
    esac
    shift
done
[ ${#variants[@]} -eq 0 ] && read -r -a variants <<< "${DEFAULT_VARIANTS:-base threaded}"
[ ${#targets[@]} -eq 0 ] && targets=(armeabi-v7a arm64-v8a macos)

needs_ndk=0
for t in "${targets[@]}"; do [ "$t" = macos ] || needs_ndk=1; done
if [ $needs_ndk = 1 ] && [ ! -d "$TC/bin" ]; then
    echo "build_android.sh: set ANDROID_NDK_HOME to an Android NDK (looked for $TC/bin)" >&2
    exit 1
fi

# The per-architecture build scripts live in build/ (see build/common.sh for the
# contract); this wrapper only resolves variant names to source trees.
mkdir -p "$HERE/bin"
for v in "${variants[@]}"; do
    src=$(src_for "$v")
    [ -x "$src/configure" ] || { echo "build_android.sh: $src is not an ffmpeg source tree (variant $v)" >&2; exit 1; }
    for t in "${targets[@]}"; do
        case $t in
        armeabi-v7a|arm64-v8a) script=android-$t.sh ;;
        macos) script=macos.sh ;;
        *) echo "unknown target $t" >&2; exit 1 ;;
        esac
        "$HERE/../build/$script" "$src" "$v" "$HERE/bin"
    done
done
