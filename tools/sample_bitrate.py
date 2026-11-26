#!/usr/bin/env python3
"""Sample 12 evenly spaced 20 s windows (inside 5%-95%) of each title and
record the summed video packet size. Writes $CORPUS/work/samples.json.

A title whose optional 4th tuple element is "start-only" is not sampled; it
is cut from its start only."""
import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

import vc1cfg

N, WIN = 12, 20.0
SRC, TITLES = vc1cfg.load_titles()


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "format=start_time,duration", "-of", "json", path],
                         check=True, capture_output=True, text=True).stdout
    f = json.loads(out)["format"]
    return float(f["start_time"]), float(f["duration"])


def window_bytes(path, abs_start):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-read_intervals", "%.3f%%+%d" % (abs_start, WIN),
                          "-show_entries", "packet=size", "-of", "csv=p=0", path],
                         check=True, capture_output=True, text=True).stdout
    return sum(int(x.strip(",")) for x in out.split() if x.strip(","))


def do_title(t):
    name, rel, _ = t[:3]
    opt = t[3] if len(t) > 3 else ""
    path = os.path.join(SRC, rel)
    start, dur = probe(path)
    res = {"name": name, "path": path, "start_time": start, "duration": dur, "samples": []}
    if opt == "start-only":
        return res
    lo, hi = 0.05 * dur, 0.95 * dur - WIN
    for i in range(N):
        off = lo + i * (hi - lo) / (N - 1)
        b = window_bytes(path, start + off)
        res["samples"].append({"offset": round(off, 3), "bytes": b,
                               "mbps": round(b * 8 / WIN / 1e6, 2)})
    print(name, [s["mbps"] for s in res["samples"]], flush=True)
    return res


if __name__ == "__main__":
    os.makedirs(vc1cfg.WORK, exist_ok=True)
    with ThreadPoolExecutor(3) as ex:
        results = list(ex.map(do_title, TITLES))
    with open(os.path.join(vc1cfg.WORK, "samples.json"), "w") as f:
        json.dump(results, f, indent=1)
