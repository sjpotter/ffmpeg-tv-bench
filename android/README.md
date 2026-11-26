# tv_bench.sh: verify and benchmark on an Android device

`tv_bench.sh` runs on a Mac and drives an Android device (an Android TV box or
TV, for example) over adb. For each clip it checks that the VC-1 decoder output
on the device matches the reference framemd5 bit for bit, then measures decode
speed per thread count. Clips are pushed to the device one at a time and are
user-supplied; keep them private.

Layout it expects (`CORPUS` defaults to the repository root):

```
$CORPUS/clips/           clips, <name>_<kind>_<start_second>.m2ts|.mkv
$CORPUS/ref/             <clip>.framemd5 references (tools/make_refs.sh)
$CORPUS/manifest.csv     per-clip metadata (tools/make_manifest.py)
$CORPUS/results/         output, one directory per run
$CORPUS/clip_cost.csv    optional: Mac single-thread fps per clip, for estimates
android/bin/             ffmpeg-<variant>-<abi> (build_android.sh), VC1_BIN overrides
config/clips.default     which clips a normal run and the smoke test use
```

## Device preparation

1. Enable developer mode (Settings > Device Preferences > About > Build, 7 times).
2. Developer options: USB debugging on, network debugging if listed.
3. Turn off any vendor idle/standby timer; the script cannot change those.
4. Note the device IP. Ethernet beats Wi-Fi: every clip is pushed over the link.
5. Keep the Mac on power.

```sh
cp config/clips.default.example config/clips.default   # edit: your clip names
./android/tv_bench.sh -s HOST:5555            # report run (3 runs per level)
./android/tv_bench.sh -s HOST:5555 --quick    # same matrix, 1 run, no smoke test
```

The guided mode (default in a terminal) prints a checklist and connects with
`adb connect`, prints a validation screen (model, Android version, ABI, cores,
free space, binary versions, power settings), runs a smoke test (the "smoke"
clip, all variants, threads 1 and 4, one run; prints PASS or FAIL), then runs
the matrix with one progress line per decode (fps, realtime factor, ETA) and
warnings when temperature rises or a core's clock drops. At the end it restores
the device settings. `--yes` runs the same flow without prompts, `--smoke` runs
only the smoke test. An estimate is printed first, based on
`clip_cost.csv` (180 fps assumed per clip when absent) divided by a slowdown
factor (13 for armv7, 11 for arm64, `--slowdown X` overrides); it is
recalibrated as real runs come in.

Recovering:

```sh
./android/tv_bench.sh -s HOST:5555 --resume                  # continue the newest run
./android/tv_bench.sh -s HOST:5555 --restore-settings results/tv-<...>/device-settings.orig
```

## Targets

`--target NAME` reads `config/targets/NAME.env` (see the top-level README for the
fields, the `local` type and how to add a type). For an adb target,
`SERIAL`, `DEV_DIR`, `NO_WAKE`, `NO_SMOKE`, `COOLDOWN`, `TIMEOUT`,
`RECONNECT_TRIES` and `VARIANTS` set the defaults of the matching options;
command-line options win, and `NO_WAKE=1` in the file makes `--no-wake`
implicit. `-s SERIAL` is unchanged and needs no file. Real target files are
git-ignored; copy `config/targets/adb.env.example`. The adb operations live in
`lib/target-adb.sh`, those of a local target in `lib/target-local.sh`.

## Variants and binaries

A variant is a named ffmpeg build; `bin/ffmpeg-<variant>-<abi>` must exist
(`build_android.sh` creates them). The defaults are two variants:

| variant | meaning |
|---|---|
| `base` | the single-threaded reference build; only run with 1 thread |
| `threaded` | the build under test, run with frame threading at several thread counts |

The names come from `BASE_VARIANT`, `THREADED_VARIANT` and `DEFAULT_VARIANTS`, which can be set in the git-ignored `config/local.env` (see `config/local.env.example`; `VC1_LOCAL_ENV` overrides the path).
Other names work: pass `--variants 'a b c'`. Variants listed in
`SINGLE_VARIANTS` (default `base single`) only run at 1 thread. The summary
adds side-by-side tables for the pairs in `COMPARE_PAIRS` ("new:base ..."
space-separated, default `single:base`).

Builds are minimal static `ffmpeg` CLIs (VC-1/WMV3 decoder, VC-1 parser,
mpegts/matroska/vc1 demuxers, null/framemd5 muxers) for armeabi-v7a, arm64-v8a
and macOS (the macOS build is for `--local` harness tests and for making
references). Each binary needs only `libc.so` and `libm.so`; `bin/*.commit`
records the source commit. Example:

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk
./android/build_android.sh base=$HOME/src/ffmpeg-base threaded=$HOME/src/ffmpeg-mt
# or place worktrees under ${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/<variant>
./android/build_android.sh base threaded -- arm64-v8a macos
```

**ABI.** The script reads `ro.product.cpu.abilist` and uses arm64 only if it is
listed and the binary runs, otherwise armv7; `--abi` forces one. 32-bit ARM
binaries cannot run on Apple Silicon, so the smoke test runs them first on the
device and a problem shows up within minutes.

## What the script does to the device

**Power settings** (changed over adb as the shell user, no root):

| setting | set to |
|---|---|
| global `stay_on_while_plugged_in` | 7 (`svc power stayon true`) |
| secure `sleep_timeout` | -1 |
| secure `screensaver_enabled` | 0 |
| secure `screensaver_activate_on_sleep` | (saved and restored only) |
| system `screen_off_timeout` | 2147483647 |
| deviceidle | `dumpsys deviceidle disable` |

- Original values are saved to `$OUT/device-settings.orig` before anything changes.
- Each setting is read back and reported as `ok` or `NOT APPLIED`.
- An exit trap restores the originals on any exit (normal end, error, Ctrl-C,
  TERM). If adb is down then, it tries one reconnect.
- If the restore cannot complete, the script prints the `--restore-settings`
  command and leaves a marker in `results/.tv-settings-pending-*`; the next run
  uses that marker's originals rather than the already-modified values.
- `--no-wake` leaves the device as it is: no wake key event, no settings
  changes, no picture-off prompt. Power state is only logged. Use it for devices
  that keep running while asleep or that must not be woken. Treat its numbers as
  a possible worst case until awake and asleep runs have been compared.

**Wake key.** `KEYCODE_WAKEUP` is sent once before preflight (unless
`--no-wake`). SLEEP and POWER keys are never sent. Wakefulness is logged before
each clip.

**Detached decodes.** Decodes run detached on the device (`setsid nohup`, under
`/data/local/tmp/vc1bench/jobs/`) and the Mac polls for an exit-code file, so a
decode survives an adb outage.

**Reconnects.** If adb drops, the script reconnects with backoff (5 s up to 60
s, 6 tries; `--reconnect-tries N`) and picks the job back up. A vanished job is
retried once. If the device stays gone it stops and prints the exact `--resume`
command. A per-decode watchdog (`--timeout`, default 1800 s) kills hung decodes.

**Pause and cool-down.** `touch $CORPUS/.tv.pause` (or `$TV_PAUSE_FILE`) pauses
before the next decode; remove it to continue. `--cooldown S` sets the pause
between bench runs (default 10 s).

## Profiles and options

| | verify | bench |
|---|---|---|
| default | `base` at 1 thread; `threaded` at 1, 2 and 4 | `base` at 1; `threaded` at 1, 2, 3 and 4; 3 runs each; 10 s cool-down; smoke test first |
| `--quick` | as default | as default, 1 run each; no smoke test |
| `--clips all` | as default, every clip in `clips/` | |

`--clips 'PATTERN ...'` takes clip names or `<name>_<kind>` prefixes. Without
it, the `default` line of `config/clips.default` is used (override the file with
`VC1_CLIPS_DEFAULT`, or the values with `DEFAULT_CLIPS` / `SMOKE_CLIP`). Other
options: `--threads`, `--verify-threads`, `--runs`, `--variants`,
`--verify-only`, `--bench-only`, `--no-smoke`, `--out`, `--force`, `--dry-run`,
`--local` (run on this Mac with the macOS builds), `--max-frames`; see `--help`.

`--max-frames N` decodes only the first N frames of each clip (`-frames:v N`):
fps is computed from N and verify compares the first N lines of `ref/`. Compare
absolute fps only within one run. Not validated for threaded runs or verify.

`--contention N` also runs N copies of `base` at 1 thread at once per clip; the
summary compares each copy's speed and CPU time with `base` alone, showing
whether cores slow each other through shared cache or memory.

`--resume` reuses the newest `results/tv-<model>-*` directory; `--out DIR` picks
one. Entries that already have a CSV row are skipped; `--force` redoes them.

### Clips kept on the device

Clips stay in `/data/local/tmp/vc1bench/clips` between runs; a later run skips
the copy when the size matches. A clip is kept only if at least 512 MiB stays
free afterwards, otherwise it is deleted after use. `--no-keep-clips` deletes
every clip after use, `--clear-clips` empties the folder at the start.

## Reading the results

`$CORPUS/results/tv-<model>-<YYYYmmdd-HHMMSS>/`:

- `summary.md`: headline table (per clip: base 1-thread fps, threaded 1-thread
  fps, threaded best fps and thread count, realtime factor, verify status),
  verification counts, and the full speed table (median fps, realtime factor,
  speedup against the same variant at 1 thread and against `base`).
- `verify.csv`: `clip, category, variant, abi, threads, exit, status,
  first_diff_frame, ref_frames, out_frames, stderr_lines, wall_s`. Status is
  `match`, `header_only` (only the `#` header differs), `mismatch`
  (`first_diff_frame` is the 0-based index), `no_output`, `timeout` or
  `skipped_nospace`. Any mismatch or non-zero exit at more than 1 thread is the
  important finding; device output is in `framemd5/`, stderr in `logs/`.
- `bench.csv`: one row per run (utime/stime/rtime, maxrss, frames, fps, realtime
  factor, temperature before/peak/after, minimum core MHz before/during/after,
  wall time).
- `device.txt` (getprop, cores, meminfo, df, frequencies, thermal zones,
  cpuinfo), `device-settings.orig` / `.applied`, `run.log`, `smoke/`.

Notes: bench runs use `-v info -nostats -hide_banner` (the `bench:` lines are
info level), verify runs use `-v error`. fps counts the non-header lines of
`ref/<clip>.framemd5`. Background load on the device is not controlled; repeat
runs (default 3) for numbers you intend to report.

## Testing without a device

`test/smoke.sh` (repo root) runs this script against `test/fake-adb/adb`, a
shell test double that emulates the adb commands used, with stub ffmpeg
binaries and a synthetic corpus. The fake adb can also simulate an unauthorized
device (`FAKE_UNAUTH_POLLS`), settings that refuse to change (`FAKE_STUCK_KEYS`),
connection drops (`FAKE_DROP_AT`, `FAKE_DROP_SECS`) and a different ABI list
(`FAKE_ABILIST`); see the header of the script. `./tv_bench.sh --dry-run` prints
the adb commands without running them. The same script also runs the smoke test
for a `local` target.
