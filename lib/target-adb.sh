# shellcheck shell=bash
# Transport and device operations for an Android device over adb.
#
# Sourced by tv_bench.sh for targets of TYPE=adb (and for ad hoc "-s SERIAL").
# Each target type provides the same set of functions; see lib/target-local.sh
# and the "Adding a target type" section of README.md.
#
# Interface used by the shared harness:
#   target_init            set ADB, DEV_DIR, JOB_DIR, CLIP_DIR, POLL (after option parsing)
#   adb_state/reconnect    connection state and recovery (local: always ready)
#   connect_device         wait until the device is usable
#   dsh CMD                run a shell one-liner on the device, print its output
#                          (return 99 = device unreachable)
#   dpush SRC DST / dpull SRC DST   copy files to / from the device
#   die_lost WHAT          fatal "lost the device" message with the resume command
#   power_state/check_awake  wakefulness (local: no-op)
#   apply_settings/restore_settings  save, change and restore power settings (local: no-op)
#   target_probe           set MODEL and ABILIST
#   target_device_info     append device details to $OUT/device.txt
#   target_cpu_probe       set NCPU and MAXFREQ
#   target_job_tools       set TO (remote timeout) and SETSID
#   target_checklist       interactive checklist before connecting
#   target_wake            wake the device once before preflight
#   target_validate_report validation screen text
#   target_picture_prompt  "turn the picture off" step
#   target_done_message    closing message
# Shared state: NO_RECONNECT, SETTINGS_APPLIED, SETTINGS_FILE live in tv_bench.sh.

adb_state() { # device | unauthorized | offline | none | multiple
    adb devices 2>/dev/null | tr -d '\r' | awk -v s="$SERIAL" '
        NR > 1 && NF >= 2 { n++; if (s == "" || $1 == s) { st = $2; m++ } }
        END { if (s == "" && n > 1) print "multiple"; else print (st == "" ? "none" : st) }'
}

adb_connect_once() {
    case $SERIAL in
    *:*)
        adb disconnect "$SERIAL" > /dev/null 2>&1
        adb connect "$SERIAL" 2>&1 | tr -d '\r' >> "$ADBLOG"
        ;;
    esac
    sleep 1
}

# reconnect: up to RECONNECT_TRIES attempts with exponential backoff.
reconnect() {
    local tries=$RECONNECT_TRIES delay=$RECONNECT_DELAY i st
    [ $NO_RECONNECT = 1 ] && tries=1
    i=1
    while [ $i -le "$tries" ]; do
        st=$(adb_state)
        [ "$st" = device ] && return 0
        log "adb: device is '$st', reconnect attempt $i/$tries"
        adb_connect_once
        [ "$(adb_state)" = device ] && { log "adb: reconnected"; return 0; }
        [ $i -lt "$tries" ] && sleep "$delay"
        delay=$((delay * 2)); [ $delay -gt 60 ] && delay=60
        i=$((i + 1))
    done
    return 1
}


# dsh CMD: run CMD on the device and print its output. Returns 99 if the
# device can't be reached even after reconnecting.
dsh() {
    if [ $DRY = 1 ]; then echo "+ $ADB shell '$1'" >&2; return 0; fi
    local out
    out=$($ADB shell "$1
echo __DSH_OK__" < /dev/null 2>> "$ADBLOG" | tr -d '\r')
    case $out in
    *__DSH_OK__) ;;
    *)
        reconnect || return 99
        out=$($ADB shell "$1
echo __DSH_OK__" < /dev/null 2>> "$ADBLOG" | tr -d '\r')
        case $out in *__DSH_OK__) ;; *) return 99 ;; esac
        ;;
    esac
    printf '%s' "${out%__DSH_OK__}"
}

dpush() {
    if [ $DRY = 1 ]; then echo "+ $ADB push '$1' '$2'" >&2; return 0; fi
    $ADB push "$1" "$2" < /dev/null >> "$ADBLOG" 2>&1 && return 0
    reconnect && $ADB push "$1" "$2" < /dev/null >> "$ADBLOG" 2>&1
}

dpull() {
    if [ $DRY = 1 ]; then echo "+ $ADB pull '$1' '$2'" >&2; return 0; fi
    $ADB pull "$1" "$2" < /dev/null >> "$ADBLOG" 2>&1 && return 0
    reconnect && $ADB pull "$1" "$2" < /dev/null >> "$ADBLOG" 2>&1
}

die_lost() {
    die "lost the device ($1). Reconnect (adb connect ${SERIAL:-<TV_IP>:5555}) and resume with:
    $0 --out $OUT $ORIG_ARGS"
}

# Wait until the device is connected and authorized.
connect_device() {
    [ $DRY = 1 ] && return 0
    command -v adb > /dev/null || die "adb not found (brew install --cask android-platform-tools)"
    if [ -z "$SERIAL" ] && [ $INTERACTIVE = 1 ] && [ "$(adb_state)" = none ]; then
        printf 'TV IP address (port 5555 is assumed): ' >&2
        read -r ip
        case $ip in *:*) SERIAL=$ip ;; *) SERIAL=$ip:5555 ;; esac
        ADB="adb -s $SERIAL"
    fi
    wait_s=120
    [ $INTERACTIVE = 1 ] && wait_s=600
    start=$(date +%s) told=0 last_connect=0
    while :; do
        st=$(adb_state)
        case $st in
        device) break ;;
        multiple) die "several adb devices are connected; pass -s SERIAL" ;;
        unauthorized)
            if [ $told = 0 ]; then
                say ""
                say ">>> The TV is asking for permission. On the TV, select 'Always allow from this computer'"
                say ">>> and then OK in the 'Allow USB debugging?' dialog. Waiting..."
                told=1
            fi ;;
        *)
            now=$(date +%s)
            if [ $((now - last_connect)) -ge 10 ]; then
                case $SERIAL in
                *:*) log "adb connect $SERIAL"; adb connect "$SERIAL" 2>&1 | tr -d '\r' | sed 's/^/    /' >&2 ;;
                *) [ $told = 0 ] && say "Waiting for the device (${SERIAL:-any}) to show up in 'adb devices'..." ; told=2 ;;
                esac
                last_connect=$now
            fi ;;
        esac
        [ $(($(date +%s) - start)) -ge $wait_s ] && die "device not ready after ${wait_s}s (adb state: $st)"
        sleep 3
    done
    log "adb: ${SERIAL:-device} connected and authorized"
}


power_state() {
    dsh "dumpsys power | grep -E 'mWakefulness=|Display Power'" | sed 's/^ *//' | tr '\n' ';' | sed 's/;$//'
}

check_awake() { # label
    [ $DRY = 1 ] && return 0
    ps_=$(power_state)
    log "power ($1): $ps_"
    [ $NO_WAKE = 1 ] && return 0
    case $ps_ in
    *mWakefulness=Awake*) return 0 ;;
    *) warn "the TV is not awake ($ps_); decoding may stop or slow down"; return 1 ;;
    esac
}


settings_get_all() { # prints "ns key value" lines
    cmd=
    for k in $SETTINGS_KEYS; do
        cmd="$cmd echo \"${k%%:*} ${k#*:} \$(settings get ${k%%:*} ${k#*:})\";"
    done
    cmd="$cmd echo \"deviceidle deep \$(dumpsys deviceidle enabled deep)\"; echo \"deviceidle light \$(dumpsys deviceidle enabled light)\""
    dsh "$cmd"
}


apply_settings() {
    SETTINGS_FILE=$OUT/device-settings.orig
    pending=$CORPUS/results/.tv-settings-pending-$(echo "${SERIAL:-default}" | tr -c 'A-Za-z0-9_.-' '_')
    if [ $DRY = 0 ] && [ -f "$pending" ] && [ -s "$(cat "$pending")" ]; then
        prev=$(cat "$pending")
        warn "a previous run did not restore the TV settings; keeping its originals from $prev"
        [ "$prev" != "$SETTINGS_FILE" ] && cp "$prev" "$SETTINGS_FILE"
    elif [ $DRY = 0 ]; then
        settings_get_all > "$SETTINGS_FILE.tmp" || die_lost "reading settings"
        grep -c . "$SETTINGS_FILE.tmp" | grep -qv '^0$' || die "could not read the TV settings"
        mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    else
        settings_get_all > /dev/null
    fi
    [ $DRY = 0 ] && echo "$SETTINGS_FILE" > "$pending"
    SETTINGS_APPLIED=1

    dsh 'svc power stayon true; settings put secure sleep_timeout -1; settings put secure screensaver_enabled 0; settings put secure screensaver_activate_on_sleep 0; settings put system screen_off_timeout 2147483647; dumpsys deviceidle disable > /dev/null' > /dev/null
    [ $DRY = 1 ] && return 0

    settings_get_all > "$OUT/device-settings.applied"
    SETTINGS_REPORT=$(awk '
        FNR == NR { orig[$1 " " $2] = $3; next }
        {
            k = $1 " " $2
            want["global stay_on_while_plugged_in"] = "7"; want["secure sleep_timeout"] = "-1"
            want["secure screensaver_enabled"] = "0"; want["secure screensaver_activate_on_sleep"] = "0"
            want["system screen_off_timeout"] = "2147483647"
            want["deviceidle deep"] = "0"; want["deviceidle light"] = "0"
            ok = ($3 == want[k]) ? "ok" : "NOT APPLIED"
            printf "  %-45s %-11s -> %-11s %s\n", k, orig[k], $3, ok
        }' "$SETTINGS_FILE" "$OUT/device-settings.applied")
    SETTINGS_BAD=$(echo "$SETTINGS_REPORT" | grep -c 'NOT APPLIED')
    if [ $INTERACTIVE = 1 ]; then
        { echo "power settings (original -> now):"; echo "$SETTINGS_REPORT"; } >> "$RUNLOG"
    else
        log "power settings (original -> now):"
        say "$SETTINGS_REPORT"
    fi
    [ "$SETTINGS_BAD" -gt 0 ] && [ $INTERACTIVE = 0 ] &&
        warn "$SETTINGS_BAD power setting(s) did not take; the TV may sleep during the run"
    return 0
}

# restore_settings FILE: tolerate a missing device (one reconnect attempt).
restore_settings() {
    f=$1
    [ -s "$f" ] || { warn "no saved settings in $f"; return 1; }
    if [ $DRY = 0 ] && [ "$(adb_state)" != device ]; then
        log "restore: device not connected, trying to reconnect once"
        adb_connect_once
        if [ "$(adb_state)" != device ]; then
            warn "TV settings NOT restored (device unreachable). Later run:
    $0 -s ${SERIAL:-<TV_IP>:5555} --restore-settings $f"
            return 1
        fi
    fi
    cmd=$(awk '
        $1 == "deviceidle" { if ($3 == "1") printf "dumpsys deviceidle enable %s > /dev/null; ", $2
                             else if ($3 == "0") printf "dumpsys deviceidle disable %s > /dev/null; ", $2; next }
        NF < 3 || $3 == "null" { printf "settings delete %s %s > /dev/null; ", $1, $2; next }
        { printf "settings put %s %s %s; ", $1, $2, $3 }' "$f")
    NO_RECONNECT=1
    if dsh "$cmd" > /dev/null; then
        now=$(settings_get_all)
        if [ "$(echo "$now" | sort)" = "$(sort "$f")" ]; then
            log "TV settings restored from $f"
        else
            warn "TV settings restored with differences:"
            echo "$now" | diff "$f" - | sed 's/^/    /' >&2
        fi
        for p in "$CORPUS"/results/.tv-settings-pending-*; do
            [ -f "$p" ] && [ "$(cat "$p")" = "$f" ] && rm -f "$p"
        done
        SETTINGS_APPLIED=0
        NO_RECONNECT=0
        return 0
    fi
    NO_RECONNECT=0
    warn "TV settings NOT restored. Later run: $0 -s ${SERIAL:-<TV_IP>:5555} --restore-settings $f"
    return 1
}


# ---------------------------------------------------------------------------
# Target hooks

target_init() {
    ADB="adb"
    [ -n "$SERIAL" ] && ADB="adb -s $SERIAL"
    DEV_DIR=${DEV_DIR:-/data/local/tmp/vc1bench}
    POLL=${POLL:-5}
    MD5FPS=60 PUSH_BPS=6000000   # estimate model: framemd5 speed, push rate (bytes/s)
}

target_probe() {
    MODEL=$(dsh 'getprop ro.product.model')
    ABILIST=$(dsh 'getprop ro.product.cpu.abilist')
    [ -z "$MODEL" ] && MODEL=dryrun
    return 0
}

target_label() { echo "adb ${SERIAL:-default}"; }

target_device_info() {
    dsh 'echo "release: $(getprop ro.build.version.release) sdk: $(getprop ro.build.version.sdk)"
                 echo "fingerprint: $(getprop ro.build.fingerprint)"
                 echo "board: $(getprop ro.board.platform) hardware: $(getprop ro.hardware)"
                 echo "nproc: $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo) (possible: $(cat /sys/devices/system/cpu/possible 2>/dev/null) online: $(cat /sys/devices/system/cpu/online 2>/dev/null))"
                 echo "--- uname"; uname -a
                 echo "--- meminfo"; head -3 /proc/meminfo
                 echo "--- df /data/local/tmp"; df /data/local/tmp
                 echo "--- power"; dumpsys power | grep -E "mWakefulness=|Display Power"
                 echo "--- cpufreq"
                 for c in /sys/devices/system/cpu/cpu[0-9]*; do
                     echo "$(basename $c): online=$(cat $c/online 2>/dev/null) gov=$(cat $c/cpufreq/scaling_governor 2>/dev/null) cur=$(cat $c/cpufreq/scaling_cur_freq 2>/dev/null) max=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null) min=$(cat $c/cpufreq/cpuinfo_min_freq 2>/dev/null)"
                 done
                 echo "--- thermal"
                 for z in /sys/class/thermal/thermal_zone*; do
                     echo "$(basename $z): type=$(cat $z/type 2>/dev/null) temp=$(cat $z/temp 2>/dev/null)"
                 done
                 echo "--- cpuinfo"; cat /proc/cpuinfo'
}

target_cpu_probe() {
    NCPU=$(dsh 'nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo' | tr -dc 0-9)
    MAXFREQ=$(dsh 'cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null' |
        awk '{ v = int($1 / 1000); if (v > m) m = v } END { print (m ? m : "na") }')
}

target_job_tools() {
    TO= SETSID=
    if [ $DRY = 1 ] || dsh 'timeout 2 true && echo ok' | grep -q '^ok$'; then TO="timeout $TIMEOUT"; fi
    if [ $DRY = 1 ] || dsh 'command -v setsid > /dev/null && echo ok' | grep -q '^ok$'; then SETSID=setsid; fi
    [ -z "$TO" ] && log "no timeout command on the device; the host enforces --timeout"
    return 0
}

target_checklist() {
    cat >&2 <<EOF

==== VC-1 TV benchmark: before you start ====

On the device (Android TV or similar):
  1. Settings > Device Preferences > About: select 'Build' 7 times (developer mode).
  2. Settings > Device Preferences > Developer options: turn on 'USB debugging'
     and 'Network debugging' if listed.
  3. Settings > Power > any idle/standby timer: Off. (Vendor timers are not covered by
     the Android settings this script changes.)
  4. Screen saver off (Settings > Device Preferences > Screen saver), optional:
     the script also disables it for the run and restores it afterwards.
  5. Prefer Ethernet: each clip (up to ~400 MB) is copied to the TV.
  6. Note the TV's IP: Settings > Network & Internet.

EOF
    pause "Press Enter when done..."
}

# The only key event this script sends; never SLEEP/POWER, and not per clip,
# which would undo the user's "Picture off".
target_wake() {
    [ $NO_WAKE = 0 ] && dsh 'input keyevent KEYCODE_WAKEUP' > /dev/null
    return 0
}

target_validate_report() {
    dsh 'echo "  model:    $(getprop ro.product.manufacturer) $(getprop ro.product.model)"
             echo "  Android:  $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
             echo "  abilist:  $(getprop ro.product.cpu.abilist)"
             echo "  cpu:      $(grep -m1 -E "^(Hardware|model name|Processor)" /proc/cpuinfo | cut -d: -f2-) x$(grep -c ^processor /proc/cpuinfo)"
             echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)  cur/max: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo ?)/$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo ?) kHz"
             echo "  temps:    $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr "\n" " ")"
             echo "  free:     $(df -h /data/local/tmp | tail -1)"
             echo "  power:    $(dumpsys power | grep -E "mWakefulness=|Display Power" | tr -s " " | tr "\n" " ")"' >&2
    say "  using:    $ABI binaries"
    say "  power settings (original -> now):"
    say "${SETTINGS_REPORT:-  (dry run)}"
    if [ "${SETTINGS_BAD:-0}" -gt 0 ]; then
        warn "$SETTINGS_BAD power setting(s) did not take; the TV may sleep during the run. Check that any idle/standby timer is Off."
    fi
}

target_picture_prompt() {
    if [ $INTERACTIVE = 1 ] && [ $NO_WAKE = 0 ]; then
        say ""
        say "Now is a good time to turn the picture off: remote Action Menu (or Quick Settings) > Picture off."
        pause "Press Enter when done..."
        check_awake "after picture off" || confirm "The TV does not report itself awake. Continue anyway?" n || exit 1
    fi
}

target_done_message() {
    say "Press any remote button to turn the picture back on."
}
