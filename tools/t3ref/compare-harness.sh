#!/bin/bash
# compare-harness.sh <thread|home> [shots-dir] — the phone's parity number
# from the render harness (T3RenderHarness `parity-*` shots) against
# refs/ios-<screen>.png, the simulator status bar (top 140 px, phone-side
# clock and the T3 client's back indicator) painted over in both before
# compare.py runs. The harness has no status bar; the reference does.
set -euo pipefail
screen=${1:?usage: compare-harness.sh <thread|home> [shots-dir]}
here=$(cd "$(dirname "$0")" && pwd)
shots=${2:-}
if [ -z "$shots" ]; then
    # The newest t3-shots dir the simulator's test host wrote.
    shots=$(find ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application -maxdepth 3 -type d -name t3-shots 2>/dev/null \
        | while read -r d; do echo "$(stat -f %m "$d") $d"; done | sort -rn | head -1 | cut -d' ' -f2-)
fi
[ -f "$shots/parity-$screen.png" ] || { echo "no parity-$screen.png under $shots (run the InfinitusMobile tests)" >&2; exit 2; }
work=$(mktemp -d)
python3 - "$here/refs/ios-$screen.png" "$shots/parity-$screen.png" "$work" <<'PY'
import sys, struct, zlib
def read(path):
    d = open(path, "rb").read(); pos = 8; idat = []
    while pos < len(d):
        n = struct.unpack(">I", d[pos:pos+4])[0]; t = d[pos+4:pos+8]; body = d[pos+8:pos+8+n]; pos += 12 + n
        if t == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif t == b"IDAT": idat.append(body)
    raw = zlib.decompress(b"".join(idat)); bpp = 4 if ctype == 6 else 3; stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, bpp, rows
def write(path, w, h, bpp, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6 if bpp == 4 else 2, 0, 0, 0)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
ref, ours, out = sys.argv[1:4]
for src, name in ((ref, "ref"), (ours, "ours")):
    w, h, bpp, rows = read(src)
    fill = bytes([242, 242, 247, 255][:bpp])
    for y in range(min(140, h)): rows[y] = bytearray(fill * w)
    write(f"{out}/{name}.png", w, h, bpp, rows)
PY
echo "parity $screen (status bar masked):"
python3 "$here/compare.py" "$work/ref.png" "$work/ours.png" --out "$work/diff-$screen.png" || true
echo "diff heatmap: $work/diff-$screen.png"
