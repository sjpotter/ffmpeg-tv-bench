# Copy to config/titles.py (git-ignored) and edit. Used by tools/sample_bitrate.py
# and tools/make_manifest.py. Point VC1_TITLES at another file to override the
# location. The source root can also come from the VC1_SOURCE_ROOT env var.
#
# You must supply the VC-1 sources yourself; this repository contains none.

# Directory that the paths below are relative to.
SRC = "/path/to/your/vc1/sources"

# (name, path relative to SRC, "<interlace mode> <fps>"[, option])
#   name:  short label used in clip names (<name>_<kind>_<start_second>);
#          use letters and digits only, no underscores
#   mode:  progressive | interlaced
#   fps:   one of 29.97, 25, 24, 23.976
#   option (optional): "start-only" = do not sample bitrate; cut from the start only
TITLES = [
    ("Sample1", "disc1/BDMV/STREAM/00000.m2ts", "interlaced 29.97"),
    ("Sample2", "disc2/BDMV/STREAM/00001.m2ts", "progressive 23.976"),
    ("Sample3", "sample3.mkv", "interlaced 25"),
    ("Sample4", "disc4/BDMV/STREAM/00002.m2ts", "progressive 24", "start-only"),
]
