# ffmpeg-tv-bench

A harness for benchmarking and bit-exact verification of FFmpeg's VC-1 decoder
on Android devices and macOS, single-threaded and frame-threaded.

It exists to answer two questions about a decoder change on real hardware:
does it still produce bit-identical output on every kind of VC-1 stream
(progressive, frame-interlaced, field-interlaced, many slices per picture), and
how much faster is it at 1, 2, 3, 4 threads on slow ARM cores that an
x86 or Apple Silicon workstation cannot represent?

## Important: no media included

**This repository contains no video clips and no reference data**, and it never
redistributes copyrighted material. You must supply your own VC-1 sources
(for example Blu-ray rips you own). Clips and references are derived from those
sources, stay on your machine, and are excluded by `.gitignore`. Keep them
private.

## Contents

| path | what |
|---|---|
| `tools/` | corpus preparation: `sample_bitrate.py`, `cut_clips.py`, `vc1_classify.py`, `scan_fields.py`, `make_refs.sh`, `make_manifest.py`, `validate_mac.sh` |
| `android/` | `build_android.sh` (cross-build reduced ffmpeg), `tv_bench.sh` (device harness), see `android/README.md` |
| `test/` | `smoke.sh` and `fake-adb/adb`: run the harness with no device |
| `config/` | `*.example` files; your real config is copied next to them and is git-ignored |

## Requirements

- macOS with bash 3.2+, python3, `ffmpeg` and `ffprobe` (for cutting and tools)
- ffmpeg source worktrees, one per variant to compare (for example a baseline
  and a branch under test)
- Android NDK (r26 or later; `ANDROID_NDK_HOME`) for the device builds
- `adb`, and an Android device with developer mode and network or USB debugging
- your own VC-1 sources (Blu-ray `.m2ts` or Matroska `.mkv`)

Optional: `shellcheck` for linting the shell scripts.

## Directory layout

Everything the tools read or write lives under `$CORPUS` (default: the repo
root, which `.gitignore` protects):

```
$CORPUS/clips/         cut clips: <name>_<kind>_<start_second>.m2ts|.mkv
$CORPUS/ref/           reference framemd5 + .errors.txt per clip
$CORPUS/work/          samples.json, clips.json, classify.jsonl, tmp/
$CORPUS/manifest.csv   per-clip metadata
$CORPUS/results/       benchmark output
$CORPUS/baseline-build/ffmpeg   baseline ffmpeg used for references (or set FFMPEG)
```

Clip names are `<name>_<kind>_<start_second>`: `name` is the label from your
titles config, `kind` is `peak`, `calm`, `mid` (or `start`), and the number is
the start offset in the source in whole seconds, e.g. `Sample1_peak_2093.m2ts`.

## Workflow

### 1. Configure

```sh
cp config/titles.example.py config/titles.py        # your sources: name, path, interlace, fps
cp config/clips.default.example config/clips.default # which clips a normal run uses
export CORPUS=$PWD        # or any directory with enough space
```

Optionally `cp config/local.env.example config/local.env` (variant names, default
variants, comparison pairs) and `cp config/worktrees.example config/worktrees`
(variant name to ffmpeg source tree map for `build_android.sh`).
`config/titles.py`, `config/clips.default`, `config/local.env` and `config/worktrees`
are git-ignored. Tools exit with a
message pointing at the example when they are missing. `VC1_TITLES`,
`VC1_SOURCE_ROOT` and `VC1_CLIPS_DEFAULT` override locations.

### 2. Cut clips

```sh
python3 tools/sample_bitrate.py        # 12 evenly spaced 20 s windows per source -> work/samples.json
python3 tools/cut_clips.py             # pick peak/calm/mid windows and cut ~90 s clips
python3 tools/cut_clips.py Sample1:peak:1200   # or add an explicit NAME:KIND:OFFSET
```

`sample_bitrate.py` measures the video bitrate over windows of each source.
`cut_clips.py` chooses a `mid` window (middle of the source), the highest-bitrate
`peak` window and the lowest-bitrate `calm` window (at least 100 s apart), so
the set covers both easy and demanding material. Cuts are video-only and
lossless (stream copy).

**Entry-point aware cutting.** A VC-1 Advanced profile stream can only be
decoded from a picture preceded by a sequence header (and its entry point).
In `.m2ts` sources libavformat flags every I picture as a keyframe but does not
flag all entry-point pictures, and `ffmpeg -ss` can land on a packet with no
sequence header, producing a clip that does not start decodably or decodes
differently from a continuous decode. So the m2ts cut is done in two lossless
steps: (1) locate the first video PES at or after the nominal start whose
payload carries a sequence header and copy whole 192-byte packets (video, PMT
and PCR PIDs, with PAT/PMT prepended) from there for about 95 s; (2) remux that
with `-fflags +noparse+nofillin -c copy -copyinkf -t 90 -mpegts_m2ts_mode 1`,
where `noparse` keeps one PES per source PES so the VC-1 parser does not split
field pairs at field-level user data. Matroska sources use a plain
`-ss ... -c copy` because Matroska keyframe flags are real random access points.
The actual start second is encoded in the clip name.

### 3. Classify and make reference framemd5

```sh
python3 tools/vc1_classify.py "$CORPUS"/clips/* > "$CORPUS/work/classify.jsonl"
FFMPEG=/path/to/baseline/ffmpeg tools/make_refs.sh     # clips/* -> ref/<clip>.framemd5
python3 tools/make_manifest.py                         # -> manifest.csv
```

`vc1_classify.py` counts BDU start codes and reads sequence/frame headers
(progressive, frame-interlaced and field-interlaced pictures, slices per
picture). References come from a trusted baseline ffmpeg build decoding with
`-threads 1 -f framemd5`; every other build and thread count is compared to
them frame by frame. `scan_fields.py` is an extra helper that reports field-
interlaced frames per 10 s bucket of a whole m2ts. `.errors.txt` files record
decoder messages for the baseline decode (non-empty means the stream itself has
errors; the manifest records the count).

### 4. Build the variants

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk
android/build_android.sh base=$HOME/src/ffmpeg-base threaded=$HOME/src/ffmpeg-mt
```

Each variant name maps to `${FFMPEG_WORKTREES:-$HOME/git/ffmpeg-worktrees}/<name>`
unless `name=/path` is given. Output: `android/bin/ffmpeg-<variant>-<target>`
for armeabi-v7a, arm64-v8a and macos (`-- armeabi-v7a macos` selects targets).
The component set is deliberately reduced (VC-1/WMV3 decoder and parser,
mpegts/matroska/vc1 demuxers, null/framemd5 muxers, rawvideo and scale for
output), which keeps the binaries small and static. The variant names `base`
(single-threaded reference) and `threaded` are what `tv_bench.sh` expects by
default; any other names work with `--variants`. A common convention is
`up-*` for variants prepared for upstream submission and `research-*` for local
experiments, but nothing depends on it.

Optionally check the macOS build against the references on the host first:

```sh
tools/validate_mac.sh android/bin/ffmpeg-threaded-macos results/mac verify
```

### 5. Benchmark and verify on a device

```sh
android/tv_bench.sh -s HOST:5555 --quick
```

See `android/README.md` for what the script does to the device, its safety
features (`--no-wake`, saved and restored device settings, pause file,
cool-downs, reconnect handling), options and the layout of `results/`.

## Testing the harness without a device

```sh
test/smoke.sh
```

runs `android/tv_bench.sh --dry-run` and a complete run against `test/fake-adb`
using stub binaries and a synthetic corpus. It needs no clips and no device and
checks the harness logic only, not any decoder.
