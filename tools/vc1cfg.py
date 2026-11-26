"""Shared configuration for the corpus tools.

Layout (everything below CORPUS is user data and is never committed):

    $CORPUS/clips/      cut clips (<name>_<kind>_<start_second>.m2ts|.mkv)
    $CORPUS/ref/        reference framemd5 files, one per clip
    $CORPUS/work/       intermediate JSON (samples.json, clips.json, classify.jsonl)
    $CORPUS/manifest.csv

CORPUS defaults to the repository root and can be set with the CORPUS
environment variable. The list of source files comes from a local config file
(default config/titles.py, override with VC1_TITLES); copy
config/titles.example.py to start. The source root can be overridden with
VC1_SOURCE_ROOT.
"""
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CORPUS = os.path.abspath(os.environ.get("CORPUS") or REPO)
CLIPS = os.path.join(CORPUS, "clips")
REF = os.path.join(CORPUS, "ref")
WORK = os.path.join(CORPUS, "work")
TMP = os.path.join(WORK, "tmp")


def load_titles():
    """Return (source_root, titles) from the local titles config."""
    path = os.environ.get("VC1_TITLES") or os.path.join(REPO, "config", "titles.py")
    if not os.path.isfile(path):
        sys.exit("missing %s\n  copy config/titles.example.py to config/titles.py and edit it "
                 "(or point VC1_TITLES at your own file)" % path)
    ns = runpy.run_path(path)
    src = os.environ.get("VC1_SOURCE_ROOT") or ns.get("SRC")
    if not src:
        sys.exit("%s defines no SRC and VC1_SOURCE_ROOT is not set" % path)
    return src, ns["TITLES"]
