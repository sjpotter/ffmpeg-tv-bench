# shellcheck shell=bash
# Shared by build/*.sh: the reduced ffmpeg component set and the build driver.
# Not run directly. See the header of each build/<name>.sh for prerequisites.
#
# Contract of every build/<name>.sh:
#   build/<name>.sh <ffmpeg-worktree-dir> <variant> [outdir]
#   -> <outdir>/ffmpeg-<variant>-<arch> and <outdir>/ffmpeg-<variant>-<arch>.commit
#   outdir defaults to android/bin (the directory tv_bench.sh reads; VC1_BIN
#   overrides it there). Scratch build trees go to ${BUILD_ROOT:-android/build}/<variant>-<arch>.

BUILD_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Component set that makes the reduced VC-1 ffmpeg CLI build.
VC1_COMMON_FLAGS="--disable-doc --disable-debug --disable-ffplay --disable-ffprobe
 --disable-network --disable-autodetect --disable-everything
 --enable-pic --disable-shared --enable-static
 --enable-decoder=vc1,wmv3 --enable-parser=vc1
 --enable-demuxer=mpegts,matroska,vc1 --enable-muxer=null,framemd5
 --enable-encoder=rawvideo,wrapped_avframe --enable-protocol=file,pipe
 --enable-filter=null,format,buffer,buffersink,scale
 --enable-bsf=extract_extradata --enable-swscale --enable-pthreads"

build_usage() { echo "usage: $1 <ffmpeg-worktree-dir> <variant> [outdir]" >&2; exit 2; }

# build_ffmpeg ARCH STRIP_CMD SRC VARIANT OUTDIR [configure flags...]
#   STRIP_CMD is run as: STRIP_CMD -o OUT BUILT_BINARY
build_ffmpeg() {
    local arch=$1 strip_cmd=$2 src=$3 v=$4 outdir=$5 bdir out
    shift 5
    [ -x "$src/configure" ] || { echo "$src is not an ffmpeg source tree (no configure)" >&2; exit 1; }
    src=$(cd "$src" && pwd)
    bdir=${BUILD_ROOT:-$BUILD_REPO/android/build}/$v-$arch
    mkdir -p "$bdir" "$outdir"
    echo "=== $v-$arch ($src @ $(git -C "$src" rev-parse --short HEAD))"
    # Start clean when the build dir was configured from another tree.
    if [ "$(cat "$bdir/.src" 2>/dev/null)" != "$src" ]; then
        rm -rf "$bdir"
        mkdir -p "$bdir"
        echo "$src" > "$bdir/.src"
    fi
    (
        cd "$bdir"
        # shellcheck disable=SC2086
        "$src/configure" $VC1_COMMON_FLAGS "$@" > configure.log 2>&1 ||
            { tail -20 configure.log; exit 1; }
        make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" ffmpeg > make.log 2>&1 || { tail -30 make.log; exit 1; }
    ) || exit 1
    out=$outdir/ffmpeg-$v-$arch
    "$strip_cmd" -o "$out" "$bdir/ffmpeg"
    git -C "$src" rev-parse HEAD > "$out.commit"
    file "$out"
    ls -la "$out"
}

# android_toolchain: sets NDK, API, TC from ANDROID_NDK_HOME (required).
android_toolchain() {
    NDK=${ANDROID_NDK_HOME:-}
    API=${ANDROID_API:-26}
    TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64
    if [ -z "$NDK" ] || [ ! -d "$TC/bin" ]; then
        echo "set ANDROID_NDK_HOME to an Android NDK (looked for $TC/bin)" >&2
        exit 1
    fi
}
