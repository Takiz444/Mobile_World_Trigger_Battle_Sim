"""Top-down PNG preview of a built district (debugging the map build).

    python -I tools/tokyo/preview.py common/map/tokyo/shibuya.json out.png [px_per_unit]
"""
import json
import math
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402

import geom  # noqa: E402


def write_png(path, img):
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main():
    src, out = sys.argv[1], sys.argv[2]
    ppu = float(sys.argv[3]) if len(sys.argv) > 3 else 4.0
    d = json.load(open(src, encoding="utf-8"))
    W, H = d["size"]
    res = 1.0 / ppu
    img = np.zeros((int(H * ppu), int(W * ppu), 3), dtype=np.uint8)
    img[:] = (60, 70, 90)

    def paint_tris(flat, color):
        for i in range(0, len(flat), 6):
            ring = [(flat[i], flat[i + 1]), (flat[i + 2], flat[i + 3]), (flat[i + 4], flat[i + 5])]
            g = geom.Grid(W, H, res)
            g.fill_rings([ring])
            img[g.a[: img.shape[0], : img.shape[1]]] = color

    def paint_mask(fn, color):
        g = geom.Grid(W, H, res)
        fn(g)
        img[g.a[: img.shape[0], : img.shape[1]]] = color

    paint_tris(d["land"], (200, 196, 186))
    paint_tris(d["green"], (120, 170, 100))
    for w in d["water"]:
        paint_tris(w["tris"], (70, 120, 180))
    for r in d["roads"]:
        pts = [(r[i], r[i + 1]) for i in range(3, len(r), 2)]
        paint_mask(lambda g, pts=pts, r=r: g.stroke(pts, r[1] / 2), (95, 95, 100) if r[0] < 5 else (170, 160, 150))
    for r in d.get("paths", []):
        pts = [(r[i], r[i + 1]) for i in range(0, len(r), 2)]
        paint_mask(lambda g, pts=pts: g.stroke(pts, 0.5), (215, 195, 150))
    for r in d["rail"]:
        pts = [(r[i], r[i + 1]) for i in range(1, len(r), 2)]
        paint_mask(lambda g, pts=pts, r=r: g.stroke(pts, r[0] / 2), (120, 90, 70))
    for m in d["markings"]:
        paint_mask(lambda g, m=m: g.fill_rings([geom.box_corners(m[0], m[1], m[2], m[3], m[4])]), (250, 250, 250) if m[5] == 0 else (250, 200, 40))
    for b in d["buildings"]:
        f = b[5]
        c = min(255, int(120 + f * 18))
        paint_mask(lambda g, b=b: g.fill_rings([geom.box_corners(*b[:5])]), (c, int(c * 0.8), int(c * 0.7)))
    for s in d["solids"]:
        paint_mask(lambda g, s=s: g.fill_rings([geom.box_corners(*s[:5])]), (40, 40, 40) if s[6] == 0 else (230, 90, 70))
    for k in d["decks"]:
        corners = geom.box_corners(*k[:5])
        for i in range(4):
            a, b = corners[i], corners[(i + 1) % 4]
            paint_mask(lambda g, a=a, b=b: g.stroke([a, b], 0.12), (230, 230, 60) if k[7] == 0 else (80, 230, 230))
    for t in d["props"]["tree"]:
        paint_mask(lambda g, t=t: g.stroke([(t[0], t[1]), (t[0] + 0.01, t[1])], 0.5 * t[2]), (40, 120, 50))
    for s in d["props"]["sign"]:
        paint_mask(lambda g, s=s: g.stroke([(s[0], s[1]), (s[0] + 0.01, s[1])], 0.3), (255, 60, 200))
    palette = [(255, 60, 60), (60, 200, 255), (255, 220, 40), (120, 255, 120), (255, 120, 255)]
    only = int(sys.argv[4]) if len(sys.argv) > 4 else -1
    for k, z in enumerate(d.get("zones", [])):
        if only >= 0 and k != only and k % 5 != only % 5:
            continue
        ring = [(z[i], z[i + 1]) for i in range(0, len(z), 2)]
        for i in range(len(ring)):
            a, b = ring[i], ring[(i + 1) % len(ring)]
            paint_mask(lambda g, a=a, b=b: g.stroke([a, b], 0.35), palette[k % 5])
    for zx, zz, zr in d.get("noplay", []):
        paint_mask(lambda g: g.stroke([(zx, zz), (zx + 0.01, zz)], 1.0), (255, 0, 0))
    write_png(out, img)
    print("wrote", out)


if __name__ == "__main__":
    main()
