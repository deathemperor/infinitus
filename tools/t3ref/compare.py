#!/usr/bin/env python3
"""Pixel parity: fraction of pixels whose CIE ΔE76 exceeds 6, text edges masked (spec §3.6)."""
import argparse, struct, sys, zlib

def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, chunks, w = 8, [], None
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]; t = data[pos + 4:pos + 8]; body = data[pos + 8:pos + 8 + n]; pos += 12 + n
        if t == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", body[:10]); assert depth == 8 and ctype in (2, 6), "need 8-bit RGB/RGBA"
        elif t == b"IDAT": chunks.append(body)
    raw = zlib.decompress(b"".join(chunks)); bpp = 4 if ctype == 6 else 3; stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    px = [[tuple(r[x * bpp:x * bpp + 3]) for x in range(w)] for r in rows]
    return w, h, px

def lab(rgb):
    def lin(c): c /= 255; return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = map(lin, rgb)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047; y = 0.2126 * r + 0.7152 * g + 0.0722 * b; z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)

def edge_mask(px, w, h):
    """1-px dilation around strong luminance edges: glyph antialiasing lives there."""
    lum = [[0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] for p in row] for row in px]
    edges = [[False] * w for _ in range(h)]
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if abs(lum[y][x] - lum[y][x + 1]) > 60 or abs(lum[y][x] - lum[y + 1][x]) > 60: edges[y][x] = True
    mask = [[False] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if edges[y][x]:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        yy, xx = y + dy, x + dx
                        if 0 <= yy < h and 0 <= xx < w: mask[yy][xx] = True
    return mask

def compare(a, b, out=None):
    wa, ha, pa = read_png(a); wb, hb, pb = read_png(b)
    if (wa, ha) != (wb, hb): raise SystemExit(f"size mismatch {wa}x{ha} vs {wb}x{hb}")
    mask = edge_mask(pa, wa, ha)
    over = total = 0; mx = 0.0; heat = []
    for y in range(ha):
        row = []
        for x in range(wa):
            if mask[y][x]: row.append(0); continue
            l1, l2 = lab(pa[y][x]), lab(pb[y][x])
            de = ((l1[0] - l2[0]) ** 2 + (l1[1] - l2[1]) ** 2 + (l1[2] - l2[2]) ** 2) ** 0.5
            total += 1; mx = max(mx, de)
            if de > 6: over += 1; row.append(min(255, int(de * 4)))
            else: row.append(0)
        heat.append(row)
    if out: write_heat(out, wa, ha, pa, heat)
    return over / max(1, total) * 100, mx

def write_heat(path, w, h, base, heat):
    def chunk(t, body): return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xffffffff)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            g = int(0.3 * (0.299 * base[y][x][0] + 0.587 * base[y][x][1] + 0.114 * base[y][x][2]))
            raw += bytes((min(255, g + heat[y][x]), g, g))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))

def selftest():
    import tempfile, os
    d = tempfile.mkdtemp()
    def png(path, w, h, color):
        def chunk(t, body): return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xffffffff)
        raw = b"".join(b"\x00" + bytes(color) * w for _ in range(h))
        open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    a, b, c = (os.path.join(d, n) for n in ("a.png", "b.png", "c.png"))
    png(a, 20, 20, (250, 250, 250)); png(b, 20, 20, (250, 250, 250)); png(c, 20, 20, (200, 200, 200))
    same, _ = compare(a, b); assert same == 0, same
    diff, mx = compare(a, c); assert diff > 99, diff; assert mx > 15, mx
    print("selftest ok")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("a", nargs="?"); ap.add_argument("b", nargs="?")
    ap.add_argument("--out"); ap.add_argument("--threshold", type=float, default=1.5); ap.add_argument("--selftest", action="store_true")
    ns = ap.parse_args()
    if ns.selftest: selftest(); sys.exit(0)
    over, mx = compare(ns.a, ns.b, ns.out)
    print(f"over: {over:.2f}% max ΔE {mx:.1f}")
    sys.exit(1 if over > ns.threshold else 0)
