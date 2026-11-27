"""Battle zones: the irregular play areas a match is fought in.

A district is split into city blocks: the land between streets, footpaths,
rivers and railways. A zone is a set of neighbouring blocks grown outward
from a centre until it reaches the target area. Its shape follows the city:
  - small streets and footpaths around and between its blocks are in the
    zone at their full width (the border runs along the far curb),
  - major roads and railways are a hard edge (the border runs along the
    near curb) unless the zone takes the blocks on both sides,
  - by a river it takes in a strip of the water along the bank,
so the border never runs down the middle of a road or through a building.

All rasters are numpy boolean grids at RES units per cell over the district.
"""
import math
import random
from collections import deque

import numpy as np

import geom

RES = 0.5


class Chunks:
    """Short pieces of every street, path and railway: the units a zone
    takes or leaves whole. kind: "major" (avenues, railways: taken only
    with both sides), "minor" (streets), "path" (footpaths)."""

    def __init__(self, shape):
        self.shape = shape
        self.items = []
        self.major = np.zeros(shape, dtype=bool)
        self.boxes = np.zeros((0, 4), dtype=np.int64)
        self.lines = 0

    def add(self, pts, half, kind, piece=2.5):
        nz, nx = self.shape
        line = self.lines
        self.lines += 1
        seq = 0
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            ln = math.hypot(b[0] - a[0], b[1] - a[1])
            if ln < 1e-6:
                continue
            n = max(1, int(math.ceil(ln / piece)))
            d = ((b[0] - a[0]) / ln, (b[1] - a[1]) / ln)
            for k in range(n):
                p0 = (a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n)
                p1 = (a[0] + (b[0] - a[0]) * (k + 1) / n, a[1] + (b[1] - a[1]) * (k + 1) / n)
                c0 = max(0, int((min(p0[0], p1[0]) - half) / RES))
                c1 = min(nx, int((max(p0[0], p1[0]) + half) / RES) + 2)
                r0 = max(0, int((min(p0[1], p1[1]) - half) / RES))
                r1 = min(nz, int((max(p0[1], p1[1]) + half) / RES) + 2)
                if c1 <= c0 or r1 <= r0:
                    continue
                X, Z = np.meshgrid((np.arange(c0, c1) + 0.5) * RES, (np.arange(r0, r1) + 0.5) * RES)
                dx, dz = p1[0] - p0[0], p1[1] - p0[1]
                ll = dx * dx + dz * dz
                t = np.clip(((X - p0[0]) * dx + (Z - p0[1]) * dz) / ll, 0.0, 1.0)
                inside = (X - (p0[0] + t * dx)) ** 2 + (Z - (p0[1] + t * dz)) ** 2 <= half * half
                rr, cc = np.nonzero(inside)
                if len(rr) == 0:
                    continue
                cells = (rr + r0) * nx + (cc + c0)
                self.items.append({"kind": kind, "cells": cells, "half": half, "dir": d,
                                   "center": ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2),
                                   "box": (r0, r1, c0, c1), "line": line, "seq": seq})
                seq += 1
                if kind == "major":
                    self.major.flat[cells] = True

    def finish(self):
        """Street pieces don't reach into an avenue (corners stay on the curb)."""
        for it in self.items:
            if it["kind"] != "major":
                it["cells"] = it["cells"][~self.major.flat[it["cells"]]]
        self.items = [it for it in self.items if len(it["cells"])]
        self.boxes = np.array([it["box"] for it in self.items], dtype=np.int64).reshape(-1, 4)

    def mask(self):
        m = np.zeros(self.shape, dtype=bool)
        for it in self.items:
            m.flat[it["cells"]] = True
        return m


def _dilate(m, n=1):
    out = m.copy()
    for _ in range(n):
        d = out.copy()
        d[1:, :] |= out[:-1, :]
        d[:-1, :] |= out[1:, :]
        d[:, 1:] |= out[:, :-1]
        d[:, :-1] |= out[:, 1:]
        out = d
    return out


def _erode(m, n=1):
    return ~_dilate(~m, n)


def zone_mask(regions, separator, water, chunks, ids, r0, r1, c0, c1, angle=0.0):
    """The zone's cells within rows r0..r1, cols c0..c1 (see module notes)."""
    nx = regions.shape[1]
    sub = regions[r0:r1, c0:c1]
    chosen = np.isin(sub, ids)
    land = chosen & ~separator[r0:r1, c0:c1]
    mask = land.copy()
    if water is not None:
        mask |= chosen & water[r0:r1, c0:c1]
    touch = _dilate(land, 2)
    b = chunks.boxes
    near = np.nonzero((b[:, 1] > r0) & (b[:, 0] < r1) & (b[:, 3] > c0) & (b[:, 2] < c1))[0]
    lr, lc = np.nonzero(land)
    lx = (lc + c0 + 0.5) * RES
    lz = (lr + r0 + 0.5) * RES
    take = {}       # chunk index -> (rr, cc) cells in the crop
    major_vote = {}  # (line, seq) -> bool
    for i in near.tolist():
        it = chunks.items[i]
        rr = it["cells"] // nx - r0
        cc = it["cells"] % nx - c0
        ok = (rr >= 0) & (rr < r1 - r0) & (cc >= 0) & (cc < c1 - c0)
        rr, cc = rr[ok], cc[ok]
        if len(rr) == 0:
            continue
        touching = bool(touch[rr, cc].any())
        if it["kind"] != "major":
            if touching:
                mask[rr, cc] = True
            continue
        both = False
        if touching:
            # Both sides: chosen land within reach left and right of it
            # (far enough to see past a median to the other carriageway).
            cx, cz = it["center"]
            dx, dz = it["dir"]
            reach = it["half"] + 5.0
            sel = (np.abs(lx - cx) < reach + 2.0) & (np.abs(lz - cz) < reach + 2.0)
            if sel.any():
                side = (lx[sel] - cx) * -dz + (lz[sel] - cz) * dx
                along = (lx[sel] - cx) * dx + (lz[sel] - cz) * dz
                near_line = (np.abs(side) <= reach) & (np.abs(along) <= 3.0)
                both = bool((side[near_line] > 0).any() and (side[near_line] < 0).any())
        take[i] = (rr, cc)
        major_vote[(it["line"], it["seq"])] = both
    # A stretch of avenue is in or out as a whole: majority of the chunk and
    # its two neighbours on each side along the same road.
    for i, (rr, cc) in take.items():
        it = chunks.items[i]
        votes = [major_vote.get((it["line"], it["seq"] + k)) for k in range(-2, 3)]
        votes = [v for v in votes if v is not None]
        if sum(votes) * 2 > len(votes):
            mask[rr, cc] = True
    # Nothing past the blocks' own extent: a side street leaving the zone is
    # cut where the block faces end, not left poking out as a stub.
    clip = _rect_clip(land, angle)
    mask &= clip
    mask = _erode(_dilate(mask, 2), 2) & clip   # close small notches
    mask = fill_holes(mask)
    # Keep the biggest piece.
    labels, count = label_blocks(~mask, min_cells=1)
    if count > 1:
        sizes = np.bincount(labels[labels >= 0].ravel(), minlength=count)
        mask = labels == int(np.argmax(sizes))
    return mask


def _rect_clip(land, angle, pad=1.0):
    """Cells inside the land's bounding rectangle at `angle` (radians),
    grown by `pad` cells."""
    ly, lx = np.nonzero(land)
    if len(ly) == 0:
        return np.ones_like(land)
    c, s = math.cos(angle), math.sin(angle)
    u = lx * c + ly * s
    v = -lx * s + ly * c
    yy, xx = np.mgrid[0:land.shape[0], 0:land.shape[1]]
    U = xx * c + yy * s
    V = -xx * s + yy * c
    return (U >= u.min() - pad) & (U <= u.max() + pad) & (V >= v.min() - pad) & (V <= v.max() + pad)


def street_angles(chunks, px, pz, reach=45.0):
    """The street grid's directions near (px, pz), folded to [0, pi/2):
    0, then the strongest local one(s) if clearly different."""
    if not hasattr(chunks, "_dirs"):
        it = [i for i in chunks.items if i["kind"] != "path"]
        chunks._dirs = (np.array([i["center"] for i in it], dtype=float).reshape(-1, 2),
                        np.array([math.atan2(i["dir"][1], i["dir"][0]) % (math.pi / 2) for i in it], dtype=float))
    cen, ang = chunks._dirs
    out = [0.0]
    if len(ang) == 0:
        return out
    near = np.hypot(cen[:, 0] - px, cen[:, 1] - pz) < reach
    if near.sum() >= 4:
        hist, edges = np.histogram(ang[near], bins=18, range=(0.0, math.pi / 2))
        hist = hist + np.roll(hist, 1) * 0.5 + np.roll(hist, -1) * 0.5   # circular smoothing
        for k in np.argsort(-hist)[:2].tolist():
            a = float((edges[k] + edges[k + 1]) / 2)
            if hist[k] > 0.25 * hist.max() and all(abs((a - b + math.pi / 4) % (math.pi / 2) - math.pi / 4) > 0.1 for b in out):
                out.append(a)
    return out


def label_blocks(separator, min_cells=6):
    """4-connected components of ~separator. Returns (labels, count); label
    -1 on separators and on components smaller than min_cells."""
    nz, nx = separator.shape
    labels = np.full((nz, nx), -1, dtype=np.int32)
    land = ~separator
    count = 0
    for r in range(nz):
        row = land[r]
        if not row.any():
            continue
        for c in np.nonzero(row & (labels[r] < 0))[0]:
            if labels[r, c] >= 0:
                continue
            q = deque([(r, c)])
            labels[r, c] = count
            cells = [(r, c)]
            while q:
                y, x = q.popleft()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < nz and 0 <= xx < nx and land[yy, xx] and labels[yy, xx] < 0:
                        labels[yy, xx] = count
                        q.append((yy, xx))
                        cells.append((yy, xx))
            if len(cells) < min_cells:
                for y, x in cells:
                    labels[y, x] = -2   # too small: treated as separator below
            else:
                count += 1
    labels[labels == -2] = -1
    return labels, count


def assign_separators(labels, water=None, water_reach=12):
    """Every unlabelled cell takes the label of its nearest labelled cell
    (breadth-first, so streets split along their middle). Water further than
    `water_reach` cells from a bank stays unassigned (-1): a zone by a river
    takes in its bank and a strip of the river, not half of it."""
    nz, nx = labels.shape
    out = labels.copy()
    dist = np.zeros(labels.shape, dtype=np.int32)
    q = deque()
    ys, xs = np.nonzero(out >= 0)
    # Seed only cells next to a separator (the rest can't spread).
    for y, x in zip(ys.tolist(), xs.tolist()):
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            yy, xx = y + dy, x + dx
            if 0 <= yy < nz and 0 <= xx < nx and out[yy, xx] < 0:
                q.append((y, x))
                break
    while q:
        y, x = q.popleft()
        lab = out[y, x]
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            yy, xx = y + dy, x + dx
            if 0 <= yy < nz and 0 <= xx < nx and out[yy, xx] < 0:
                d = dist[y, x] + 1
                if water is not None and water[yy, xx] and d > water_reach:
                    continue
                out[yy, xx] = lab
                dist[yy, xx] = d
                q.append((yy, xx))
    return out


def split_large(regions, labels, max_cells, chunk_cells, built=None):
    """Open regions bigger than max_cells (under 30% built: parks, plazas,
    temple grounds) are cut into chunks on a grid. Returns (regions, count,
    paths): `paths` are the cut lines inside the cut blocks, as polylines in
    world units, to be drawn as footpaths."""
    sizes = np.bincount(regions[regions >= 0].ravel())
    big = np.nonzero(sizes > max_cells)[0]
    if built is not None and len(big):
        cover = np.bincount(regions[(regions >= 0) & built].ravel(), minlength=sizes.size)
        big = np.array([b for b in big.tolist() if cover[b] < 0.3 * sizes[b]], dtype=np.int64)
    out = regions.copy()
    nxt = int(sizes.size)
    if len(big) == 0:
        return out, nxt, []
    nz, nx = regions.shape
    rr, cc = np.mgrid[0:nz, 0:nx]
    chunk = (rr // chunk_cells) * 100000 + (cc // chunk_cells)
    paths = []
    for b in big.tolist():
        m = regions == b
        land = m & (labels >= 0)
        keys = np.unique(chunk[m])
        for k in keys[1:]:
            out[m & (chunk == k)] = nxt
            nxt += 1
        # Cut lines: grid lines with this block's land on both sides.
        for x in range(chunk_cells, nx, chunk_cells):
            both = land[:, x - 1] & land[:, x]
            paths += _runs(both, lambda r, x=x: (x * RES, r * RES))
        for z in range(chunk_cells, nz, chunk_cells):
            both = land[z - 1, :] & land[z, :]
            paths += _runs(both, lambda c, z=z: (c * RES, z * RES))
    return out, nxt, paths


def _runs(flags, to_world, min_len=6):
    """Polylines along the True runs of a 1D boolean array."""
    out = []
    idx = np.nonzero(flags)[0]
    if len(idx) == 0:
        return out
    start = prev = int(idx[0])
    for v in idx[1:].tolist() + [None]:
        if v is None or v != prev + 1:
            if prev + 1 - start >= min_len:
                out.append([to_world(start), to_world(prev + 1)])
            if v is None:
                break
            start = v
        prev = v
    return out


def adjacency(regions, count):
    adj = [set() for _ in range(count)]
    a = regions[:, :-1]
    b = regions[:, 1:]
    m = (a != b) & (a >= 0) & (b >= 0)
    for u, v in zip(a[m].tolist(), b[m].tolist()):
        adj[u].add(v)
        adj[v].add(u)
    a = regions[:-1, :]
    b = regions[1:, :]
    m = (a != b) & (a >= 0) & (b >= 0)
    for u, v in zip(a[m].tolist(), b[m].tolist()):
        adj[u].add(v)
        adj[v].add(u)
    return adj


def fill_holes(mask):
    """Cells not reachable from the border through ~mask become part of mask."""
    nz, nx = mask.shape
    outside = np.zeros_like(mask)
    q = deque()
    for r in range(nz):
        for c in (0, nx - 1):
            if not mask[r, c] and not outside[r, c]:
                outside[r, c] = True
                q.append((r, c))
    for c in range(nx):
        for r in (0, nz - 1):
            if not mask[r, c] and not outside[r, c]:
                outside[r, c] = True
                q.append((r, c))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            yy, xx = y + dy, x + dx
            if 0 <= yy < nz and 0 <= xx < nx and not mask[yy, xx] and not outside[yy, xx]:
                outside[yy, xx] = True
                q.append((yy, xx))
    return ~outside


def largest_component_share(mask):
    """(largest 4-connected component size, total) of a boolean grid."""
    labels, count = label_blocks(~mask, min_cells=1)
    if count == 0:
        return 0, 0
    sizes = np.bincount(labels[labels >= 0].ravel(), minlength=count)
    return int(sizes.max()), int(mask.sum())


def build_zones(W, H, separator, walkable, noplay, margin, target_area, chunks, water=None, built=None, spacing=12.0,
                max_zones=60, seed="", log=None, green=None, footprint=None, min_built=0.0, aspect=1.0, aspect_max=1.6):
    """Zones as simplified polygons [[(x, z), ...], ...].

    separator: street / water / rail cells (block borders).
    walkable:  open ground (not buildings, water or rail): zones need most of
               theirs connected.
    noplay:    [(x, z, r)] circles a zone must stay clear of.
    margin:    keep zones this far from the district edge (scenery around).
    aspect:    the proportions zones aim for (long side / short side);
    aspect_max: zones longer than this are dropped.
    """
    STRAIGHTEN_LOG.clear()
    # Big parks are blocks of their own (their edge is a natural border).
    if green is not None:
        g_labels, g_count = label_blocks(~(green & ~separator), min_cells=1)
        g_sizes = np.bincount(g_labels[g_labels >= 0].ravel(), minlength=max(1, g_count)) * RES * RES
        big_green = (g_labels >= 0) & (g_sizes[np.maximum(g_labels, 0)] >= 300.0)
        edge = big_green & ~_erode(big_green, 1)
        separator = separator | edge
    labels, count = label_blocks(separator)
    # Medians and traffic islands (strips under ~3 units wide, or tiny) are
    # part of the road, not blocks a zone could take.
    land = labels >= 0
    core = _erode(land, 3)
    keep = np.zeros(count, dtype=bool)
    keep[np.unique(labels[core & land])] = True
    sizes = np.bincount(labels[land].ravel(), minlength=count)
    keep &= sizes * RES * RES >= 20.0
    thin = land & ~keep[np.maximum(labels, 0)]
    separator = separator | thin
    labels, count = label_blocks(separator)
    regions = assign_separators(labels, water)
    # Open blocks still too big for a zone (parks, plazas, grounds) are cut
    # on a grid; every cut becomes a drawn footpath, so a border along it
    # follows something you can see. Built-up blocks are never cut.
    regions, count, cut_paths = split_large(regions, labels, int(target_area * 0.6 / (RES * RES)), int(18.0 / RES), built)
    nz, nx = regions.shape
    adj = adjacency(regions, count)
    valid = regions >= 0
    area_cells = np.bincount(regions[valid].ravel(), minlength=count).astype(float)
    ys, xs = np.nonzero(valid)
    labs = regions[valid]
    cx = np.bincount(labs, weights=(xs + 0.5) * RES, minlength=count) / np.maximum(area_cells, 1)
    cz = np.bincount(labs, weights=(ys + 0.5) * RES, minlength=count) / np.maximum(area_cells, 1)
    area = area_cells * RES * RES
    # Region bounds, to check zone extents cheaply.
    x0 = np.full(count, np.inf)
    x1 = np.full(count, -np.inf)
    z0 = np.full(count, np.inf)
    z1 = np.full(count, -np.inf)
    np.minimum.at(x0, labs, xs * RES)
    np.maximum.at(x1, labs, (xs + 1) * RES)
    np.minimum.at(z0, labs, ys * RES)
    np.maximum.at(z1, labs, (ys + 1) * RES)

    # Blocks a zone may use: inside the margin, clear of no-play circles.
    eligible = (x0 >= margin) & (z0 >= margin) & (x1 <= W - margin) & (z1 <= H - margin) & (area_cells > 0)
    for n in noplay:
        nxs = np.clip(n[0], x0, x1)
        nzs = np.clip(n[1], z0, z1)
        near = np.hypot(nxs - n[0], nzs - n[1]) < n[2]
        for b in np.nonzero(near & eligible)[0].tolist():
            if _near_circle(regions, np.array([b]), n):
                eligible[b] = False

    zones = []
    shares = []
    seen = set()
    rejected = {"edge": 0, "shape": 0, "walk": 0, "noplay": 0, "dup": 0, "aspect": 0}
    side = math.sqrt(target_area)
    centers = []
    gz = margin + spacing * 0.5
    while gz < H - margin:
        gx = margin + spacing * 0.5
        while gx < W - margin:
            centers.append((gx, gz))
            gx += spacing
        gz += spacing
    random.Random(seed).shuffle(centers)   # spread the zones over the district
    for (px, pz) in centers:
        c = int(px / RES)
        r = int(pz / RES)
        if not (0 <= r < nz and 0 <= c < nx) or regions[r, c] < 0:
            continue
        start = int(regions[r, c])
        if not eligible[start]:
            rejected["edge"] += 1
            continue
        if area[start] > target_area * 1.45:
            rejected["shape"] += 1
            continue
        # Candidates: blocks mostly inside rectangles of a few proportions
        # around the centre (the district is turned to its street grid, so
        # these follow the streets), plus the old greedy growth. Keep the one
        # that fills its bounding box best: zones as rectangular as the
        # blocks allow.
        best = None
        angles = street_angles(chunks, px, pz)
        for chosen in _candidates(start, px, pz, target_area, regions, area_cells, area, cx, cz, adj, eligible, angles,
                                  aspect, aspect_max):
            total = float(sum(area[b] for b in chosen))
            if total < target_area * 0.85 or total > target_area * 1.35:
                continue
            for a in angles:
                fill, asp = _fill(regions, chosen, x0, x1, z0, z1, a)
                if asp > aspect_max:
                    continue
                if best is None or fill > best[0] + 1e-9:
                    best = (fill, chosen, a)
        if best is None:
            rejected["shape"] += 1
            continue
        chosen = best[1]
        zone_angle = best[2]
        key = frozenset(chosen)
        if key in seen:
            rejected["dup"] += 1
            continue
        seen.add(key)
        ids = np.array(sorted(chosen))
        bx0, bx1 = x0[ids].min(), x1[ids].max()
        bz0, bz1 = z0[ids].min(), z1[ids].max()
        if bx0 < margin or bz0 < margin or bx1 > W - margin or bz1 > H - margin:
            rejected["edge"] += 1
            continue
        if max(bx1 - bx0, bz1 - bz0) > side * 1.9 or min(bx1 - bx0, bz1 - bz0) < side * 0.55:
            rejected["shape"] += 1
            continue
        if any(_rect_circle(bx0, bz0, bx1, bz1, n) and _near_circle(regions, ids, n) for n in noplay):
            rejected["noplay"] += 1
            continue
        r0 = max(0, int(bz0 / RES) - 4)
        r1 = min(nz, int(bz1 / RES) + 4)
        c0 = max(0, int(bx0 / RES) - 4)
        c1 = min(nx, int(bx1 / RES) + 4)
        mask = zone_mask(regions, separator, water, chunks, ids, r0, r1, c0, c1, zone_angle)
        zarea = float(mask.sum() * RES * RES)
        if zarea < target_area * 0.8 or zarea > target_area * 1.45:
            rejected["shape"] += 1
            continue
        if footprint is not None:
            # Building cover of the zone's land (its blocks; not streets,
            # rivers or railways): no zones of open lots and empty grounds.
            zl = mask & ~separator[r0:r1, c0:c1]
            share = float((zl & footprint[r0:r1, c0:c1]).sum()) / max(1, zl.sum())
            shares.append(share)
            if share < min_built:
                rejected["sparse"] = rejected.get("sparse", 0) + 1
                continue
        walk = mask & walkable[r0:r1, c0:c1]
        big, tot = largest_component_share(walk)
        if tot < 0.3 * mask.sum() or big < 0.8 * tot:
            rejected["walk"] += 1
            continue
        ring = _outline(mask)
        if ring is None:
            rejected["shape"] += 1
            continue
        ring = [(x + c0 * RES, z + r0 * RES) for x, z in ring]
        ring = straighten(ring, [zone_angle] + street_angles(chunks, (bx0 + bx1) / 2, (bz0 + bz1) / 2, reach=60.0))
        ring = despike(ring)
        zc = geom.centroid(ring)
        _, _, hx, hz, _ = geom.min_area_rect(ring)
        if max(hx, hz) > aspect_max * min(hx, hz):
            rejected["aspect"] += 1
            continue
        rect = geom.area(ring) / max(1e-6, 4.0 * hx * hz)
        zones.append({"ring": ring, "area": float(mask.sum() * RES * RES), "center": zc, "rect": rect})
    found = len(zones)
    # Prefer the squarest zones: keep those filling most of their rectangle,
    # relaxing the bar only as far as needed to cover the district.
    # Winding districts settle for fewer zones rather than ragged ones.
    fallback = None
    for bar in (0.93, 0.91, 0.89, 0.87, 0.85, 0.83, 0.81, 0.79, 0.0):
        boxy = [z for z in zones if z["rect"] >= bar]
        if len(boxy) >= min(len(zones), 24):
            break
        if fallback is None and len(boxy) >= min(len(zones), 14):
            fallback = (bar, boxy)
    if bar < 0.79 and fallback is not None:
        bar, boxy = fallback
    elif bar < 0.79:
        # Winding streets everywhere: keep only the squarest dozen.
        boxy = sorted(zones, key=lambda z: -z["rect"])[:12]
        bar = round(boxy[-1]["rect"], 2) if boxy else 0.0
    zones = _spread(boxy, max_zones)
    if log:
        q = sorted(shares)
        pct = (lambda f: round(q[int(f * (len(q) - 1))], 2)) if q else (lambda f: None)
        rq = sorted(z["rect"] for z in zones)
        log(f"zones: {len(zones)} kept of {found} found from {len(centers)} centres (rect bar {bar}), rejected {rejected}, "
            f"built share p10/p50/p90 {pct(0.1)}/{pct(0.5)}/{pct(0.9)}, "
            f"straighten {STRAIGHTEN_LOG}, rectangularity min/p50 {round(rq[0], 2) if rq else None}/{round(rq[len(rq) // 2], 2) if rq else None}")
    return zones, _used_paths(cut_paths, zones)


def _candidates(start, px, pz, target_area, regions, area_cells, area, cx, cz, adj, eligible, angles=(0.0,),
                aspect=1.0, aspect_max=1.6):
    """Block sets to try for a zone around (px, pz) that contains `start`."""
    # Greedy: nearest blocks first.
    chosen = {start}
    total = area[start]
    frontier = {b for b in adj[start] if eligible[b]}
    while total < target_area and frontier:
        b = min(frontier, key=lambda k: (cx[k] - px) ** 2 + (cz[k] - pz) ** 2)
        frontier.discard(b)
        if total + area[b] > target_area * 1.35:
            continue
        chosen.add(b)
        total += area[b]
        frontier |= {k for k in adj[b] if eligible[k]} - chosen
    yield chosen
    # Rectangles of a few sizes and proportions, turned to each street
    # direction: every block with most of its cells inside.
    nz, nx = regions.shape
    # Proportions around the target's, either way round, up to aspect_max.
    shapes = sorted({round(a, 3) for a in (aspect, (aspect + aspect_max) / 2, aspect_max * 0.97, 1.0)})
    shapes = [a for a in shapes if a <= aspect_max] + [1 / a for a in shapes if 1.0 < a <= aspect_max]
    span = math.sqrt(target_area * 1.2 * max(shapes)) * 0.75 + 2.0
    c0 = max(0, int((px - span) / RES))
    c1 = min(nx, int((px + span) / RES) + 1)
    r0 = max(0, int((pz - span) / RES))
    r1 = min(nz, int((pz + span) / RES) + 1)
    sub = regions[r0:r1, c0:c1]
    Z, X = np.mgrid[r0:r1, c0:c1]
    X = (X + 0.5) * RES - px
    Z = (Z + 0.5) * RES - pz
    valid = sub >= 0
    seen = set()
    for ang in angles:
        ca, sa = math.cos(ang), math.sin(ang)
        U = X * ca + Z * sa
        V = -X * sa + Z * ca
        for scale in (0.95, 1.05, 1.15):
            for shp in shapes:
                w = math.sqrt(target_area * scale * shp)
                h = target_area * scale / w
                for ox, oz in ((0, 0), (0.25, 0), (-0.25, 0), (0, 0.25), (0, -0.25)):
                    inr = (np.abs(U - ox * w) <= w / 2) & (np.abs(V - oz * h) <= h / 2) & valid
                    labs = sub[inr]
                    if labs.size == 0:
                        continue
                    ids, cnt = np.unique(labs, return_counts=True)
                    inside = ids[(cnt >= 0.55 * area_cells[ids]) & eligible[ids]]
                    pick = set(inside.tolist())
                    if start not in pick:
                        continue
                    # Connected to the start through chosen blocks only.
                    comp = {start}
                    todo = [start]
                    while todo:
                        b = todo.pop()
                        for k in adj[b]:
                            if k in pick and k not in comp:
                                comp.add(k)
                                todo.append(k)
                    key = frozenset(comp)
                    if key in seen:
                        continue
                    seen.add(key)
                    yield comp


def _fill(regions, chosen, x0, x1, z0, z1, angle=0.0):
    """Share of the chosen blocks' bounding rectangle (at `angle`) they
    cover, and that rectangle's proportions (long / short side)."""
    ids = np.array(sorted(chosen))
    r0 = int(z0[ids].min() / RES)
    r1 = int(math.ceil(z1[ids].max() / RES))
    c0 = int(x0[ids].min() / RES)
    c1 = int(math.ceil(x1[ids].max() / RES))
    ys, xs = np.nonzero(np.isin(regions[r0:r1, c0:c1], ids))
    if len(ys) == 0:
        return 0.0, 1.0
    c, s = math.cos(angle), math.sin(angle)
    u = xs * c + ys * s
    v = -xs * s + ys * c
    w, h = u.max() - u.min() + 1, v.max() - v.min() + 1
    return float(len(ys)) / max(1.0, w * h), max(w, h) / max(1.0, min(w, h))


STRAIGHTEN_LOG = {}


def despike(ring, max_angle=75.0, max_leg=4.0):
    """Drops spikes from a zone outline: a corner sharper than `max_angle`
    with a side shorter than `max_leg` is a jog into a junction (where two
    border lines meet at a slant), not a corner of the zone, so its
    neighbours are joined by a straight line instead. Repeats until none is
    left; keeps the input if that would leave under 4 corners or make the
    outline cross itself."""
    out = list(ring)
    cos_max = math.cos(math.radians(max_angle))
    changed = True
    while changed and len(out) > 4:
        changed = False
        for i in range(len(out)):
            a, b, c = out[i - 1], out[i], out[(i + 1) % len(out)]
            v1 = (a[0] - b[0], a[1] - b[1])
            v2 = (c[0] - b[0], c[1] - b[1])
            l1, l2 = math.hypot(*v1), math.hypot(*v2)
            if l1 < 1e-6 or l2 < 1e-6:
                del out[i]
                changed = True
                break
            # Interior or exterior: a sharp spike either way.
            if (v1[0] * v2[0] + v1[1] * v2[1]) / (l1 * l2) > cos_max and min(l1, l2) < max_leg:
                del out[i]
                changed = True
                break
    out = [q for k, q in enumerate(out) if _turns(out[k - 1], q, out[(k + 1) % len(out)])]
    if len(out) < 4 or _self_intersects(out):
        return ring
    return out


def straighten(ring, angles, snap_deg=15.0, jog=1.6, max_move=1.6):
    """The zone outline as clean straight sides: edges near the zone's two
    axes are snapped to them, runs along one axis become one line (small
    steps of under `jog` folded in), and corners are where those lines meet.
    Sides that follow something slanted (a river bank) keep their angle.
    Falls back to the input if the result moves the outline more than
    `max_move` anywhere, changes its area by over 4%, or self-intersects."""
    ring = geom.dedupe(list(ring))
    if len(ring) < 4:
        return ring
    src = ring
    # Slanted runs (river banks, curving streets) smoothed harder first.
    ring = geom.rdp_ring(ring, 0.7)
    if len(ring) < 4:
        ring = src
    cos_snap = math.cos(math.radians(snap_deg))
    axes = []
    for angle in angles:
        for u in ((math.cos(angle), math.sin(angle)), (-math.sin(angle), math.cos(angle))):
            if all(abs(u[0] * v[0] + u[1] * v[1]) < math.cos(math.radians(4.0)) for v in axes):
                axes.append(u)
    lines = []
    for i in range(len(ring)):
        a, b = ring[i], ring[(i + 1) % len(ring)]
        ln = math.hypot(b[0] - a[0], b[1] - a[1])
        if ln < 1e-6:
            continue
        d = ((b[0] - a[0]) / ln, (b[1] - a[1]) / ln)
        ax = None
        best = cos_snap
        dd = d
        for k, u in enumerate(axes):
            dot = d[0] * u[0] + d[1] * u[1]
            # Snap only if that turns the side by under ~0.9 units over its
            # length: a long side that really is slanted stays slanted.
            if abs(dot) >= best and ln * math.sqrt(max(0.0, 1.0 - dot * dot)) <= 0.9:
                best = abs(dot)
                dd = u if dot > 0 else (-u[0], -u[1])
                ax = k * 2 + (0 if dot > 0 else 1)
        d = dd
        lines.append(_line(d, ax, [(a, b, ln)]))
    changed = True
    while changed and len(lines) >= 4:
        changed = False
        # Consecutive runs along the same axis and direction: one line.
        i = 0
        while i < len(lines) and len(lines) >= 4:
            j = (i + 1) % len(lines)
            if lines[i]["ax"] is not None and lines[i]["ax"] == lines[j]["ax"]:
                lines[i] = _line(lines[i]["d"], lines[i]["ax"], lines[i]["segs"] + lines[j]["segs"])
                del lines[j]
                if j < i:
                    i -= 1
                changed = True
            else:
                i += 1
        # A short step between two lines of the same direction, close
        # together: fold it in (the next pass merges the two).
        for i in range(len(lines)):
            n = len(lines)
            if n < 5:
                break
            prev, cur, nxt = lines[(i - 1) % n], lines[i], lines[(i + 1) % n]
            if cur["w"] < jog and prev["ax"] is not None and prev["ax"] == nxt["ax"] and abs(prev["c"] - nxt["c"]) < jog:
                del lines[i]
                changed = True
                break
        # Slivers that aren't on an axis between two that are: drop them.
        for i in range(len(lines)):
            n = len(lines)
            if n < 5:
                break
            if lines[i]["ax"] is None and lines[i]["w"] < 0.8:
                del lines[i]
                changed = True
                break
    if len(lines) < 3:
        return src
    out = []
    n = len(lines)
    for i in range(n):
        l0, l1 = lines[i - 1], lines[i]
        corner = l1["segs"][0][0]
        p = _meet(l0, l1)
        if p is None or math.hypot(p[0] - corner[0], p[1] - corner[1]) > 3.0:
            # Parallel (or nearly): a square step between them.
            out.append(_project(l0, corner))
            out.append(_project(l1, corner))
        else:
            out.append(p)
    out = geom.dedupe(out)
    out = [q for k, q in enumerate(out) if _turns(out[k - 1], q, out[(k + 1) % len(out)])]
    if len(out) < 3 or _self_intersects(out):
        STRAIGHTEN_LOG["crossing"] = STRAIGHTEN_LOG.get("crossing", 0) + 1
        return src
    ring = src
    a0, a1 = abs(geom.signed_area(ring)), abs(geom.signed_area(out))
    if abs(a1 - a0) > 0.04 * a0:
        STRAIGHTEN_LOG["area"] = STRAIGHTEN_LOG.get("area", 0) + 1
        return ring
    if max(_dist_to_ring(q, ring) for q in out) > max_move or max(_dist_to_ring(q, out) for q in ring) > max_move:
        STRAIGHTEN_LOG["moved"] = STRAIGHTEN_LOG.get("moved", 0) + 1
        return ring
    STRAIGHTEN_LOG["ok"] = STRAIGHTEN_LOG.get("ok", 0) + 1
    if geom.signed_area(out) * geom.signed_area(ring) < 0:
        out.reverse()
    return [(round(x, 3), round(z, 3)) for x, z in out]


def _line(d, ax, segs):
    nrm = (-d[1], d[0])
    w = sum(s[2] for s in segs)
    c = sum((nrm[0] * (a[0] + b[0]) / 2 + nrm[1] * (a[1] + b[1]) / 2) * ln for a, b, ln in segs) / max(w, 1e-9)
    if ax is None and len(segs) > 1:
        # A merged slanted run: the line through its ends.
        a, b = segs[0][0], segs[-1][1]
        ln = math.hypot(b[0] - a[0], b[1] - a[1])
        if ln > 1e-6:
            d = ((b[0] - a[0]) / ln, (b[1] - a[1]) / ln)
            nrm = (-d[1], d[0])
            c = nrm[0] * a[0] + nrm[1] * a[1]
    return {"d": d, "n": nrm, "c": c, "w": w, "ax": ax, "segs": segs}


def _meet(l0, l1):
    (a, b), (c, d) = l0["n"], l1["n"]
    det = a * d - b * c
    if abs(det) < 1e-3:
        return None
    return ((l0["c"] * d - b * l1["c"]) / det, (a * l1["c"] - l0["c"] * c) / det)


def _project(l, p):
    k = l["n"][0] * p[0] + l["n"][1] * p[1] - l["c"]
    return (p[0] - l["n"][0] * k, p[1] - l["n"][1] * k)


def _turns(a, b, c, eps=0.02):
    """b is a real corner (not on the straight line a-c)."""
    cr = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
    ln = math.hypot(c[0] - a[0], c[1] - a[1])
    return abs(cr) > eps * max(ln, 1e-6)


def _self_intersects(ring):
    n = len(ring)
    for i in range(n):
        a, b = ring[i], ring[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            c, d = ring[j], ring[(j + 1) % n]
            if _seg_cross(a, b, c, d):
                return True
    return False


def _seg_cross(a, b, c, d):
    def o(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
    d1, d2, d3, d4 = o(c, d, a), o(c, d, b), o(a, b, c), o(a, b, d)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and d1 != 0 and d2 != 0 and d3 != 0 and d4 != 0


def _used_paths(paths, zones, tol=0.8):
    """The cut lines some zone border actually runs along (most of the cut
    within `tol` of the border); the rest aren't drawn."""
    out = []
    for a, b in paths:
        ln = math.hypot(b[0] - a[0], b[1] - a[1])
        n = max(2, int(ln / 0.5))
        for z in zones:
            ring = z["ring"]
            near = 0
            for k in range(n + 1):
                p = (a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n)
                if _dist_to_ring(p, ring) <= tol:
                    near += 1
            if near >= 0.5 * (n + 1):
                out.append([a, b])
                break
    return out


def _dist_to_ring(p, ring):
    best = 1e9
    for i in range(len(ring)):
        a = ring[i]
        b = ring[(i + 1) % len(ring)]
        dx, dz = b[0] - a[0], b[1] - a[1]
        ll = dx * dx + dz * dz
        t = 0.0 if ll < 1e-12 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dz) / ll))
        best = min(best, math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dz))
    return best


def _spread(zones, n):
    """Up to n zones whose centres are as spread out as possible (farthest
    point sampling, deterministic), so every part of the district is used."""
    if len(zones) <= n:
        return zones
    zones = sorted(zones, key=lambda z: (round(z["center"][0], 2), round(z["center"][1], 2)))
    picked = [zones[0]]
    dist = [math.hypot(z["center"][0] - zones[0]["center"][0], z["center"][1] - zones[0]["center"][1]) for z in zones]
    while len(picked) < n:
        i = max(range(len(zones)), key=lambda k: dist[k])
        picked.append(zones[i])
        c = zones[i]["center"]
        for k, z in enumerate(zones):
            dist[k] = min(dist[k], math.hypot(z["center"][0] - c[0], z["center"][1] - c[1]))
    return picked


def _rect_circle(x0, z0, x1, z1, n):
    nx_ = min(max(n[0], x0), x1)
    nz_ = min(max(n[1], z0), z1)
    return math.hypot(nx_ - n[0], nz_ - n[1]) < n[2]


def _near_circle(regions, ids, n):
    # Any zone cell within the circle?
    r0 = max(0, int((n[1] - n[2]) / RES))
    r1 = min(regions.shape[0], int((n[1] + n[2]) / RES) + 1)
    c0 = max(0, int((n[0] - n[2]) / RES))
    c1 = min(regions.shape[1], int((n[0] + n[2]) / RES) + 1)
    sub = np.isin(regions[r0:r1, c0:c1], ids)
    if not sub.any():
        return False
    yy, xx = np.nonzero(sub)
    d = np.hypot((xx + c0 + 0.5) * RES - n[0], (yy + r0 + 0.5) * RES - n[1])
    return bool((d < n[2]).any())


def _outline(mask):
    """Outer ring of a zone mask, simplified, in world units."""
    rings = geom.contours(mask.astype(np.float32), RES)
    if not rings:
        return None
    ring = max(rings, key=geom.area)
    ring = geom.rdp_ring(geom.dedupe(ring), 0.3)
    if len(ring) < 4:
        return None
    if geom.signed_area(ring) < 0:
        ring.reverse()
    return ring
