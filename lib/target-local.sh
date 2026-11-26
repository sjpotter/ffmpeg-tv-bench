# shellcheck shell=bash
# Transport and device operations for running the binaries on this Mac
# ("--local" and targets of TYPE=local). Implements the same interface as
# lib/target-adb.sh (see the header there); everything runs through `sh -c` and
# `cp`, there is no connection to lose, no power state and no settings to restore.

target_init() {
    ADB="local"
    DEV_DIR=${DEV_DIR:-$HERE/local-device}
    POLL=${POLL:-1}
    MD5FPS=800 PUSH_BPS=2000000000
}

adb_state() { echo device; }
adb_connect_once() { return 0; }
reconnect() { return 0; }

dsh() {
    if [ $DRY = 1 ]; then echo "+ $ADB shell '$1'" >&2; return 0; fi
    sh -c "$1" < /dev/null
    return 0
}

dpush() {
    if [ $DRY = 1 ]; then echo "+ $ADB push '$1' '$2'" >&2; return 0; fi
    cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"
}

dpull() {
    if [ $DRY = 1 ]; then echo "+ $ADB pull '$1' '$2'" >&2; return 0; fi
    cp "$1" "$2"
}

die_lost() {
    die "local run failed ($1). Resume with:
    $0 --out $OUT $ORIG_ARGS"
}

connect_device() { return 0; }
power_state() { echo "local"; }
check_awake() { return 0; }
apply_settings() { return 0; }
restore_settings() { warn "local target: no device settings to restore"; return 0; }

target_probe() {
    MODEL=local-$(sysctl -n hw.model 2>/dev/null || uname -m)
    ABILIST=macos
}

target_label() { echo local; }

target_device_info() { sysctl -n machdep.cpu.brand_string hw.ncpu 2>/dev/null; }

target_cpu_probe() {
    NCPU=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)
    MAXFREQ=na
}

target_job_tools() { TO= SETSID=; }
target_checklist() { return 0; }
target_wake() { return 0; }
target_validate_report() { say "  local mode: $MODEL, $NCPU cores"; }
target_picture_prompt() { return 0; }
target_done_message() { return 0; }
