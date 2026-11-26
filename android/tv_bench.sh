#!/bin/bash
# VC-1 decoder verification and benchmark on an Android TV over adb.
# Runs on the Mac; see README.md next to this script.
#
# Written for the bash 3.2 that ships with macOS: no associative arrays.
# Everything lives in functions and main runs from the last line, so bash has
# parsed the whole file before running anything; editing the script during a
# run can't change what the running copy executes.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CORPUS=${CORPUS:-$(cd "$HERE/.." && pwd)}
# Optional local settings (git-ignored): BASE_VARIANT, THREADED_VARIANT,
# SINGLE_VARIANTS, DEFAULT_VARIANTS, COMPARE_PAIRS, DEFAULT_CLIPS, SMOKE_CLIP...
# Copy config/local.env.example to config/local.env. VC1_LOCAL_ENV overrides the path.
LOCAL_ENV=${VC1_LOCAL_ENV:-$HERE/../config/local.env}
# shellcheck disable=SC1090
[ -f "$LOCAL_ENV" ] && . "$LOCAL_ENV"
BIN=${VC1_BIN:-$HERE/bin}
MANIFEST=$CORPUS/manifest.csv
# Optional per-clip Mac single-thread fps for the run-time estimate
# (CSV: clip,frames,mac_t1_rtime_s,mac_t1_fps). 180 fps is assumed if absent.
COSTS=${CLIP_COSTS:-$CORPUS/clip_cost.csv}

# Which clips make up a normal run and the smoke test comes from a local,
# git-ignored file (copy config/clips.default.example). It is only required
# when --clips is not given (DEFAULT_CLIPS) or the smoke test runs (SMOKE_CLIP).
CLIPS_DEFAULT_FILE=${VC1_CLIPS_DEFAULT:-$(cd "$HERE/.." && pwd)/config/clips.default}
DEFAULT_CLIPS=${DEFAULT_CLIPS:-}
SMOKE_CLIP=${SMOKE_CLIP:-}
load_clip_defaults() {
    local kind rest
    [ -f "$CLIPS_DEFAULT_FILE" ] || return 0
    while read -r kind rest; do
        case $kind in
        default) [ -n "$DEFAULT_CLIPS" ] || DEFAULT_CLIPS=$rest ;;
        smoke) [ -n "$SMOKE_CLIP" ] || SMOKE_CLIP=$rest ;;
        esac
    done < "$CLIPS_DEFAULT_FILE"
}
need_clip_defaults() { # default|smoke
    load_clip_defaults
    case $1 in
    default) [ -n "$DEFAULT_CLIPS" ] && return 0 ;;
    smoke) [ -n "$SMOKE_CLIP" ] && return 0 ;;
    esac
    echo "no $1 clips configured: copy config/clips.default.example to $CLIPS_DEFAULT_FILE" >&2
    echo "  and edit it (or set VC1_CLIPS_DEFAULT, or pass --clips / DEFAULT_CLIPS / SMOKE_CLIP)" >&2
    exit 2
}
# Variant names: BASE_VARIANT is the single-threaded reference (also the one the
# contention test and the "vs base" column use), THREADED_VARIANT the build under
# test (headline table). Override in config/local.env (see below).
BASE_VARIANT=${BASE_VARIANT:-base}
THREADED_VARIANT=${THREADED_VARIANT:-threaded}
SINGLE_VARIANTS=${SINGLE_VARIANTS:-"$BASE_VARIANT single"}
# "A:B" pairs compared side by side in the summary when both variants ran.
COMPARE_PAIRS=${COMPARE_PAIRS:-"single:$BASE_VARIANT"}
NO_RECONNECT=0
SETTINGS_APPLIED=0
SETTINGS_FILE=
SETTINGS_KEYS="global:stay_on_while_plugged_in secure:sleep_timeout secure:screensaver_enabled secure:screensaver_activate_on_sleep system:screen_off_timeout"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Guided by default when stdin is a terminal: checklist, connect, settings
check, smoke test, then the full run. --yes runs unattended.

  --target NAME        use config/targets/NAME.env (VC1_TARGETS_DIR overrides the directory);
                       command-line options override its fields; NO_WAKE=1 there implies --no-wake
  -s SERIAL            ad hoc adb target, e.g. HOST:5555 (adb connect is done for you)
  --yes                no prompts (unattended)
  --smoke              run only the smoke test (the "smoke" clip, both variants, threads 1 and 4)
  --no-smoke           skip the smoke test
  --quick              same matrix as the default with 1 bench run, no smoke test
  --clips 'GLOB ...'   clip name globs or prefixes (default: the 'default' line of config/clips.default); 'all' for every clip
  --threads 'N ...'    bench thread counts for threaded variants (default '1 2 3 4')
  --verify-threads 'N ...'  verify thread counts for threaded variants (default '1 2 4')
  --runs N             bench repetitions (default 3; 1 with --quick)
  --max-frames N       decode only the first N frames of each clip (ffmpeg -frames:v N);
                       fps uses N, verify compares the first N lines of ref/ (default: all)
  --variants 'V ...'   variants (default '$BASE_VARIANT $THREADED_VARIANT'); single-threaded ones
                       ('$SINGLE_VARIANTS') only run 1 thread
  --no-keep-clips      delete each clip from the device after use (default: keep
                       clips for later runs while at least 512 MiB stays free)
  --clear-clips        delete the clips kept on the device, then continue
  --contention N       also run N copies of '$BASE_VARIANT' at 1 thread at once per clip
                       (cache/memory contention test; compared with $BASE_VARIANT alone)
  --abi ABI            force armeabi-v7a or arm64-v8a (default: from ro.product.cpu.abilist)
  --verify-only | --bench-only
  --cooldown S         sleep between bench runs (default 10)
  --timeout S          per-decode limit (default 1800)
  --reconnect-tries N  adb reconnect attempts after a drop (default 6, backoff 5..60 s)
  --slowdown X         TV vs Mac single-thread speed ratio used for estimates (default 11 arm64, 13 armv7)
  --out DIR            results directory (reuse it to resume)
  --resume             reuse the newest results/tv-<model>-* directory
  --force              redo entries that already have results
  --restore-settings FILE   restore TV power settings saved in FILE and exit
  --dry-run            print the adb commands without running them
  --local              run on this Mac with the macOS builds (harness test)
  to pause:           touch $CORPUS/.tv.pause (or \$TV_PAUSE_FILE) to pause before
                       the next decode; remove it to continue
  --no-wake            leave the device asleep: no wake key event, no power
                       settings changes, no picture-off prompt; the power
                       state is only logged (results may be a worst case)
  -h | --help
EOF
}

# ---------------------------------------------------------------------------
# Options

# load_target NAME: read config/targets/NAME.env (VC1_TARGETS_DIR overrides the
# directory) into T_* variables. Fields: TYPE (adb|local), ARCH, BUILD, NOTES,
# SERIAL, DEV_DIR, WORK_DIR, BIN_DIR, NO_WAKE, NO_SMOKE, COOLDOWN, TIMEOUT,
# RECONNECT_TRIES, VARIANTS. Command-line options override them.
load_target() {
    local f=${VC1_TARGETS_DIR:-$HERE/../config/targets}/$1.env k
    if [ ! -f "$f" ]; then
        echo "no target '$1': $f is missing" >&2
        echo "  copy config/targets/<type>.env.example to $f and edit it" >&2
        exit 2
    fi
    for k in TYPE ARCH BUILD NOTES SERIAL DEV_DIR WORK_DIR BIN_DIR NO_WAKE NO_SMOKE COOLDOWN TIMEOUT RECONNECT_TRIES VARIANTS; do unset "$k"; done
    # shellcheck disable=SC1090
    . "$f"
    T_TYPE=${TYPE:-adb} T_ARCH=${ARCH:-} T_BUILD=${BUILD:-} T_NOTES=${NOTES:-}
    T_SERIAL=${SERIAL:-} T_DEV_DIR=${DEV_DIR:-} T_WORK_DIR=${WORK_DIR:-} T_BIN_DIR=${BIN_DIR:-}
    T_NO_WAKE=${NO_WAKE:-} T_NO_SMOKE=${NO_SMOKE:-} T_COOLDOWN=${COOLDOWN:-}
    T_TIMEOUT=${TIMEOUT:-} T_RECONNECT_TRIES=${RECONNECT_TRIES:-} T_VARIANTS=${VARIANTS:-}
    [ -f "$HERE/../lib/target-$T_TYPE.sh" ] || {
        echo "$f: unknown TYPE '$T_TYPE' (no lib/target-$T_TYPE.sh)" >&2; exit 2; }
    for k in TYPE ARCH BUILD NOTES SERIAL DEV_DIR WORK_DIR BIN_DIR NO_WAKE NO_SMOKE COOLDOWN TIMEOUT RECONNECT_TRIES VARIANTS; do unset "$k"; done
}

parse_args() {
    ORIG_ARGS=
    [ $# -gt 0 ] && ORIG_ARGS=$(printf "'%s' " "$@")
    # Target file first (so that command-line options can override its fields).
    TARGET_NAME=
    T_TYPE=adb T_ARCH= T_BUILD= T_NOTES= T_SERIAL= T_DEV_DIR= T_WORK_DIR= T_BIN_DIR=
    T_NO_WAKE= T_NO_SMOKE= T_COOLDOWN= T_TIMEOUT= T_RECONNECT_TRIES= T_VARIANTS=
    local prev=
    for a in "$@"; do
        [ "$prev" = --target ] && TARGET_NAME=$a
        prev=$a
    done
    [ -n "$TARGET_NAME" ] && load_target "$TARGET_NAME"
    SERIAL=$T_SERIAL
    CLIPS_ARG=
    BENCH_THREADS=
    VERIFY_THREADS=
    RUNS=
    MAX_FRAMES=0
    VARIANTS=${T_VARIANTS:-${DEFAULT_VARIANTS:-"$BASE_VARIANT $THREADED_VARIANT"}}
    ABI=
    ABI_FORCED=0
    DO_VERIFY=1
    DO_BENCH=1
    COOLDOWN=${T_COOLDOWN:-10}
    TIMEOUT=${T_TIMEOUT:-1800}
    RECONNECT_TRIES=${T_RECONNECT_TRIES:-6}
    SLOWDOWN=
    OUT=
    RESUME=0
    FORCE=0
    DRY=0
    LOCAL=0
    TARGET_TYPE=$T_TYPE
    YES=0
    SMOKE_ONLY=0
    NO_SMOKE=${T_NO_SMOKE:-0}
    QUICK=0
    CONTENTION=0
    KEEP_CLIPS=1
    CLEAR_CLIPS=0
    NO_WAKE=${T_NO_WAKE:-0}   # NO_WAKE=1 in a target file makes --no-wake implicit
    RESTORE_FILE=

    while [ $# -gt 0 ]; do
        case $1 in
        -s) SERIAL=$2; shift ;;
        --yes|-y) YES=1 ;;
        --smoke) SMOKE_ONLY=1 ;;
        --no-smoke) NO_SMOKE=1 ;;
        --quick) QUICK=1 ;;
        --clips) CLIPS_ARG=$2; shift ;;
        --threads) BENCH_THREADS=$2; shift ;;
        --verify-threads) VERIFY_THREADS=$2; shift ;;
        --runs) RUNS=$2; shift ;;
        --max-frames) MAX_FRAMES=$2; shift ;;
        --variants) VARIANTS=$2; shift ;;
        --contention) CONTENTION=$2; shift ;;
        --no-keep-clips) KEEP_CLIPS=0 ;;
        --clear-clips) CLEAR_CLIPS=1 ;;
        --abi) ABI=$2; ABI_FORCED=1; shift ;;
        --verify-only) DO_BENCH=0 ;;
        --bench-only) DO_VERIFY=0 ;;
        --cooldown) COOLDOWN=$2; shift ;;
        --timeout) TIMEOUT=$2; shift ;;
        --reconnect-tries) RECONNECT_TRIES=$2; shift ;;
        --slowdown) SLOWDOWN=$2; shift ;;
        --out) OUT=$2; shift ;;
        --resume) RESUME=1 ;;
        --force) FORCE=1 ;;
        --restore-settings) RESTORE_FILE=$2; shift ;;
        --dry-run) DRY=1 ;;
        --target) shift ;;   # handled above
        --local) LOCAL=1; TARGET_TYPE=local ;;
        --no-wake) NO_WAKE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    if [ $QUICK = 1 ]; then
        [ -z "$RUNS" ] && RUNS=1
        [ $SMOKE_ONLY = 0 ] && NO_SMOKE=1
    fi
    [ -z "$BENCH_THREADS" ] && BENCH_THREADS="1 2 3 4"
    [ -z "$VERIFY_THREADS" ] && VERIFY_THREADS="1 2 4"
    [ -z "$RUNS" ] && RUNS=3
    case $MAX_FRAMES in ''|*[!0-9]*) die "--max-frames needs a number" ;; esac
    FOPT=
    if [ "$MAX_FRAMES" -gt 0 ]; then FOPT="-frames:v $MAX_FRAMES"; fi
    if [ "$CONTENTION" -gt 1 ]; then
        case " $VARIANTS " in
        *" $BASE_VARIANT "*) ;;
        *) echo "--contention runs '$BASE_VARIANT'; add it to --variants" >&2; exit 2 ;;
        esac
    fi

    INTERACTIVE=0
    [ -t 0 ] && [ $YES = 0 ] && [ $DRY = 0 ] && INTERACTIVE=1

    # Target implementation: transport and device operations live in lib/.
    # shellcheck disable=SC1090
    . "$HERE/../lib/target-$TARGET_TYPE.sh"
    [ -n "$T_BIN_DIR" ] && [ -z "${VC1_BIN:-}" ] && BIN=$T_BIN_DIR
    target_init
    JOB_DIR=$DEV_DIR/jobs
    CLIP_DIR=$DEV_DIR/clips
    KEEP_RESERVE_KB=$((512 * 1024))
    RECONNECT_DELAY=${RECONNECT_DELAY:-5}
}

# ---------------------------------------------------------------------------
# Output helpers

RUNLOG=
ADBLOG=/dev/null

log() {
    line="[$(date +%H:%M:%S)] $*"
    echo "$line" >&2
    [ -n "$RUNLOG" ] && echo "$line" >> "$RUNLOG"
    return 0
}
say() {
    echo "$*" >&2
    [ -n "$RUNLOG" ] && echo "$*" >> "$RUNLOG"
    return 0
}
warn() { log "WARNING: $*"; }
die() { log "ERROR: $*"; exit 1; }

pause() {
    [ $INTERACTIVE = 1 ] || return 0
    printf '%s' "${1:-Press Enter to continue...} " >&2
    read -r _ || true
}

# confirm QUESTION DEFAULT(y|n): non-interactive runs take the default.
confirm() {
    if [ $INTERACTIVE = 0 ]; then [ "$2" = y ]; return; fi
    printf '%s [%s] ' "$1" "$([ "$2" = y ] && echo Y/n || echo y/N)" >&2
    read -r ans || ans=
    [ -z "$ans" ] && ans=$2
    case $ans in [yY]*) return 0 ;; *) return 1 ;; esac
}

fmt_dur() { # seconds -> 1h05m / 12m / 40s
    awk -v s="$1" 'BEGIN { s = int(s + 0.5)
        if (s >= 3600) printf "%dh%02dm", s / 3600, (s % 3600) / 60
        else if (s >= 60) printf "%dm", (s + 30) / 60
        else printf "%ds", s }'
}

# ---------------------------------------------------------------------------
# adb transport

# Between decodes, wait while the pause file exists (touch it to pause after
# the current decode, remove it to continue). No adb traffic while paused.
PAUSE_FILE=${TV_PAUSE_FILE:-$CORPUS/.tv.pause}
wait_if_paused() {
    [ -e "$PAUSE_FILE" ] || return 0
    log "paused: $PAUSE_FILE exists; remove it to continue"
    while [ -e "$PAUSE_FILE" ]; do sleep 10; done
    log "resumed"
    reconnect || die_lost "reconnecting after pause"
}

# ---------------------------------------------------------------------------
# Device probes

THERM_CMD='echo T $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null); echo F $(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null)'

# parse_therm: stdin with T/F lines -> "maxtempC maxcoreMHz" ("na" if unknown)
parse_therm() {
    awk '
        $1 == "T" { for (i = 2; i <= NF; i++) { v = $i; if (v > 1000) v /= 1000; if (v > -50 && (t == "" || v > t)) t = v } }
        $1 == "F" { for (i = 2; i <= NF; i++) { v = int($i / 1000); if (f == "" || v > f) f = v } }
        END { printf "%s %s\n", (t == "" ? "na" : t), (f == "" ? "na" : f) }'
}

dev_thermal() { dsh "$THERM_CMD" | parse_therm; }

# Free KiB on the filesystem holding DEV_DIR, empty if unknown. Toybox
# "df -P" reports 512-byte blocks even with -k, so honour the header.
dev_free_kb() {
    dsh "df -k $DEV_DIR 2>/dev/null || df $DEV_DIR" |
        awk 'NR == 1 { div = ($2 ~ /^512/ ? 2 : 1) }
             NR > 1 && $4 ~ /^[0-9]+$/ { v = int($4 / div) }
             END { if (v != "") print v }'
}

# ---------------------------------------------------------------------------
# TV power settings: save, apply, restore

# ---------------------------------------------------------------------------
# Detached decode jobs: launch on the device, poll for the exit-code file.
# A dropped adb connection only interrupts polling; the decode carries on.

CURRENT_JOB=
JOB_SEQ=0

# run_job LOG CMD: sets RC (exit code, "lost" or "timeout"), JOB_WALL,
# JOB_TEMP_PEAK and JOB_FREQ_MIN (lowest max-core MHz seen while running).
run_job() {
    local logf=$1 cmd=$2 attempt id jf t0 launched status margin st el
    RC= JOB_WALL=0 JOB_TEMP_PEAK=na JOB_FREQ_MIN=na
    if [ $DRY = 1 ]; then
        echo "+ $ADB shell '$SETSID nohup sh $JOB_DIR/<job>.sh &'   job: $cmd" >&2
        RC=0
        return
    fi
    attempt=1
    while :; do
        JOB_SEQ=$((JOB_SEQ + 1))
        id=j$$_$JOB_SEQ
        jf=$JOB_DIR/$id
        mkdir -p "$OUT/.jobs"
        {
            echo "echo \$\$ > $jf.pid"
            echo "$cmd > $jf.log 2>&1"
            echo "echo \$? > $jf.rc.tmp && mv $jf.rc.tmp $jf.rc"
        } > "$OUT/.jobs/$id.sh"
        dpush "$OUT/.jobs/$id.sh" "$jf.sh" || die_lost "pushing job script"
        rm -f "$OUT/.jobs/$id.sh"
        t0=$(date +%s)
        launched=$(dsh "$SETSID nohup sh $jf.sh < /dev/null > /dev/null 2>&1 & echo launched")
        [ $? = 99 ] && die_lost "launching a decode"
        CURRENT_JOB=$jf
        status=
        if [ "$launched" = launched ]; then
            margin=$(( TIMEOUT < 240 ? TIMEOUT / 2 : 120 ))
            while :; do
                sleep "$POLL"
                st=$(dsh "if [ -f $jf.rc ]; then echo RC \$(cat $jf.rc); elif [ ! -f $jf.pid ]; then echo NOPID; elif kill -0 \$(cat $jf.pid) 2>/dev/null; then echo RUNNING; elif [ -f $jf.rc ]; then echo RC \$(cat $jf.rc); else echo GONE; fi; $THERM_CMD")
                if [ $? = 99 ]; then
                    reconnect || die_lost "while a decode was running (it may still finish on the TV)"
                    continue
                fi
                el=$(( $(date +%s) - t0 ))
                case $st in
                RC\ *) RC=$(echo "$st" | sed -n 's/^RC //p' | head -1); status=done ;;
                RUNNING*)
                    set -- $(echo "$st" | parse_therm)
                    if [ "$1" != na ]; then
                        [ "$JOB_TEMP_PEAK" = na ] && JOB_TEMP_PEAK=$1
                        JOB_TEMP_PEAK=$(awk -v a="$JOB_TEMP_PEAK" -v b="$1" 'BEGIN { print (b > a ? b : a) }')
                    fi
                    if [ "$2" != na ]; then
                        [ "$JOB_FREQ_MIN" = na ] && JOB_FREQ_MIN=$2
                        [ "$2" -lt "$JOB_FREQ_MIN" ] && JOB_FREQ_MIN=$2
                    fi
                    if [ $el -gt $((TIMEOUT + margin)) ]; then
                        warn "decode exceeded ${TIMEOUT}s, killing it"
                        kill_job "$jf"
                        RC=timeout; status=done
                    fi ;;
                NOPID*) [ $el -gt 30 ] && status=gone ;;
                *GONE*) status=gone ;;
                esac
                [ -n "$status" ] && break
            done
        else
            status=gone
        fi
        JOB_WALL=$(( $(date +%s) - t0 ))
        if [ "$status" = done ]; then
            dsh "cat $jf.log" > "$logf"
            dsh "rm -f $jf.*" > /dev/null
            CURRENT_JOB=
            return
        fi
        dsh "rm -f $jf.*" > /dev/null
        CURRENT_JOB=
        if [ $attempt = 1 ]; then
            warn "decode vanished on the device without an exit code (reboot?), retrying once"
            attempt=2
            continue
        fi
        RC=lost
        echo "decode vanished twice without an exit code" > "$logf"
        return
    done
}

kill_job() {
    dsh "p=\$(cat $1.pid 2>/dev/null); [ -n \"\$p\" ] && { kill -TERM -\$p 2>/dev/null || { pkill -P \$p; kill \$p; }; }" > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Manifest, clip costs and estimates

manifest_field() { # clipfile column
    awk -F, -v c="$1" -v k="$2" 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        $1 == c { print $col[k] }' "$MANIFEST"
}

fps_value() { echo "$1" | awk -F/ '{ printf "%.3f", ($2 == "" ? $1 : $1 / $2) }'; }

category_of() {
    awk -F, -v c="$1" 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        $1 == c {
            split($col["fps"], f, "/"); fps = sprintf("%.3f", (f[2] == "" ? f[1] : f[1] / f[2]))
            sub(/\.?0+$/, "", fps)
            if ($col["interlace"] ~ /^progressive/) printf "progressive %s\n", fps
            else if ($col["field_interlaced_pics"] > 0) printf "interlaced %s +fields\n", fps
            else printf "interlaced %s\n", fps
        }' "$MANIFEST"
}

ref_frames() { # clip -> frame count, capped by --max-frames
    local n
    n=$(grep -vc '^#' "$CORPUS/ref/$1.framemd5")
    if [ "${MAX_FRAMES:-0}" -gt 0 ] && [ "$n" -gt "$MAX_FRAMES" ]; then n=$MAX_FRAMES; fi
    echo "$n"
}

mac_fps() { # clipname -> Mac single-thread fps (clip_cost.csv), 180 if unknown
    local v
    v=$(awk -F, -v c="$1" '$1 == c { print $4 }' "$COSTS" 2>/dev/null)
    echo "${v:-180}"
}

# pred_step KIND CLIP THREADS -> predicted wall seconds
pred_step() {
    case $1 in
    push)
        sz=$(stat -f %z "$CORPUS/clips/$(clip_file "$2")")
        awk -v s="$sz" -v b="$PUSH_BPS" 'BEGIN { printf "%.0f", s / b + 2 }' ;;
    verify|bench)
        awk -v kind="$1" -v fr="$(ref_frames "$2")" -v mf="$(mac_fps "$2")" -v n="$3" \
            -v sd="$SLOWDOWN" -v nc="$NCPU" -v md5="$MD5FPS" -v poll="$POLL" -v cd="$COOLDOWN" 'BEGIN {
            sp = (n <= 1 ? 1 : (n < nc ? n : nc) * 0.9)
            t = fr / (mf / sd * sp)
            if (kind == "verify") { m = fr / md5; if (m > t) t = m; t *= 1.05 }
            else t += cd
            printf "%.0f", t + poll / 2 + 2
        }' ;;
    par) # N single-thread copies sharing the cores; assume 30% contention
        awk -v fr="$(ref_frames "$2")" -v mf="$(mac_fps "$2")" -v n="$3" -v sd="$SLOWDOWN" \
            -v nc="$NCPU" -v poll="$POLL" -v cd="$COOLDOWN" 'BEGIN {
            w = (n > nc ? n / nc : 1) * 1.3
            printf "%.0f", fr / (mf / sd) * w + cd + poll / 2 + 2
        }' ;;
    *) echo 0 ;;
    esac
}

clip_file() { (cd "$CORPUS/clips" && ls | grep "^$1\.") | head -1; }

select_clips() { # pattern list -> clip files
    all=$(cd "$CORPUS/clips" && ls)
    if [ "$1" = all ]; then echo "$all"; return; fi
    for p in $1; do
        for c in $all; do
            name=${c%.*}
            case $name in
            $p|${p}_*) echo "$c" ;;
            esac
        done
    done | awk '!seen[$0]++'
}

is_single() { case " $SINGLE_VARIANTS " in *" $1 "*) return 0 ;; esac; return 1; }

threads_for() { # variant verify|bench
    if is_single "$1"; then echo 1
    elif [ "$2" = verify ]; then echo "$P_VT"
    else echo "$P_BT"
    fi
}

# ---------------------------------------------------------------------------
# Result files

compare_framemd5() { # REF OUT -> "status first_diff_frame ref_frames out_frames"
    local ref=$1 tmpref=
    if [ ! -s "$2" ]; then echo "no_output - - -"; return; fi
    if [ "${MAX_FRAMES:-0}" -gt 0 ]; then
        tmpref=$(mktemp); ref=$tmpref
        awk -v n="$MAX_FRAMES" '/^#/ { print; next } ++c <= n' "$1" > "$ref"
    fi
    if cmp -s "$ref" "$2"; then
        n=$(grep -vc '^#' "$ref")
        echo "match - $n $n"
        [ -z "$tmpref" ] || rm -f "$tmpref"
        return
    fi
    awk '
        FNR == NR { if ($0 !~ /^#/) ref[r++] = $0; next }
        $0 !~ /^#/ { out[o++] = $0 }
        END {
            n = r < o ? r : o
            for (i = 0; i < n; i++) if (ref[i] != out[i]) break
            if (i == n && r == o) printf "header_only - %d %d\n", r, o
            else printf "mismatch %d %d %d\n", i, r, o
        }' "$ref" "$2"
    [ -z "$tmpref" ] || rm -f "$tmpref"
    return 0
}

init_phase_dir() { # dir
    P_DIR=$1
    mkdir -p "$P_DIR/logs" "$P_DIR/framemd5"
    P_VCSV=$P_DIR/verify.csv
    P_BCSV=$P_DIR/bench.csv
    P_PCSV=$P_DIR/contention.csv
    [ -s "$P_PCSV" ] || echo "clip,category,variant,abi,copies,run,copy,exit,utime_s,stime_s,rtime_s,maxrss_kb,frames,fps,clip_fps,rt_factor,wall_s" > "$P_PCSV"
    [ -s "$P_VCSV" ] || echo "clip,category,variant,abi,threads,exit,status,first_diff_frame,ref_frames,out_frames,stderr_lines,wall_s" > "$P_VCSV"
    [ -s "$P_BCSV" ] || echo "clip,category,variant,abi,threads,run,exit,utime_s,stime_s,rtime_s,maxrss_kb,frames,fps,clip_fps,rt_factor,temp_before_c,temp_peak_c,temp_after_c,freq_before_mhz,freq_min_run_mhz,freq_after_mhz,wall_s" > "$P_BCSV"
}

have_verify() { [ $FORCE = 0 ] && awk -F, -v c="$1" -v v="$2" -v a="$ABI" -v n="$3" '$1 == c && $3 == v && $4 == a && $5 == n { f = 1 } END { exit !f }' "$P_VCSV"; }
have_par() { [ $FORCE = 0 ] && awk -F, -v c="$1" -v a="$ABI" -v n="$2" -v r="$3" '$1 == c && $4 == a && $5 == n && $6 == r { f = 1 } END { exit !f }' "$P_PCSV"; }
have_bench() { [ $FORCE = 0 ] && awk -F, -v c="$1" -v v="$2" -v a="$ABI" -v n="$3" -v r="$4" '$1 == c && $3 == v && $4 == a && $5 == n && $6 == r { f = 1 } END { exit !f }' "$P_BCSV"; }

drop_rows() { # CSV CLIP VARIANT THREADS [RUN]
    awk -F, -v c="$2" -v v="$3" -v a="$ABI" -v n="$4" -v r="${5:-}" '
        NR > 1 && $1 == c && $3 == v && $4 == a && $5 == n && (r == "" || $6 == r) { next }
        { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---------------------------------------------------------------------------
# Phase plan and execution

# plan_phase CLIPFILES -> P_PLAN lines "kind clip variant threads run pred"
plan_phase() {
    P_PLAN=
    P_NCLIPS=0
    for clip in $1; do
        name=${clip%.*}
        steps=
        for v in $VARIANTS; do
            if [ $P_DOV = 1 ]; then
                for n in $(threads_for "$v" verify); do
                    have_verify "$name" "$v" "$n" || steps="$steps
verify $name $v $n 1 $(pred_step verify "$name" "$n")"
                done
            fi
            if [ $P_DOB = 1 ]; then
                for n in $(threads_for "$v" bench); do
                    for r in $(seq 1 "$P_RUNS"); do
                        have_bench "$name" "$v" "$n" "$r" || steps="$steps
bench $name $v $n $r $(pred_step bench "$name" "$n")"
                    done
                done
            fi
        done
        if [ $P_DOB = 1 ] && [ "${P_PAR:-0}" -gt 1 ]; then
            for r in $(seq 1 "$P_RUNS"); do
                have_par "$name" "$P_PAR" "$r" || steps="$steps
par $name $BASE_VARIANT $P_PAR $r $(pred_step par "$name" "$P_PAR")"
            done
        fi
        [ -z "$steps" ] && continue
        P_NCLIPS=$((P_NCLIPS + 1))
        P_PLAN="$P_PLAN
push $name - - - $(pred_step push "$name")$steps
done $name - - - 0"
    done
    P_PRED_TOTAL=$(echo "$P_PLAN" | awk 'NF { s += $6 } END { print s + 0 }')
}

ACT_SUM=0
PRED_SUM=0
calib() { awk -v a="$ACT_SUM" -v p="$PRED_SUM" 'BEGIN { printf "%.3f", (p > 60 ? a / p : 1) }'; }

run_phase() { # label
    label=$1
    P_PRED_DONE=0
    ci=0
    [ -z "$P_PLAN" ] && { log "$label: nothing to do (all results present)"; return 0; }
    echo "$P_PLAN" | awk 'NF' > "$P_DIR/.plan"
    exec 3< "$P_DIR/.plan"
    while read -r kind name v n r pred <&3; do
        wait_if_paused
        t_step=$(date +%s)
        clip=$(clip_file "$name")
        dclip=$CLIP_DIR/$clip
        case $kind in
        push)
            ci=$((ci + 1))
            prefix="[clip $ci/$P_NCLIPS $name]"
            cat=$(category_of "$clip")
            frames=$(ref_frames "$name")
            cfps=$(fps_value "$(manifest_field "$clip" fps)")
            check_awake "$name"
            size_b=$(stat -f %z "$CORPUS/clips/$clip")
            size_kb=$(( size_b / 1024 ))
            SKIP_CLIP=0
            have_b=$(dsh "ls -ln $dclip 2>/dev/null" | awk 'NR == 1 { print $5 }')
            if [ $DRY = 0 ] && [ "$have_b" = "$size_b" ]; then
                log "$prefix $cat, $frames frames @ $cfps fps: already on the device"
                P_PRED_DONE=$((P_PRED_DONE + pred))
                continue
            fi
            dsh "rm -f $dclip" > /dev/null
            free_kb=$(dev_free_kb)
            need_kb=$(( size_kb + 100 * 1024 ))
            if [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ]; then
                warn "$name: not enough space on the device (${free_kb} KiB free, ${need_kb} KiB needed), skipping"
                echo "$name,$cat,-,$ABI,-,-,skipped_nospace,-,-,-,-,-" >> "$P_VCSV"
                SKIP_CLIP=1
            else
                log "$prefix $cat, $frames frames @ $cfps fps: pushing $((size_kb / 1024)) MiB"
                if ! dpush "$CORPUS/clips/$clip" "$dclip"; then
                    reconnect || die_lost "pushing $clip"
                    warn "$name: push failed, skipping"
                    dsh "rm -f $dclip" > /dev/null
                    SKIP_CLIP=1
                fi
            fi
            ;;
        verify)
            [ $SKIP_CLIP = 1 ] && continue
            [ $FORCE = 1 ] && drop_rows "$P_VCSV" "$name" "$v" "$n"
            dout=$DEV_DIR/$name.$v.t$n.framemd5
            lout=$P_DIR/framemd5/$name.$v.$ABI.t$n.framemd5
            vlog=$P_DIR/logs/$name.$v.$ABI.t$n.verify.log
            run_job "$vlog" "$TO $DEV_DIR/ffmpeg-$v -nostdin -v error -threads $n -thread_type frame -i $dclip -map 0:v:0 $FOPT -f framemd5 -y $dout"
            rm -f "$lout"
            dpull "$dout" "$lout" || true
            dsh "rm -f $dout" > /dev/null
            if [ $DRY = 0 ]; then
                set -- $(compare_framemd5 "$CORPUS/ref/$name.framemd5" "$lout")
                case $RC in timeout|124) shift; set -- timeout "$@" ;; esac
                nerr=$(grep -c . "$vlog")
                echo "$name,$cat,$v,$ABI,$n,$RC,$1,$2,$3,$4,$nerr,$JOB_WALL" >> "$P_VCSV"
                res="$1"
                [ "$1" = mismatch ] && res="MISMATCH at frame $2 ($4/$3 frames)"
                [ "$RC" != 0 ] && res="$res, exit $RC"
                [ "$nerr" -gt 0 ] && res="$res, $nerr stderr lines"
                case $1 in match|header_only) [ "$RC" = 0 ] || VERIFY_FAIL=$((VERIFY_FAIL + 1)) ;; *) VERIFY_FAIL=$((VERIFY_FAIL + 1)) ;; esac
            fi
            ;;
        bench)
            [ $SKIP_CLIP = 1 ] && continue
            [ $FORCE = 1 ] && drop_rows "$P_BCSV" "$name" "$v" "$n" "$r"
            blog=$P_DIR/logs/$name.$v.$ABI.t$n.r$r.bench.log
            if [ -n "${LAST_BENCH_END:-}" ] && [ "$COOLDOWN" -gt 0 ]; then
                if [ $DRY = 1 ]; then echo "+ sleep $COOLDOWN" >&2; else sleep "$COOLDOWN"; fi
            fi
            set -- $(dev_thermal)
            tb=$1 fb=$2
            run_job "$blog" "$TO $DEV_DIR/ffmpeg-$v -nostdin -hide_banner -nostats -benchmark -v info -threads $n -thread_type frame -i $dclip -map 0:v:0 $FOPT -f null -"
            LAST_BENCH_END=1
            set -- $(dev_thermal)
            ta=$1 fa=$2
            if [ $DRY = 0 ]; then
                row=$(awk -v fr="$frames" -v cf="$cfps" '
                    /bench: utime=/ {
                        for (i = 1; i <= NF; i++) {
                            split($i, kv, "="); val = kv[2]; sub(/s$/, "", val)
                            if (kv[1] == "utime") u = val
                            if (kv[1] == "stime") s = val
                            if (kv[1] == "rtime") t = val
                        }
                    }
                    /bench: maxrss=/ { m = $2; sub(/^maxrss=/, "", m); sub(/[^0-9]+$/, "", m) }
                    END {
                        fps = (t > 0 ? fr / t : 0)
                        printf "%s,%s,%s,%s,%s,%.2f,%s,%.3f", u, s, t, m, fr, fps, cf, (cf > 0 ? fps / cf : 0)
                    }' "$blog")
                echo "$name,$cat,$v,$ABI,$n,$r,$RC,$row,$tb,$JOB_TEMP_PEAK,$ta,$fb,$JOB_FREQ_MIN,$fa,$(( $(date +%s) - t_step ))" >> "$P_BCSV"
                fps=$(echo "$row" | cut -d, -f6) rt=$(echo "$row" | cut -d, -f8)
                res=$(awk -v f="$fps" -v r="$rt" 'BEGIN { printf "%.1f fps (%.2fx realtime)", f, r }')
                [ "$RC" != 0 ] && { res="FAILED, exit $RC (see $blog)"; BENCH_FAIL=$((BENCH_FAIL + 1)); }
                thermal_warnings
            fi
            ;;
        par)
            [ $SKIP_CLIP = 1 ] && continue
            if [ $FORCE = 1 ]; then
                awk -F, -v c="$name" -v a="$ABI" -v n="$n" -v r="$r" 'NR > 1 && $1 == c && $4 == a && $5 == n && $6 == r { next } { print }' \
                    "$P_PCSV" > "$P_PCSV.tmp" && mv "$P_PCSV.tmp" "$P_PCSV"
            fi
            plog=$P_DIR/logs/$name.$v.$ABI.x$n.r$r.contention.log
            if [ -n "${LAST_BENCH_END:-}" ] && [ "$COOLDOWN" -gt 0 ]; then
                if [ $DRY = 1 ]; then echo "+ sleep $COOLDOWN" >&2; else sleep "$COOLDOWN"; fi
            fi
            one="$TO $DEV_DIR/ffmpeg-$v -nostdin -hide_banner -nostats -benchmark -v info -threads 1 -i $dclip -map 0:v:0 $FOPT -f null -"
            # Braces: the job script redirects the whole command, not its last part.
            run_job "$plog" "{ i=1; while [ \$i -le $n ]; do ( $one > $DEV_DIR/par.\$i.log 2>&1; echo \"rc=\$?\" >> $DEV_DIR/par.\$i.log ) & i=\$((i + 1)); done; wait; i=1; while [ \$i -le $n ]; do echo \"=== copy \$i\"; cat $DEV_DIR/par.\$i.log; i=\$((i + 1)); done; rm -f $DEV_DIR/par.*.log; }"
            LAST_BENCH_END=1
            if [ $DRY = 0 ]; then
                awk -v fr="$frames" -v cf="$cfps" -v pre="$name,$cat,$v,$ABI,$n,$r" -v w="$JOB_WALL" '
                    function flush() {
                        if (cp == "") return
                        fps = (t > 0 ? fr / t : 0)
                        printf "%s,%s,%s,%s,%s,%s,%s,%s,%.2f,%s,%.3f,%s\n", pre, cp, (rc == "" ? "lost" : rc), u, s, t, m, fr, fps, cf, (cf > 0 ? fps / cf : 0), w
                    }
                    /^=== copy / { flush(); cp = $3; rc = u = s = t = m = "" }
                    /^rc=/ { rc = substr($0, 4) }
                    /bench: utime=/ {
                        for (i = 1; i <= NF; i++) {
                            split($i, kv, "="); val = kv[2]; sub(/s$/, "", val)
                            if (kv[1] == "utime") u = val
                            if (kv[1] == "stime") s = val
                            if (kv[1] == "rtime") t = val
                        }
                    }
                    /bench: maxrss=/ { m = $2; sub(/^maxrss=/, "", m); sub(/[^0-9]+$/, "", m) }
                    END { flush() }' "$plog" > "$P_DIR/.par_rows"
                cat "$P_DIR/.par_rows" >> "$P_PCSV"
                res=$(awk -F, -v n="$n" '
                    $8 == 0 && $14 > 0 { ok++; f += $14; u += $9 }
                    END {
                        if (ok < n) { printf "FAILED: %d of %d copies finished", ok, n; exit }
                        printf "%d copies: %.1f fps each, %.1fs CPU each", n, f / ok, u / ok
                    }' "$P_DIR/.par_rows")
                rm -f "$P_DIR/.par_rows"
                case $res in FAILED*) BENCH_FAIL=$((BENCH_FAIL + 1)) ;; esac
            fi
            ;;
        done)
            keep=0
            if [ $KEEP_CLIPS = 1 ]; then
                free_kb=$(dev_free_kb)
                [ -n "$free_kb" ] && [ "$free_kb" -ge "$KEEP_RESERVE_KB" ] && keep=1
            fi
            if [ $keep = 0 ]; then
                dsh "rm -f $dclip" > /dev/null
                [ $KEEP_CLIPS = 1 ] && log "$prefix not kept on the device: less than $((KEEP_RESERVE_KB / 1024)) MiB would stay free"
            fi
            ;;
        esac
        wall=$(( $(date +%s) - t_step ))
        if [ "$kind" != done ] && [ $DRY = 0 ]; then
            ACT_SUM=$((ACT_SUM + wall)); PRED_SUM=$((PRED_SUM + pred))
        fi
        P_PRED_DONE=$((P_PRED_DONE + pred))
        eta=$(awk -v t="$P_PRED_TOTAL" -v d="$P_PRED_DONE" -v c="$(calib)" 'BEGIN { print (t - d) * c }')
        case $kind in
        verify) log "$prefix verify $v threads=$n — ${res:-dry run} — ETA $(fmt_dur "$eta")" ;;
        bench) log "$prefix $v threads=$n run $r/$P_RUNS — ${res:-dry run} — ETA $(fmt_dur "$eta")" ;;
        par) log "$prefix contention: $n x $v at 1 thread, run $r/$P_RUNS — ${res:-dry run} — ETA $(fmt_dur "$eta")" ;;
        done) log "$prefix done" ;;
        esac
        res=
    done
    exec 3<&-
}

thermal_warnings() {
    if [ "$JOB_FREQ_MIN" != na ] && [ -n "${MAXFREQ:-}" ] && [ "$MAXFREQ" != na ] &&
        [ $((JOB_FREQ_MIN * 10)) -lt $((MAXFREQ * 9)) ]; then
        warn "CPU frequency fell to ${JOB_FREQ_MIN} MHz during the run (max ${MAXFREQ} MHz): throttling?"
    fi
    if [ "$JOB_TEMP_PEAK" != na ] && [ -n "${BASE_TEMP:-}" ] && [ "$BASE_TEMP" != na ]; then
        awk -v p="$JOB_TEMP_PEAK" -v b="$BASE_TEMP" 'BEGIN { exit !(p - b > 15 || p > 85) }' &&
            warn "temperature peaked at ${JOB_TEMP_PEAK} C (${BASE_TEMP} C at start)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Summary

write_summary() { # dir title
    d=$1
    med=$d/.medians
    tail -n +2 "$d/bench.csv" | awk -F, '$7 == 0 && $13 > 0 { print $1 "|" $2 "|" $3 "|" $5 "," $13 "," $14 }' |
        sort -t, -k1,1 -k2,2g |
        awk -F, '
            { k = $1; v[k, ++n[k]] = $2; cf[k] = $3; if (!(k in seen)) { seen[k] = 1; keys[++nk] = k } }
            END {
                for (i = 1; i <= nk; i++) {
                    k = keys[i]; c = n[k]
                    m = (c % 2 ? v[k, (c + 1) / 2] : (v[k, c / 2] + v[k, c / 2 + 1]) / 2)
                    printf "%s,%.2f,%s,%d\n", k, m, cf[k], c
                }
            }' > "$med"
    {
        echo "# $2"
        echo
        echo "Generated $(date '+%Y-%m-%d %H:%M:%S') on $MODEL ($ABI). Device details in device.txt."
        [ $NO_WAKE = 1 ] && echo "Run with --no-wake: the device was not woken and its power settings were not changed; power states are in run.log."
        echo
        for v in $VARIANTS; do
            echo "- \`$v\`: $(cat "$BIN/ffmpeg-$v-$ABI.commit" 2>/dev/null)"
        done
        echo
        echo "## Headline"
        echo
        headline "$d"
        echo
        echo "## Verification (framemd5 vs ref/)"
        echo
        echo "| status | count |"
        echo "|---|---|"
        tail -n +2 "$d/verify.csv" | awk -F, '{ k = $7; if ($6 != 0 && $6 != "-") k = k " (exit " $6 ")"; c[k]++ } END { for (k in c) printf "| %s | %d |\n", k, c[k] }' | sort
        bad=$(tail -n +2 "$d/verify.csv" | awk -F, '($7 != "match" && $7 != "header_only") || ($6 != 0 && $6 != "-")')
        if [ -n "$bad" ]; then
            echo
            echo "Failures:"
            echo
            echo "$bad" | awk -F, '{ printf "- %s %s t%s: exit=%s %s first_diff=%s frames=%s/%s stderr=%s\n", $1, $3, $5, $6, $7, $8, $10, $9, $11 }'
        fi
        echo
        echo "## Decode speed (median of runs)"
        echo
        echo "Speedup is against the same variant at 1 thread; 'vs $BASE_VARIANT' is against $BASE_VARIANT at 1 thread."
        echo
        echo "| clip | category | variant | threads | median fps | realtime x | speedup | vs $BASE_VARIANT | runs | verify |"
        echo "|---|---|---|---|---|---|---|---|---|---|"
        awk -F, -v bv="$BASE_VARIANT" -v vcsv="$d/verify.csv" '
            BEGIN { while ((getline line < vcsv) > 0) { split(line, f, ","); vs[f[1] "|" f[3] "|" f[5]] = f[7] } }
            { med[$1] = $2; cf[$1] = $3; runs[$1] = $4; order[++n] = $1 }
            END {
                for (i = 1; i <= n; i++) {
                    key = order[i]; split(key, k, "|")
                    b = med[k[1] "|" k[2] "|" k[3] "|1"]; fx = med[k[1] "|" k[2] "|" bv "|1"]
                    st = vs[k[1] "|" k[3] "|" k[4]]
                    printf "| %s | %s | %s | %s | %.1f | %.2f | %s | %s | %d | %s |\n", k[1], k[2], k[3], k[4], med[key],
                        (cf[key] > 0 ? med[key] / cf[key] : 0),
                        (b > 0 ? sprintf("%.2f", med[key] / b) : "-"), (fx > 0 ? sprintf("%.2f", med[key] / fx) : "-"),
                        runs[key], (st == "" ? "-" : st)
                }
            }' "$med"
        failed=$(tail -n +2 "$d/bench.csv" | awk -F, '$7 != 0' | wc -l | tr -d ' ')
        [ "$failed" -gt 0 ] && { echo; echo "$failed bench runs exited non-zero (excluded); see bench.csv and logs/."; }
        compare_section "$med"
        contention_section "$d" "$med"
        echo
        echo "## Thermal / frequency during bench"
        echo
        tail -n +2 "$d/bench.csv" | awk -F, -v mx="${MAXFREQ:-na}" '
            { for (i = 16; i <= 18; i++) if ($i != "na" && $i != "") { if (lo == "" || $i < lo) lo = $i; if (hi == "" || $i > hi) hi = $i } }
            $20 != "na" && $20 != "" { if (fm == "" || $20 < fm) fm = $20 }
            END {
                printf "- temperature (max zone): %s .. %s C\n", (lo == "" ? "na" : lo), (hi == "" ? "na" : hi)
                printf "- lowest max-core frequency while decoding: %s MHz (cpuinfo max %s MHz)\n", (fm == "" ? "na" : fm), mx
            }'
    } > "$d/summary.md"
    rm -f "$med"
}

# compare_section MEDIANS: variant A against variant B at the same thread count
compare_section() {
    for pair in $COMPARE_PAIRS; do
        a=${pair%%:*} b=${pair#*:}
        rows=$(awk -F, -v a="$a" -v b="$b" '
            { split($1, k, "|"); key = k[1] "|" k[4]
              if (k[3] == a) { fa[key] = $2; if (!(key in seen)) { seen[key] = 1; order[++n] = key } }
              if (k[3] == b) fb[key] = $2 }
            END {
                for (i = 1; i <= n; i++) { key = order[i]; if (!(key in fb) || fb[key] <= 0) continue
                    split(key, k, "|")
                    printf "| %s | %s | %.1f | %.1f | %+.1f%% |\n", k[1], k[2], fb[key], fa[key], (fa[key] / fb[key] - 1) * 100 }
            }' "$1")
        [ -z "$rows" ] && continue
        echo
        echo "## \`$a\` vs \`$b\`"
        echo
        echo "| clip | threads | $b fps | $a fps | change |"
        echo "|---|---|---|---|---|"
        echo "$rows"
    done
}

# contention_section DIR MEDIANS: N single-thread copies at once vs one alone
contention_section() {
    [ -f "$1/contention.csv" ] && [ "$(wc -l < "$1/contention.csv")" -gt 1 ] || return 0
    echo
    echo "## Contention: independent single-thread decodes at once"
    echo
    echo "Each copy is \`$BASE_VARIANT\` at 1 thread on its own core. Alone = the \`$BASE_VARIANT\` 1-thread bench runs."
    echo "If copies need more CPU time than a lone decode, they are slowing each other through shared cache or memory."
    echo
    echo "| clip | copies | alone fps | fps per copy | per-copy speed | CPU time per copy vs alone |"
    echo "|---|---|---|---|---|---|"
    awk -F, -v bv="$BASE_VARIANT" -v bcsv="$1/bench.csv" '
        BEGIN {
            while ((getline line < bcsv) > 0) { split(line, f, ",")
                if (f[3] == bv && f[5] == 1 && f[7] == 0 && f[13] > 0) { af[f[1]] += f[13]; au[f[1]] += f[8]; an[f[1]]++ } }
        }
        NR > 1 && $8 == 0 && $14 > 0 { k = $1 "|" $5; if (!(k in seen)) { seen[k] = 1; order[++n] = k }; pf[k] += $14; pu[k] += $9; pn[k]++ }
        END {
            for (i = 1; i <= n; i++) { k = order[i]; split(k, c, "|")
                pfps = pf[k] / pn[k]; u = pu[k] / pn[k]
                if (an[c[1]] > 0) { a = af[c[1]] / an[c[1]]; au1 = au[c[1]] / an[c[1]]
                    printf "| %s | %s | %.1f | %.1f | %.2fx | %+.0f%% |\n", c[1], c[2], a, pfps, pfps / a, (u / au1 - 1) * 100 }
                else printf "| %s | %s | - | %.1f | - | - |\n", c[1], c[2], pfps }
        }' "$1/contention.csv"
}

# headline DIR: one line per clip
headline() {
    awk -F, -v bv="$BASE_VARIANT" -v tv="$THREADED_VARIANT" -v vcsv="$1/verify.csv" '
        BEGIN {
            while ((getline line < vcsv) > 0) {
                split(line, f, ","); if (f[1] == "clip") continue
                if (!(f[1] in vok)) vok[f[1]] = "ok"
                if ((f[7] != "match" && f[7] != "header_only") || (f[6] != 0 && f[6] != "-")) vok[f[1]] = "FAIL"
            }
        }
        { split($1, k, "|"); c = k[1]; if (!(c in seen)) { seen[c] = 1; cl[++n] = c }
          if (k[3] == bv && k[4] == 1) fx[c] = $2
          if (k[3] == tv) { if (k[4] == 1) p1[c] = $2; if ($2 > pb[c]) { pb[c] = $2; pt[c] = k[4]; rt[c] = $2 / $3 } } }
        END {
            print "| clip | " bv " 1 thread fps | " tv " 1 thread fps | " tv " best fps (threads) | realtime x at best | verify |"
            print "|---|---|---|---|---|---|"
            for (i = 1; i <= n; i++) { c = cl[i]
                printf "| %s | %s | %s | %s | %s | %s |\n", c, (c in fx ? sprintf("%.1f", fx[c]) : "-"), (c in p1 ? sprintf("%.1f", p1[c]) : "-"),
                    (c in pb ? sprintf("%.1f (%s)", pb[c], pt[c]) : "-"), (c in rt ? sprintf("%.2f", rt[c]) : "-"), (c in vok ? vok[c] : "-") }
        }' "$1/.medians"
}

# ---------------------------------------------------------------------------
# Steps

preflight() {
    target_probe
    MODEL_TAG=$(echo "$MODEL" | tr -c 'A-Za-z0-9_.-' '_' | sed 's/_*$//')

    if [ -z "$ABI" ]; then
        case ",$ABILIST," in
        *,macos,*) ABI=macos ;;
        *,arm64-v8a,*) ABI=arm64-v8a ;;
        *,armeabi-v7a,*) ABI=armeabi-v7a ;;
        ,,) ABI=${T_ARCH:-armeabi-v7a}; log "abilist unknown (dry run), assuming $ABI" ;;
        *) die "no supported ABI in abilist '$ABILIST'" ;;
        esac
    fi

    if [ -z "$OUT" ]; then
        if [ $DRY = 1 ]; then
            OUT=$(mktemp -d /tmp/tv_bench-dryrun.XXXXXX)
        elif [ $RESUME = 1 ]; then
            OUT=$(ls -d "$CORPUS/results/tv-$MODEL_TAG-"* 2>/dev/null | tail -1)
            [ -n "$OUT" ] || die "--resume: no previous results for $MODEL_TAG"
        else
            OUT=$CORPUS/results/tv-$MODEL_TAG-$(date +%Y%m%d-%H%M%S)
        fi
    fi
    mkdir -p "$OUT/logs"
    OUT=$(cd "$OUT" && pwd)
    RUNLOG=$OUT/run.log
    ADBLOG=$OUT/logs/adb.log
    log "results: $OUT"
    [ -n "$TARGET_NAME" ] && log "target: $TARGET_NAME ($TARGET_TYPE)${T_NOTES:+ - $T_NOTES}"
    log "model: $MODEL  abilist: $ABILIST  abi: $ABI  device dir: $DEV_DIR"
    if [ "$MAX_FRAMES" -gt 0 ]; then log "max-frames: first $MAX_FRAMES frames of each clip"; fi

    {
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') $(target_label)"
        echo "model: $MODEL"
        echo "abilist: $ABILIST"
        echo "abi used: $ABI"
        for v in $VARIANTS; do
            echo "binary $v: ffmpeg-$v-$ABI commit $(cat "$BIN/ffmpeg-$v-$ABI.commit" 2>/dev/null)"
        done
        target_device_info
    } >> "$OUT/device.txt"

    target_cpu_probe
    [ -z "$NCPU" ] && NCPU=4
    set -- $(dev_thermal)
    BASE_TEMP=$1

    # Estimate model: TV single-thread fps = Mac fps / SLOWDOWN.
    if [ -z "$SLOWDOWN" ]; then
        case $ABI in
        macos) SLOWDOWN=1 ;;
        arm64-v8a) SLOWDOWN=11 ;;
        *) SLOWDOWN=13 ;;
        esac
    fi

    # Leftovers from an interrupted run must not compete for the CPU.
    dsh "pkill -f '$DEV_DIR/ffmpeg-' 2>/dev/null; mkdir -p $JOB_DIR $CLIP_DIR && rm -f $JOB_DIR/* $DEV_DIR/*.m2ts $DEV_DIR/*.mkv $DEV_DIR/*.framemd5 $DEV_DIR/par.*.log" > /dev/null
    if [ $CLEAR_CLIPS = 1 ]; then
        dsh "rm -f $CLIP_DIR/*" > /dev/null
        log "cleared the clips kept on the device"
    fi
    kept=$(dsh "ls -ln $CLIP_DIR 2>/dev/null" | awk 'NF > 5 && $1 ~ /^-/ { n++; s += $5 } END { if (n) printf "%d clip(s), %d MiB", n, s / 1048576 }')
    [ -n "$kept" ] && log "kept on the device from earlier runs: $kept ($CLIP_DIR; --clear-clips removes them)"

    if ! push_binaries; then
        case ",$ABILIST," in
        *,armeabi-v7a,*)
            [ $ABI_FORCED = 0 ] && [ "$ABI" = arm64-v8a ] || die "the binaries do not run on the device (try --abi)"
            ABI=armeabi-v7a
            log "falling back to $ABI"
            echo "abi used: $ABI (arm64-v8a binaries failed to run)" >> "$OUT/device.txt"
            push_binaries || die "the armeabi-v7a binaries do not run either"
            ;;
        *) die "the binaries do not run on the device (try --abi)" ;;
        esac
    fi

    target_job_tools
}

push_binaries() {
    for v in $VARIANTS; do
        [ -x "$BIN/ffmpeg-$v-$ABI" ] || die "missing binary $BIN/ffmpeg-$v-$ABI (${T_BUILD:+build it with $T_BUILD <worktree> $v; or }run build_android.sh)"
        dpush "$BIN/ffmpeg-$v-$ABI" "$DEV_DIR/ffmpeg-$v" || die_lost "pushing ffmpeg-$v"
        dsh "chmod 755 $DEV_DIR/ffmpeg-$v" > /dev/null
        ver=$(dsh "$DEV_DIR/ffmpeg-$v -hide_banner -version 2>&1 | head -1")
        if [ $DRY = 0 ] && ! echo "$ver" | grep -q '^ffmpeg version'; then
            log "ffmpeg-$v-$ABI does not run on the device: $ver"
            return 1
        fi
        log "ffmpeg-$v ($ABI): ${ver:-?}"
        echo "ffmpeg-$v ($ABI) -version: $ver" >> "$OUT/device.txt"
    done
}

validate_report() {
    say ""
    say "==== Validating TV settings ===="
    target_validate_report
    say ""
    pause
}

print_estimate() { # label
    secs=$(awk -v p="$P_PRED_TOTAL" -v c="$(calib)" 'BEGIN { print p * c }')
    note="assumes the TV decodes at Mac speed / $SLOWDOWN on one thread"
    [ "$PRED_SUM" -gt 60 ] && note="calibrated on the runs so far (x$(calib))"
    say "$1: $P_NCLIPS clip(s), estimated $(fmt_dur "$secs") ($note)"
}

# setup_phase DIR CLIPPATTERN VT BT RUNS DOV DOB
setup_phase() {
    init_phase_dir "$1"
    P_VT=$3 P_BT=$4 P_RUNS=$5 P_DOV=$6 P_DOB=$7
    clips=$(select_clips "$2")
    [ -n "$clips" ] || die "no clips match '$2'"
    plan_phase "$clips"
}

smoke_phase() {
    P_PAR=0
    setup_phase "$OUT/smoke" "$SMOKE_CLIP" "1 4" "1 4" 1 1 1
    print_estimate "Smoke test"
    VERIFY_FAIL=0 BENCH_FAIL=0
    LAST_BENCH_END=
    run_phase smoke
    [ $DRY = 1 ] && return 0
    write_summary "$OUT/smoke" "Smoke test on $MODEL ($ABI)"
    fails=$(tail -n +2 "$OUT/smoke/verify.csv" | awk -F, '($7 != "match" && $7 != "header_only") || $6 != 0' | wc -l | tr -d ' ')
    bfails=$(tail -n +2 "$OUT/smoke/bench.csv" | awk -F, '$7 != 0 || $13 <= 0' | wc -l | tr -d ' ')
    say ""
    if [ "$fails" = 0 ] && [ "$bfails" = 0 ]; then
        say "==== Smoke test: PASS ($ABI binaries decode bit-exactly; bench parsed) ===="
        return 0
    fi
    say "==== Smoke test: FAIL ($fails verify failure(s), $bfails bench failure(s)) ===="
    tail -n +2 "$OUT/smoke/verify.csv" | awk -F, '($7 != "match" && $7 != "header_only") || $6 != 0 { printf "  verify %s t%s: %s exit=%s first_diff=%s\n", $3, $5, $7, $6, $8 }' >&2
    tail -n +2 "$OUT/smoke/bench.csv" | awk -F, '$7 != 0 || $13 <= 0 { printf "  bench %s t%s run %s: exit=%s\n", $3, $5, $6, $7 }' >&2
    say "  logs: $OUT/smoke/logs/"
    return 1
}

main_phase() {
    pat=${CLIPS_ARG:-$DEFAULT_CLIPS}
    P_PAR=$CONTENTION
    setup_phase "$OUT" "$pat" "$VERIFY_THREADS" "$BENCH_THREADS" "$RUNS" "$DO_VERIFY" "$DO_BENCH"
    print_estimate "Main run$([ $QUICK = 1 ] && echo ' (--quick)')"
    VERIFY_FAIL=0 BENCH_FAIL=0
    LAST_BENCH_END=
    run_phase main
}

on_exit() {
    rc=$?
    trap - EXIT INT TERM
    if [ -n "$CURRENT_JOB" ] && [ $DRY = 0 ]; then
        log "stopping the decode still running on the device"
        NO_RECONNECT=1
        kill_job "$CURRENT_JOB"
    fi
    if [ $SETTINGS_APPLIED = 1 ] && [ $DRY = 0 ]; then
        restore_settings "$SETTINGS_FILE"
    fi
    [ -n "${CAFF_PID:-}" ] && kill "$CAFF_PID" 2>/dev/null
    exit $rc
}

main() {
    parse_args "$@"
    SETTINGS_APPLIED=0
    trap on_exit EXIT
    trap 'log "interrupted"; exit 130' INT
    trap 'log "terminated"; exit 143' TERM

    if [ -z "$RESTORE_FILE" ]; then
        [ $NO_SMOKE = 0 ] && need_clip_defaults smoke
        [ $SMOKE_ONLY = 0 ] && [ -z "$CLIPS_ARG" ] && need_clip_defaults default
    fi

    if [ -n "$RESTORE_FILE" ]; then
        INTERACTIVE=0
        connect_device
        restore_settings "$RESTORE_FILE"
        exit $?
    fi

    if [ $DRY = 0 ] && command -v caffeinate > /dev/null; then
        caffeinate -i -w $$ &
        CAFF_PID=$!
    fi

    [ $INTERACTIVE = 1 ] && target_checklist
    connect_device
    target_wake
    preflight
    if [ $NO_WAKE = 0 ]; then
        apply_settings
        [ $INTERACTIVE = 1 ] && validate_report
    else
        log "--no-wake: device left as is, power settings untouched ($(power_state))"
        echo "no-wake: power settings untouched; power at start: $(power_state)" >> "$OUT/device.txt"
    fi

    if [ $NO_SMOKE = 0 ]; then
        if ! smoke_phase; then
            if [ $SMOKE_ONLY = 1 ]; then exit 1; fi
            confirm "Continue with the full run anyway?" "$([ $YES = 1 ] && echo y || echo n)" || exit 1
            warn "continuing after a failed smoke test"
        fi
    fi

    if [ $SMOKE_ONLY = 0 ]; then
        target_picture_prompt
        main_phase
    fi

    [ $DRY = 1 ] && { log "dry run done"; exit 0; }

    if [ $SMOKE_ONLY = 0 ]; then
        write_summary "$OUT" "VC-1 decode on $MODEL ($ABI)"
        sumfile=$OUT/summary.md
    else
        sumfile=$OUT/smoke/summary.md
    fi
    [ $SETTINGS_APPLIED = 1 ] && restore_settings "$SETTINGS_FILE"
    say ""
    say "==== Done ===="
    target_done_message
    say "Summary: $sumfile"
    say ""
    sed -n '/^## Headline/,/^## Verification/p' "$sumfile" | sed '1,2d;$d' >&2
    sed -n '/^## Verification/,/^## Decode/p' "$sumfile" | grep '^|' | sed 1,2d | sed 's/^/verify: /' >&2
}

main "$@"
