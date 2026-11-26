#!/usr/bin/env python3
"""Build $CORPUS/manifest.csv from work/clips.json, work/classify.jsonl and
ref/*.errors.txt (see vc1cfg.py for the layout)."""
import csv
import json
import os
import subprocess

import vc1cfg

ROOT = vc1cfg.CORPUS
TITLES = vc1cfg.load_titles()[1]
FPS = {"29.97": "30000/1001", "25": "25", "24": "24", "23.976": "24000/1001"}
NONDETERMINISTIC = set()

COLS = ["clip", "title", "source_path", "container", "start_s", "duration_s", "kind",
        "interlace", "fps", "frames", "progressive_pics", "frame_interlaced_pics",
        "field_interlaced_pics", "slices_per_pic", "avg_mbps", "decode_errors",
        "framemd5_file"]


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def main():
    desc = {t[0]: t[2] for t in TITLES}
    cls = {}
    for line in open(os.path.join(vc1cfg.WORK, "classify.jsonl")):
        r = json.loads(line)
        cls[r["clip"]] = r
    rows = []
    for c in sorted(json.load(open(os.path.join(vc1cfg.WORK, "clips.json"))), key=lambda c: c["clip"]):
        r = cls[c["clip"]]
        base = c["clip"].rsplit(".", 1)[0]
        dur = duration(os.path.join(ROOT, "clips", c["clip"]))
        errs = sum(1 for _ in open(os.path.join(ROOT, "ref", base + ".errors.txt")))
        mode, rate = desc[c["title"]].split()
        err = str(errs)
        if c["title"] in NONDETERMINISTIC:
            err += " (nondeterministic; see README)"
        rows.append({
            "clip": c["clip"], "title": c["title"], "source_path": c["source_path"],
            "container": c["container"], "start_s": c["start_s"],
            "duration_s": round(dur, 3), "kind": c["kind"],
            "interlace": "%s (INTERLACE=%d)" % (mode, r["seq"]["interlace"]),
            "fps": FPS[rate], "frames": r["frames"],
            "progressive_pics": r["progressive_pics"],
            "frame_interlaced_pics": r["frame_interlaced_pics"],
            "field_interlaced_pics": r["field_interlaced_pics"],
            "slices_per_pic": r["slices_per_pic"],
            "avg_mbps": round(r["es_bytes"] * 8 / dur / 1e6, 2),
            "decode_errors": err, "framemd5_file": "ref/%s.framemd5" % base,
        })
    with open(os.path.join(ROOT, "manifest.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, COLS)
        w.writeheader()
        w.writerows(rows)
    for row in rows:
        print(row["clip"], row["kind"], row["progressive_pics"], row["frame_interlaced_pics"],
              row["field_interlaced_pics"], row["avg_mbps"], row["decode_errors"], sep=" | ")


if __name__ == "__main__":
    main()
