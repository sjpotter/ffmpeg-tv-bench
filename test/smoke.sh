#!/bin/bash
# Smoke test: runs android/tv_bench.sh against the fake adb in test/fake-adb with
# stub "ffmpeg" binaries and a tiny synthetic corpus. No device, no real video and
# no real ffmpeg are involved; it checks the harness logic (config loading,
# verify/bench phases, CSV and summary output, settings save/restore).
#
# Usage: test/smoke.sh        (exit status 0 = pass)
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vc1-smoke.XXXXXX")
trap 'rm -rf "$T"' EXIT

C=$T/corpus
mkdir -p "$C/clips" "$C/ref" "$C/config" "$T/bin" "$T/dev"

# Synthetic corpus: two fake clips, each with a 10-frame reference framemd5.
for clip in SampleA_peak_0 SampleA_calm_10; do
    head -c 4096 /dev/zero > "$C/clips/$clip.mkv"
    {
        echo "#format: frame checksums"
        echo "#version: 2"
        echo "#tb 0: 1001/24000"
        for i in 0 1 2 3 4 5 6 7 8 9; do
            echo "0, $i, $i, 1, 3110400, 0123456789abcdef0123456789abcd$(printf %02x "$i")"
        done
    } > "$C/ref/$clip.framemd5"
done
cat > "$C/manifest.csv" <<'EOF'
clip,title,source_path,container,start_s,duration_s,kind,interlace,fps,frames,progressive_pics,frame_interlaced_pics,field_interlaced_pics,slices_per_pic,avg_mbps,decode_errors,framemd5_file
SampleA_peak_0.mkv,SampleA,-,mkv,0,1,peak,progressive (INTERLACE=0),24000/1001,10,10,0,0,1.0,1.0,0,ref/SampleA_peak_0.framemd5
SampleA_calm_10.mkv,SampleA,-,mkv,10,1,calm,progressive (INTERLACE=0),24000/1001,10,10,0,0,1.0,1.0,0,ref/SampleA_calm_10.framemd5
EOF
cat > "$C/config/clips.default" <<'EOF'
default SampleA_peak
smoke SampleA_calm
EOF

# Stub ffmpeg: prints a version, emits the reference framemd5 for the clip given
# with -i (verify) or bench lines on stderr (bench). Anything else is an error.
cat > "$T/stub" <<'EOF'
#!/bin/bash
REF=${STUB_REF:?}
clip= out= mode=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
    -version) echo "ffmpeg version stub"; exit 0 ;;
    -i) clip=${args[i+1]} ;;
    -f) mode=${args[i+1]}; out=${args[${#args[@]}-1]} ;;
    -frames:v) frames=${args[i+1]} ;;
    esac
done
n=$(basename "$clip"); n=${n%.*}
case $mode in
framemd5) cp "$REF/$n.framemd5" "$out" ;;
null) echo "bench: utime=1.000s stime=0.100s rtime=1.100s" >&2
      echo "bench: maxrss=1000KiB" >&2 ;;
*) echo "stub: unsupported $mode" >&2; exit 1 ;;
esac
EOF
for v in base threaded; do
    cp "$T/stub" "$T/bin/ffmpeg-$v-armeabi-v7a"; chmod +x "$T/bin/ffmpeg-$v-armeabi-v7a"
    echo "0000000000000000000000000000000000000000" > "$T/bin/ffmpeg-$v-armeabi-v7a.commit"
done

export PATH="$REPO/test/fake-adb:$PATH"
export FAKE_ADB_ROOT=$T/dev STUB_REF=$C/ref
export CORPUS=$C VC1_BIN=$T/bin VC1_CLIPS_DEFAULT=$C/config/clips.default VC1_LOCAL_ENV=/dev/null
unset BASE_VARIANT THREADED_VARIANT DEFAULT_VARIANTS SINGLE_VARIANTS COMPARE_PAIRS DEFAULT_CLIPS SMOKE_CLIP

fail=0
check() { if "$@"; then echo "PASS: $*"; else echo "FAIL: $*"; fail=1; return 1; fi; }

echo "== dry run"
rc=0
"$REPO/android/tv_bench.sh" --dry-run --yes -s fakehost:5555 --no-smoke --runs 1 \
    --out "$T/dry" > "$T/dry.out" 2>&1 || rc=$?
check test "$rc" = 0 || tail -20 "$T/dry.out"

echo "== run against fake adb"
rc=0
"$REPO/android/tv_bench.sh" --yes -s fakehost:5555 --runs 1 --threads '1 2' \
    --verify-threads '1 2' --cooldown 0 --out "$T/res" > "$T/run.out" 2>&1 || rc=$?
check test "$rc" = 0 || tail -30 "$T/run.out"
if [ -f "$T/res/verify.csv" ]; then
    cat "$T/res/verify.csv"
    check test "$(tail -n +2 "$T/res/verify.csv" | awk -F, '$7 != "match"' | wc -l | tr -d ' ')" = 0
    check test -s "$T/res/summary.md"
else
    echo "FAIL: no verify.csv"; fail=1
fi
check grep -q "Smoke test: PASS" "$T/run.out" || true
check grep -q "settings restored" "$T/run.out" || true
[ "$fail" = 0 ] && echo "SMOKE TEST PASSED" || { echo "SMOKE TEST FAILED"; exit 1; }
