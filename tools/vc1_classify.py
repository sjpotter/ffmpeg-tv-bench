#!/usr/bin/env python3
"""Classify the VC-1 Advanced-profile elementary stream inside a clip.

For .m2ts (192-byte BDAV packets) the video PID (default 0x1011) is demuxed
directly. For other containers the ES is dumped with
`ffmpeg -c copy -f rawvideo -`, which emits start-code-delimited VC-1 packets.

Counts BDU start codes (0x0F seq hdr, 0x0E entry point, 0x0D frame,
0x0C field, 0x0B slice), parses the sequence header, and when INTERLACE=1
reads the FCM VLC of every frame header (0 = progressive,
10 = frame-interlaced, 11 = field-interlaced).

Usage: vc1_classify.py [--pid 0x1011] CLIP [CLIP...]   -> one JSON line per clip
"""
import argparse
import json
import os
import subprocess
import sys


def demux_m2ts(path, pid):
    out = []
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 192
    started = False
    for i in range(n):
        p = i * 192 + 4
        if data[p] != 0x47:
            raise ValueError("lost TS sync at packet %d" % i)
        b1, b2, b3 = data[p + 1], data[p + 2], data[p + 3]
        if ((b1 & 0x1F) << 8 | b2) != pid:
            continue
        pusi = b1 & 0x40
        afc = (b3 >> 4) & 3
        q = p + 4
        if afc & 2:
            q += 1 + data[q]
        if not afc & 1:
            continue
        end = p + 188
        if pusi:
            if data[q:q + 3] != b"\x00\x00\x01":
                raise ValueError("bad PES start at packet %d" % i)
            q += 9 + data[q + 8]
            started = True
        if started and q < end:
            out.append(data[q:end])
    return b"".join(out)


def demux_ffmpeg(path, ffmpeg):
    cmd = [ffmpeg, "-nostdin", "-v", "error", "-i", path, "-map", "0:v:0",
           "-c", "copy", "-f", "rawvideo", "-"]
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout


def unescape(buf):
    out = bytearray()
    zeros = 0
    for b in buf:
        if zeros >= 2 and b == 3:
            zeros = 0
            continue
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


class Bits:
    def __init__(self, buf):
        self.buf, self.pos = buf, 0

    def get(self, n):
        v = 0
        for _ in range(n):
            byte = self.buf[self.pos >> 3] if (self.pos >> 3) < len(self.buf) else 0
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v


def parse_seq(buf):
    b = Bits(unescape(buf[:24]))
    s = {}
    for name, n in (("profile", 2), ("level", 3), ("colordiff", 2),
                    ("frmrtq", 3), ("bitrtq", 5), ("postprocflag", 1),
                    ("max_coded_width", 12), ("max_coded_height", 12),
                    ("pulldown", 1), ("interlace", 1), ("tfcntrflag", 1),
                    ("finterpflag", 1), ("reserved", 1), ("psf", 1)):
        s[name] = b.get(n)
    s["max_coded_width"] = (s["max_coded_width"] + 1) * 2
    s["max_coded_height"] = (s["max_coded_height"] + 1) * 2
    return s


PTYPE = {0: "P", 2: "B", 6: "I", 14: "BI", 15: "skip"}
FPTYPE = ["I/I", "I/P", "P/I", "P/P", "B/B", "B/BI", "BI/B", "BI/BI"]


def pic_type(b, field):
    if field:
        return FPTYPE[b.get(3)]
    v = 0
    for _ in range(4):
        v = (v << 1) | b.get(1)
        if v in PTYPE:
            return PTYPE[v]
    return "?"


def classify(es):
    counts = {0x0F: 0, 0x0E: 0, 0x0D: 0, 0x0C: 0, 0x0B: 0}
    other = 0
    seq = None
    fcm = {"progressive": 0, "frame_interlaced": 0, "field_interlaced": 0}
    first_unit = None
    first_pic = None
    leading = 0
    i = es.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(es):
        sc = es[i + 3]
        body = es[i + 4:i + 28]
        if first_unit is None:
            first_unit = "0x%02X" % sc
        if sc in counts:
            counts[sc] += 1
        else:
            other += 1
        if sc == 0x0F:
            s = parse_seq(body)
            if seq is None:
                seq = s
        elif sc == 0x0D and seq is None:
            leading += 1
        elif sc == 0x0D:
            b = Bits(unescape(body))
            kind, field = "progressive", False
            if seq["interlace"]:
                if b.get(1):
                    if b.get(1):
                        kind, field = "field_interlaced", True
                    else:
                        kind = "frame_interlaced"
            fcm[kind] += 1
            if first_pic is None:
                first_pic = pic_type(b, field)
        i = es.find(b"\x00\x00\x01", i + 4)
    frames = counts[0x0D]
    pics = frames + counts[0x0C]
    return {
        "es_bytes": len(es),
        "seq_headers": counts[0x0F],
        "entry_points": counts[0x0E],
        "frames": frames,
        "field_start_codes": counts[0x0C],
        "slice_start_codes": counts[0x0B],
        "other_start_codes": other,
        "progressive_pics": fcm["progressive"],
        "frame_interlaced_pics": fcm["frame_interlaced"],
        "field_interlaced_pics": fcm["field_interlaced"],
        "slices_per_pic": round((pics + counts[0x0B]) / pics, 3) if pics else 0,
        "frames_before_first_seq_header": leading,
        "first_unit": first_unit,
        "first_pic_type": first_pic,
        "seq": seq,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", default="0x1011")
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("clips", nargs="+")
    a = ap.parse_args()
    for c in a.clips:
        if c.lower().endswith(".m2ts"):
            es = demux_m2ts(c, int(a.pid, 0))
        else:
            es = demux_ffmpeg(c, a.ffmpeg)
        r = classify(es)
        r["clip"] = os.path.basename(c)
        print(json.dumps(r), flush=True)


if __name__ == "__main__":
    sys.exit(main())
