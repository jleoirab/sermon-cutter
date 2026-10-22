#!/bin/bash
# Times a 5-minute stretch of a downloaded stream through the export's ffmpeg
# command and a few variants of it. Run by build.sh when .bench exists.
# Writes only into ~/Movies/SermonCutter/bench and removes what it wrote.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/target/release/sermoncut"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
WORK="$HOME/Movies/SermonCutter"
VIDEO="${BENCH_VIDEO:-$WORK/iz0PPVUleUw.video.mp4}"
START="${BENCH_START:-5400}"
LEN="${BENCH_LEN:-300}"
DIR="$WORK/bench"
mkdir -p "$DIR"
trap 'rm -f "$DIR"/bench-*.mp4 "$DIR"/banner.png; rmdir "$DIR" 2>/dev/null' EXIT

echo "== bench: $(basename "$VIDEO"), $LEN s from $START s"
ffmpeg -version | head -1
sysctl -n machdep.cpu.brand_string
[ -f "$VIDEO" ] || { echo "no video at $VIDEO"; exit 1; }
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=0x2a6b4f:s=1920x1080" -frames:v 1 "$DIR/banner.png"

args() { # $1 = output, rest = extra render options
  local out="$1"; shift
  "$ENGINE" render --source "$VIDEO" --banner "$DIR/banner.png" --in "$START" --out "$((START + LEN))" \
    -o "$out" --overwrite --print-ffmpeg "$@" | grep '"step":"ffmpeg"'
}
args "$DIR/bench-x.mp4" > "$DIR/with-banner.json"
args "$DIR/bench-x.mp4" --open-hold 0 --close-hold 0 --dissolve 0 > "$DIR/no-banner.json"

python3 - "$DIR" "$LEN" <<'PY'
import json, subprocess, sys, time, os
d, length = sys.argv[1], float(sys.argv[2])
def load(name):
    return json.loads(open(os.path.join(d, name)).read())["data"]["args"]
base = load("with-banner.json")
plain = load("no-banner.json")
def hw(a):
    i = a.index("-ss")
    return a[:i] + ["-hwaccel", "videotoolbox"] + a[i:]
def prio(a):
    i = a.index("h264_videotoolbox") + 1
    return a[:i] + ["-prio_speed", "1"] + a[i:]
variants = [
    ("as exported today", base),
    ("hardware decode", hw(base)),
    ("prio_speed", prio(base)),
    ("hardware decode + prio_speed", prio(hw(base))),
    ("no banner (encode only)", plain),
]
for n, (name, a) in enumerate(variants):
    out = os.path.join(d, f"bench-{n}.mp4")
    a = a[:-1] + [out]
    t = time.time()
    r = subprocess.run(["ffmpeg"] + a, capture_output=True, text=True)
    el = time.time() - t
    if r.returncode != 0:
        print(f"{name:32s} failed: {r.stderr.strip()[-300:]}")
        continue
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out],
                         capture_output=True, text=True).stdout.strip()
    size = os.path.getsize(out) / 1e6
    full = 4424 / (length / el) / 60
    print(f"{name:32s} {el:6.1f} s  {length/el:5.1f}x  {size:6.1f} MB  dur {dur}  -> 73:44 sermon in {full:4.1f} min")
    if n > 0:
        # Same picture as today's export? SSIM over the first 20 s.
        s = subprocess.run(["ffmpeg", "-hide_banner", "-t", "20", "-i", os.path.join(d, "bench-0.mp4"), "-t", "20", "-i", out,
                            "-lavfi", "ssim", "-f", "null", "-"], capture_output=True, text=True).stderr
        line = [l for l in s.splitlines() if "SSIM" in l]
        print(f"{'':32s} vs today: {line[-1].split('All:')[1].strip() if line else '?'}")
PY
rm -f "$DIR"/*.json
