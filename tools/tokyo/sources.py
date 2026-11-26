"""Official building data for the Tokyo build (see fetch_tiles.py).

load_plateau(): every building of a district from Project PLATEAU, with its
measured height. A building cut by tile edges comes back as one entry with
all its pieces (the tiles overlap, so pieces are unioned, never XOR-ed).
load_gsi():     the GSI base map's building outlines (to check against).
"""
import math
import os

import geom
import mvt
from fetch_tiles import ZOOM, tile_path, tiles_for


def _tile_to_latlon(tx, ty, px, py, extent, z=ZOOM):
    n = 2.0 ** z
    lon = (tx + px / extent) / n * 360.0 - 180.0
    y = (ty + py / extent) / n
    lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * y))))
    return lat, lon


def _polygons(rings):
    """MVT rings -> [(outer, [holes])]: exterior rings have positive area in
    tile coordinates (y down); holes follow their exterior."""
    out = []
    for r in rings:
        r = geom.dedupe(r)
        if len(r) < 3:
            continue
        if geom.signed_area(r) > 0:
            out.append((r, []))
        elif out:
            out[-1][1].append(r)
    return out


def _features(cache, src, layer, d, proj, inside):
    for tx, ty in tiles_for(d):
        path = tile_path(cache, src, tx, ty)
        if not os.path.exists(path):
            continue
        data = open(path, "rb").read()
        if not data:
            continue
        layers = mvt.decode(data)
        if layer not in layers:
            continue
        ext = layers[layer]["extent"]
        for f in layers[layer]["features"]:
            if f["type"] != 3:
                continue
            polys = []
            for outer, holes in _polygons(f["rings"]):
                o = [proj(*_tile_to_latlon(tx, ty, x, y, ext)) for x, y in outer]
                hs = [[proj(*_tile_to_latlon(tx, ty, x, y, ext)) for x, y in h] for h in holes]
                # Projection keeps the winding (x east / z south like tile x / y).
                if any(inside(p, 4) for p in o):
                    polys.append((o, hs))
            if polys:
                yield f, polys


def load_plateau(cache, d, proj, inside):
    """[{id, h (metres or None), pieces: [(outer, holes)]}]"""
    by_id = {}
    for f, polys in _features(cache, "plateau", "bldg", d, proj, inside):
        p = f["props"]
        bid = p.get("建物ID") or ("f%d" % f["id"])
        h = p.get("measuredHeight")
        try:
            h = float(h) if h is not None else None
        except (TypeError, ValueError):
            h = None
        if h is not None and h <= 0:
            h = None
        e = by_id.setdefault(bid, {"id": bid, "h": h, "pieces": []})
        if e["h"] is None and h is not None:
            e["h"] = h
        e["pieces"] += polys
    return list(by_id.values())


def load_gsi(cache, d, proj, inside):
    """[(outer, holes)] building outlines of the GSI base map."""
    out = []
    for _f, polys in _features(cache, "gsi", "BldA", d, proj, inside):
        out += polys
    return out


def coverage(polys, W, H, res=0.5):
    """Raster of polygons [(outer, holes)] (each OR-ed in)."""
    g = geom.Grid(W, H, res)
    for outer, holes in polys:
        g.fill_rings([outer] + holes)   # each call ORs its polygon in
    return g.a


def dilate(m, n=1):
    out = m.copy()
    for _ in range(n):
        d = out.copy()
        d[1:, :] |= out[:-1, :]
        d[:-1, :] |= out[1:, :]
        d[:, 1:] |= out[:, :-1]
        d[:, :-1] |= out[:, 1:]
        out = d
    return out
