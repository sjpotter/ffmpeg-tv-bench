#!/bin/bash
# Build the same reduced VC-1 ffmpeg component set for macOS (used for the
# reference decodes, `--local` runs and local targets).
#
# Usage: build/macos.sh <ffmpeg-worktree-dir> <variant> [outdir]
# Output: <outdir>/ffmpeg-<variant>-macos (+ .commit); outdir defaults to android/bin.
# Prerequisites: macOS with Xcode command line tools (clang, make, strip), git.
#   Optional: BUILD_ROOT (scratch directory).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/common.sh
. "$HERE/common.sh"
[ $# -ge 2 ] || build_usage "$0"
# strip has no -o form on macOS: copy first, then strip in place.
macos_strip() { [ "$1" = -o ] && { cp "$3" "$2" && strip "$2"; }; }
build_ffmpeg macos macos_strip "$1" "$2" "${3:-$BUILD_REPO/android/bin}"
