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
# Env: ANDROID_NDK_HOME (required for the Android targets), FFMPEG_WORKTREES,
#      ANDROID_API (default 26)
# Output: bin/ffmpeg-<variant>-<target> (+ .commit) next to this script.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
NDK=${ANDROID_NDK_HOME:-}
API=${ANDROID_API:-26}
TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64
JOBS=$(sysctl -n hw.ncpu)

# Variant name -> source tree. An explicit NAME=/path/to/worktree argument wins;
# otherwise the tree is ${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/NAME.
# NAME=PATH arguments are collected in OVERRIDES, one "name=path" per line.
OVERRIDES=
src_for() {
    local name path
    while IFS='=' read -r name path; do
        [ "$name" = "$1" ] && { echo "$path"; return; }
    done < <(printf '%s\n' "$OVERRIDES")
    echo "${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/$1"
}

COMMON="--disable-doc --disable-debug --disable-ffplay --disable-ffprobe
 --disable-network --disable-autodetect --disable-everything
 --enable-pic --disable-shared --enable-static
 --enable-decoder=vc1,wmv3 --enable-parser=vc1
 --enable-demuxer=mpegts,matroska,vc1 --enable-muxer=null,framemd5
 --enable-encoder=rawvideo,wrapped_avframe --enable-protocol=file,pipe
 --enable-filter=null,format,buffer,buffersink,scale
 --enable-bsf=extract_extradata --enable-swscale --enable-pthreads"

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
[ ${#variants[@]} -eq 0 ] && variants=(base threaded)
[ ${#targets[@]} -eq 0 ] && targets=(armeabi-v7a arm64-v8a macos)

needs_ndk=0
for t in "${targets[@]}"; do [ "$t" = macos ] || needs_ndk=1; done
if [ $needs_ndk = 1 ] && [ ! -d "$TC/bin" ]; then
    echo "build_android.sh: set ANDROID_NDK_HOME to an Android NDK (looked for $TC/bin)" >&2
    exit 1
fi

mkdir -p "$HERE/bin"
for v in "${variants[@]}"; do
    src=$(src_for "$v")
    [ -x "$src/configure" ] || { echo "build_android.sh: $src is not an ffmpeg source tree (variant $v)" >&2; exit 1; }
    for t in "${targets[@]}"; do
        bdir=$HERE/build/$v-$t
        mkdir -p "$bdir"
        case $t in
        armeabi-v7a)
            extra="--target-os=android --arch=arm --cpu=armv7-a --enable-neon
             --enable-cross-compile --cross-prefix=$TC/bin/llvm-
             --cc=$TC/bin/armv7a-linux-androideabi$API-clang
             --cxx=$TC/bin/armv7a-linux-androideabi$API-clang++
             --ar=$TC/bin/llvm-ar --nm=$TC/bin/llvm-nm
             --ranlib=$TC/bin/llvm-ranlib --strip=$TC/bin/llvm-strip
             --sysroot=$TC/sysroot" ;;
        arm64-v8a)
            extra="--target-os=android --arch=aarch64 --cpu=armv8-a
             --enable-cross-compile --cross-prefix=$TC/bin/llvm-
             --cc=$TC/bin/aarch64-linux-android$API-clang
             --cxx=$TC/bin/aarch64-linux-android$API-clang++
             --ar=$TC/bin/llvm-ar --nm=$TC/bin/llvm-nm
             --ranlib=$TC/bin/llvm-ranlib --strip=$TC/bin/llvm-strip
             --sysroot=$TC/sysroot" ;;
        macos) extra="" ;;
        *) echo "unknown target $t" >&2; exit 1 ;;
        esac
        echo "=== $v-$t ($src @ $(git -C "$src" rev-parse --short HEAD))"
        # Start clean when the build dir was configured from another tree.
        if [ "$(cat "$bdir/.src" 2>/dev/null)" != "$src" ]; then
            rm -rf "$bdir"
            mkdir -p "$bdir"
            echo "$src" > "$bdir/.src"
        fi
        (
            cd "$bdir"
            # shellcheck disable=SC2086
            "$src/configure" $COMMON $extra > configure.log 2>&1 ||
                { tail -20 configure.log; exit 1; }
            make -j"$JOBS" ffmpeg > make.log 2>&1 || { tail -30 make.log; exit 1; }
        )
        out=$HERE/bin/ffmpeg-$v-$t
        if [ "$t" = macos ]; then
            cp "$bdir/ffmpeg" "$out"
            strip "$out"
        else
            "$TC/bin/llvm-strip" -o "$out" "$bdir/ffmpeg"
        fi
        git -C "$src" rev-parse HEAD > "$out.commit"
        file "$out"
        ls -la "$out"
    done
done
