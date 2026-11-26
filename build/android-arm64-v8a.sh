#!/bin/bash
# Build the reduced VC-1 ffmpeg CLI for Android arm64-v8a.
#
# Usage: build/android-arm64-v8a.sh <ffmpeg-worktree-dir> <variant> [outdir]
# Output: <outdir>/ffmpeg-<variant>-arm64-v8a (+ .commit); outdir defaults to android/bin.
# Prerequisites: macOS host, Android NDK (ANDROID_NDK_HOME, with the LLVM
#   toolchain under toolchains/llvm/prebuilt/darwin-x86_64), git, make.
#   Optional: ANDROID_API (default 26), BUILD_ROOT (scratch directory).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/common.sh
. "$HERE/common.sh"
[ $# -ge 2 ] || build_usage "$0"
android_toolchain
build_ffmpeg arm64-v8a "$TC/bin/llvm-strip" "$1" "$2" "${3:-$BUILD_REPO/android/bin}" \
    --target-os=android --arch=aarch64 --cpu=armv8-a \
    --enable-cross-compile --cross-prefix="$TC/bin/llvm-" \
    --cc="$TC/bin/aarch64-linux-android$API-clang" \
    --cxx="$TC/bin/aarch64-linux-android$API-clang++" \
    --ar="$TC/bin/llvm-ar" --nm="$TC/bin/llvm-nm" \
    --ranlib="$TC/bin/llvm-ranlib" --strip="$TC/bin/llvm-strip" \
    --sysroot="$TC/sysroot"
