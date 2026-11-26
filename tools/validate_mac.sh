#!/bin/bash
# Correctness matrix and speed of a macOS ffmpeg build against ref/.
#
# Usage: validate_mac.sh FFMPEG OUTDIR [verify|bench|both]
# Env:   CORPUS (default: repo root; uses $CORPUS/clips and $CORPUS/ref),
#        THREADS (verify, default "1 2 4 8"), JOBS (parallel decodes, default 4),
#        BENCH_CLIPS (file names in clips/), BENCH_THREADS (default "1 2 4 8"), BENCH_RUNS (default 3)
set -u

FF=$1
OUT=$2
MODE=${3:-both}
CORPUS=${CORPUS:-$(cd "$(dirname "$0")/.." && pwd)}
THREADS=${THREADS:-"1 2 4 8"}
JOBS=${JOBS:-4}
# Default: every "peak" clip found in $CORPUS/clips.
BENCH_CLIPS=${BENCH_CLIPS:-$(cd "$CORPUS/clips" 2>/dev/null && ls | grep '_peak_' | tr '\n' ' ')}
BENCH_THREADS=${BENCH_THREADS:-"1 2 4 8"}
BENCH_RUNS=${BENCH_RUNS:-3}

mkdir -p "$OUT/framemd5" "$OUT/logs"

# compare_framemd5 REF OUT -> prints "status,first_diff_frame,ref_frames,out_frames"
compare_framemd5() {
    if cmp -s "$1" "$2"; then
        n=$(grep -vc '^#' "$1")
        echo "match,,$n,$n"
        return
    fi
    awk '
        FNR == NR { if ($0 !~ /^#/) ref[r++] = $0; next }
        $0 !~ /^#/ { out[o++] = $0 }
        END {
            n = r < o ? r : o
            for (i = 0; i < n; i++) if (ref[i] != out[i]) break
            if (i == n && r == o) printf "header_only,,%d,%d\n", r, o
            else if (i == n) printf "mismatch,%d,%d,%d\n", i, r, o
            else printf "mismatch,%d,%d,%d\n", i, r, o
        }' "$1" "$2"
}

verify_one() {
    clip=$1 n=$2
    name=${clip%.*}
    f=$OUT/framemd5/$name.t$n.framemd5
    err=$OUT/logs/$name.t$n.verify.err
    "$FF" -nostdin -v error -threads "$n" -thread_type frame \
        -i "$CORPUS/clips/$clip" -map 0:v:0 -f framemd5 -y "$f" 2> "$err"
    rc=$?
    res=$(compare_framemd5 "$CORPUS/ref/$name.framemd5" "$f")
    nerr=$(wc -l < "$err" | tr -d ' ')
    echo "$name,$n,$rc,$res,$nerr"
}

if [ "$MODE" = verify ] || [ "$MODE" = both ]; then
    export -f verify_one compare_framemd5
    export FF OUT CORPUS
    csv=$OUT/verify.csv
    echo "clip,threads,exit,status,first_diff_frame,ref_frames,out_frames,stderr_lines" > "$csv"
    for c in $(cd "$CORPUS/clips" && ls); do
        for n in $THREADS; do echo "$c $n"; done
    done | xargs -P "$JOBS" -n 2 bash -c 'verify_one "$0" "$1"' | sort >> "$csv"
fi

if [ "$MODE" = bench ] || [ "$MODE" = both ]; then
    csv=$OUT/bench.csv
    echo "clip,threads,run,utime_s,stime_s,rtime_s,maxrss_kb,frames,fps" > "$csv"
    for c in $BENCH_CLIPS; do
        name=${c%.*}
        frames=$(grep -vc "^#" "$CORPUS/ref/$name.framemd5")
        for n in $BENCH_THREADS; do
            for r in $(seq 1 "$BENCH_RUNS"); do
                log=$OUT/logs/$name.t$n.r$r.bench.err
                "$FF" -nostdin -hide_banner -nostats -benchmark -v info -threads "$n" -thread_type frame \
                    -i "$CORPUS/clips/$c" -map 0:v:0 -f null - > /dev/null 2> "$log"
                # bench: utime=1.234s stime=0.123s rtime=0.456s / bench: maxrss=12345KiB
                awk -v c="$name" -v n="$n" -v r="$r" -v fr="$frames" '
                    /bench: utime=/ {
                        for (i = 1; i <= NF; i++) {
                            split($i, kv, "="); v = kv[2]; sub(/s$/, "", v)
                            if (kv[1] == "utime") u = v
                            if (kv[1] == "stime") s = v
                            if (kv[1] == "rtime") t = v
                        }
                    }
                    /bench: maxrss=/ { split($2, kv, "="); m = kv[2]; sub(/[^0-9]+$/, "", m) }
                    END { printf "%s,%s,%s,%s,%s,%s,%s,%s,%.2f\n", c, n, r, u, s, t, m, fr, (t > 0 ? fr / t : 0) }
                ' "$log" >> "$csv"
            done
        done
    done
fi
