#!/usr/bin/env python3
"""Scan a whole VC-1 m2ts (PID 0x1011) and report, per 10 s bucket of PTS
relative to the first video PTS, how many frames are field-interlaced
(FCM=11). Assumes INTERLACE=1 and that each frame start code (0x0D) sits in
the first TS packet of its PES, which holds for these Blu-ray streams.

Usage: scan_fields.py FILE.m2ts > out.json
"""
import json
import sys

VPID = 0x1011
WRAP = 1 << 33


def main():
    path = sys.argv[1]
    buckets = {}
    first = None
    with open(path, "rb") as f:
        while True:
            chunk = f.read(192 * 16384)
            if len(chunk) < 192:
                break
            for i in range(len(chunk) // 192):
                p = i * 192 + 4
                b1 = chunk[p + 1]
                if not b1 & 0x40 or ((b1 & 0x1F) << 8 | chunk[p + 2]) != VPID:
                    continue
                q = p + 4
                if (chunk[p + 3] >> 4) & 2:
                    q += 1 + chunk[q]
                if not chunk[q + 7] & 0x80:
                    continue
                b = chunk[q + 9:q + 14]
                pts = (((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 |
                       b[3] << 7 | b[4] >> 1)
                if first is None:
                    first = pts
                pl = chunk[q + 9 + chunk[q + 8]:p + 188]
                j = pl.find(b"\x00\x00\x01\x0d")
                if j < 0 or j + 4 >= len(pl):
                    continue
                hdr = pl[j + 4]
                fcm = "field" if hdr & 0xC0 == 0xC0 else ("frame" if hdr & 0x80 else "prog")
                sec = ((pts - first) % WRAP) // 90000
                k = int(sec // 10 * 10)
                c = buckets.setdefault(k, {"field": 0, "frame": 0, "prog": 0})
                c[fcm] += 1
    json.dump({"first_pts": first, "buckets": {str(k): v for k, v in sorted(buckets.items())}},
              sys.stdout, indent=0)


if __name__ == "__main__":
    main()
