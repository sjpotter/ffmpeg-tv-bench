# shellcheck shell=bash
# Shared by build/*.sh: the build driver (configure flags come from config/configure-flags).
# Not run directly. See the header of each build/<name>.sh for prerequisites.
#
# Contract of every build/<name>.sh:
#   build/<name>.sh <ffmpeg-worktree-dir> <variant> [outdir]
#   -> <outdir>/ffmpeg-<variant>-<arch> and <outdir>/ffmpeg-<variant>-<arch>.commit
#   outdir defaults to android/bin (the directory tv_bench.sh reads; VC1_BIN
#   overrides it there). Scratch build trees go to ${BUILD_ROOT:-android/build}/<variant>-<arch>.

BUILD_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ./configure flags common to all builds come from config/configure-flags (git-ignored;
# VC1_CONFIGURE_FLAGS overrides the path). If it does not exist the committed
# default config/configure-flags.example is used. '#' comments and newlines are
# stripped. Result: CONFIGURE_FLAGS.
load_configure_flags() {
    local f=${VC1_CONFIGURE_FLAGS:-$BUILD_REPO/config/configure-flags}
    if [ ! -f "$f" ]; then
        if [ -n "${VC1_CONFIGURE_FLAGS:-}" ]; then
            echo "VC1_CONFIGURE_FLAGS=$f does not exist" >&2; exit 1
        fi
        f=$BUILD_REPO/config/configure-flags.example
        echo "note: config/configure-flags not found, using $f" >&2
    fi
    CONFIGURE_FLAGS=$(sed 's/#.*//' "$f" | tr '\n' ' ')
    [ -n "${CONFIGURE_FLAGS// /}" ] || { echo "$f contains no configure flags" >&2; exit 1; }
}

build_usage() { echo "usage: $1 <ffmpeg-worktree-dir> <variant> [outdir]" >&2; exit 2; }

# build_ffmpeg ARCH STRIP_CMD SRC VARIANT OUTDIR [configure flags...]
#   STRIP_CMD is run as: STRIP_CMD -o OUT BUILT_BINARY
build_ffmpeg() {
    local arch=$1 strip_cmd=$2 src=$3 v=$4 outdir=$5 bdir out
    shift 5
    load_configure_flags
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
        "$src/configure" $CONFIGURE_FLAGS "$@" > configure.log 2>&1 ||
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
