#!/usr/bin/env python3
"""Choose peak/calm/mid windows from samples.json and cut 90 s video-only
stream-copy clips into $CORPUS/clips. Writes $CORPUS/work/clips.json.

m2ts sources: libavformat flags every I picture as a keyframe (and does not
flag the entry-point pictures of some streams), and `ffmpeg -ss` lands on a packet that
lacks a sequence header. So the cut is done in two lossless steps:
  1. locate the first video PES at/after the nominal start whose payload
     carries a sequence header (0x0F) and copy whole 192-byte packets of the
     video, PMT and PCR PIDs from there for ~95 s (PAT/PMT prepended);
  2. remux that with `ffmpeg -fflags +noparse+nofillin -i ... -c copy
     -copyinkf -t 90 -f mpegts -mpegts_m2ts_mode 1`. noparse keeps one PES per
     source PES; the VC-1 parser would otherwise split field pairs at the
     field-level user data (0x1C) that sits between the two fields.
mkv sources: plain `ffmpeg -ss T -i SRC -t 90 -c copy` (Matroska keyframe
flags are real random access points).

Usage: cut_clips.py [NAME:KIND:OFFSET ...]   (append explicit clips)
"""
import json
import os
import subprocess
import sys

import vc1cfg

CLIPS = vc1cfg.CLIPS
TMP = vc1cfg.TMP
LEN = 90.0
GAP = 100.0
VPID = 0x1011
WRAP = 1 << 33


def first_pos(path, abs_t):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-read_intervals", "%.3f%%+#1" % abs_t,
                          "-show_entries", "packet=pos", "-of", "csv=p=0", path],
                         check=True, capture_output=True, text=True).stdout
    return int(out.split()[0].strip(","))


def pes_ts(b):
    return (((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 |
            b[3] << 7 | b[4] >> 1)


def pid_of(pkt):
    return (pkt[5] & 0x1F) << 8 | pkt[6]


def psi_packets(path):
    """First PAT and PMT packets of the file, plus PMT and PCR PIDs."""
    with open(path, "rb") as f:
        d = f.read(192 * 20000)
    pat = pmt = None
    pmt_pid = pcr_pid = None
    for i in range(len(d) // 192):
        pkt = d[i * 192:(i + 1) * 192]
        pid = pid_of(pkt)
        if pid == 0 and pat is None and pkt[5] & 0x40:
            s = pkt[8 + pkt[8] + 1:]
            for j in range(8, 3 + ((s[1] & 0xF) << 8 | s[2]) - 4, 4):
                prog = s[j] << 8 | s[j + 1]
                if prog:
                    pmt_pid = (s[j + 2] & 0x1F) << 8 | s[j + 3]
                    break
            pat = pkt
        elif pmt_pid is not None and pid == pmt_pid and pkt[5] & 0x40:
            s = pkt[8 + pkt[8] + 1:]
            pcr_pid = (s[8] & 0x1F) << 8 | s[9]
            pmt = pkt
            break
    if pat is None or pmt is None:
        raise RuntimeError("PAT/PMT not found")
    return pat + pmt, {0, pmt_pid, pcr_pid, VPID}


def extract_m2ts(src, pos, tmp_out):
    """Copy packets starting at the first seq-header PES at/after pos."""
    head, keep = psi_packets(src)
    start_pts = None
    with open(src, "rb") as f, open(tmp_out, "wb") as o:
        o.write(head)
        f.seek(max(0, pos - pos % 192 - 192 * 64))
        while True:
            chunk = f.read(192 * 8192)
            if len(chunk) < 192:
                return start_pts
            out = []
            for i in range(len(chunk) // 192):
                pkt = chunk[i * 192:(i + 1) * 192]
                if pkt[4] != 0x47:
                    raise RuntimeError("TS sync lost")
                pid = pid_of(pkt)
                if pid not in keep:
                    continue
                if pid == VPID and pkt[5] & 0x40:
                    q = 8
                    if (pkt[7] >> 4) & 2:
                        q += 1 + pkt[q]
                    pts = pes_ts(pkt[q + 9:q + 14]) if pkt[q + 7] & 0x80 else None
                    if start_pts is None:
                        if pts is not None and b"\x00\x00\x01\x0f" in pkt[q + 9 + pkt[q + 8]:]:
                            start_pts = pts
                    elif pts is not None and \
                            (pts - start_pts + WRAP // 2) % WRAP - WRAP // 2 > (LEN + 5) * 90000:
                        o.write(b"".join(out))
                        return start_pts
                if start_pts is not None:
                    out.append(pkt)
            o.write(b"".join(out))


def cut(t, kind, off):
    src = t["path"]
    os.makedirs(TMP, exist_ok=True)
    common = ["-t", "%g" % LEN, "-map", "0:v:0", "-an", "-sn", "-dn", "-c", "copy"]
    if src.endswith(".m2ts"):
        tmp = os.path.join(TMP, "cut.m2ts")
        pts = extract_m2ts(src, first_pos(src, t["start_time"] + off), tmp)
        ss = round((pts - round(t["start_time"] * 90000)) % WRAP / 90000.0, 3)
        name = "%s_%s_%d.m2ts" % (t["name"], kind, int(ss))
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y",
               "-fflags", "+noparse+nofillin", "-i", tmp] + common + \
              ["-copyinkf", "-f", "mpegts", "-mpegts_m2ts_mode", "1"]
    else:
        ss = round(off, 3)
        name = "%s_%s_%d.mkv" % (t["name"], kind, int(ss))
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", "%.3f" % ss,
               "-i", src] + common
    subprocess.run(cmd + [os.path.join(CLIPS, name)], check=True)
    if src.endswith(".m2ts"):
        os.remove(tmp)
    print(name, flush=True)
    return {"clip": name, "title": t["name"], "source_path": src,
            "container": name.rsplit(".", 1)[1], "start_s": ss, "kind": kind,
            "nominal_offset": round(off, 3)}


def choose(t):
    d = t["duration"]
    if not t["samples"]:
        return [("start", 0.0)]
    picks = [("mid", 0.5 * d)]
    ranked = sorted(t["samples"], key=lambda s: s["bytes"])
    for kind, order in (("peak", ranked[::-1]), ("calm", ranked)):
        for s in order:
            if all(abs(s["offset"] - o) >= GAP for _, o in picks):
                picks.append((kind, s["offset"]))
                break
    return picks


def main():
    os.makedirs(CLIPS, exist_ok=True)
    os.makedirs(vc1cfg.WORK, exist_ok=True)
    titles = {t["name"]: t for t in json.load(open(os.path.join(vc1cfg.WORK, "samples.json")))}
    jpath = os.path.join(vc1cfg.WORK, "clips.json")
    if len(sys.argv) > 1:
        done = json.load(open(jpath))
        jobs = [tuple(a.split(":")) for a in sys.argv[1:]]
    else:
        done = []
        jobs = [(n, k, o) for n, t in titles.items() for k, o in choose(t)]
    for name, kind, off in jobs:
        done.append(cut(titles[name], kind, float(off)))
        json.dump(done, open(jpath, "w"), indent=1)


if __name__ == "__main__":
    main()
