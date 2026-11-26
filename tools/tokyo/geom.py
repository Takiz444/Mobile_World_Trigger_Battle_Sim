"""Small pure-Python geometry kit for the Tokyo map build (no shapely here:
native GIS libraries are not always installable). numpy is used for rasters.
Coordinates are (x, z) game units, x east, z south.
"""
import math

import numpy as np


# --- Polygons --------------------------------------------------------------

def signed_area(ring):
    a = 0.0
    n = len(ring)
    for i in range(n):
        x0, z0 = ring[i]
        x1, z1 = ring[(i + 1) % n]
        a += x0 * z1 - x1 * z0
    return a * 0.5


def area(ring):
    return abs(signed_area(ring))


def centroid(ring):
    a = signed_area(ring)
    if abs(a) < 1e-9:
        xs = [p[0] for p in ring]
        zs = [p[1] for p in ring]
        return (sum(xs) / len(xs), sum(zs) / len(zs))
    cx = cz = 0.0
    n = len(ring)
    for i in range(n):
        x0, z0 = ring[i]
        x1, z1 = ring[(i + 1) % n]
        f = x0 * z1 - x1 * z0
        cx += (x0 + x1) * f
        cz += (z0 + z1) * f
    return (cx / (6 * a), cz / (6 * a))


def point_in_ring(p, ring):
    x, z = p
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, zi = ring[i]
        xj, zj = ring[j]
        if (zi > z) != (zj > z):
            t = (z - zi) / (zj - zi)
            if x < xi + t * (xj - xi):
                inside = not inside
        j = i
    return inside


def dedupe(ring, eps=1e-6):
    out = []
    for p in ring:
        if not out or abs(p[0] - out[-1][0]) > eps or abs(p[1] - out[-1][1]) > eps:
            out.append(p)
    if len(out) > 1 and abs(out[0][0] - out[-1][0]) <= eps and abs(out[0][1] - out[-1][1]) <= eps:
        out.pop()
    return out


def convex_hull(points):
    pts = sorted(set((round(p[0], 6), round(p[1], 6)) for p in points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower = []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    upper = []
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def min_area_rect(points):
    """Minimum-area enclosing rectangle: (cx, cz, hx, hz, angle). The box's
    local x axis is (cos a, sin a); angle is folded to [-pi/4, pi/4) by
    swapping the half extents, so similar boxes get similar angles."""
    hull = convex_hull(points)
    if len(hull) < 3:
        xs = [p[0] for p in points]
        zs = [p[1] for p in points]
        return ((min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2,
                max(0.01, (max(xs) - min(xs)) / 2), max(0.01, (max(zs) - min(zs)) / 2), 0.0)
    best = None
    n = len(hull)
    for i in range(n):
        x0, z0 = hull[i]
        x1, z1 = hull[(i + 1) % n]
        a = math.atan2(z1 - z0, x1 - x0)
        c, s = math.cos(a), math.sin(a)
        us = [(p[0] * c + p[1] * s) for p in hull]
        vs = [(-p[0] * s + p[1] * c) for p in hull]
        ar = (max(us) - min(us)) * (max(vs) - min(vs))
        if best is None or ar < best[0] - 1e-9:
            best = (ar, a, min(us), max(us), min(vs), max(vs))
    _, a, u0, u1, v0, v1 = best
    cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
    c, s = math.cos(a), math.sin(a)
    cx, cz = cu * c - cv * s, cu * s + cv * c
    hx, hz = (u1 - u0) / 2, (v1 - v0) / 2
    return fold_box(cx, cz, hx, hz, a)


def fold_box(cx, cz, hx, hz, a):
    """Same box, angle folded into [-pi/4, pi/4)."""
    a = math.atan2(math.sin(a), math.cos(a))
    while a >= math.pi / 4:
        a -= math.pi / 2
        hx, hz = hz, hx
    while a < -math.pi / 4:
        a += math.pi / 2
        hx, hz = hz, hx
    return (cx, cz, hx, hz, a)


def box_corners(cx, cz, hx, hz, a):
    c, s = math.cos(a), math.sin(a)
    out = []
    for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        lx, lz = sx * hx, sz * hz
        out.append((cx + lx * c - lz * s, cz + lx * s + lz * c))
    return out


def to_local(p, cx, cz, a):
    c, s = math.cos(a), math.sin(a)
    dx, dz = p[0] - cx, p[1] - cz
    return (dx * c + dz * s, -dx * s + dz * c)


def from_local(l, cx, cz, a):
    c, s = math.cos(a), math.sin(a)
    return (cx + l[0] * c - l[1] * s, cz + l[0] * s + l[1] * c)


def rdp(points, tol):
    """Ramer-Douglas-Peucker on an open polyline."""
    if len(points) < 3:
        return list(points)
    stack = [(0, len(points) - 1)]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    while stack:
        i0, i1 = stack.pop()
        x0, z0 = points[i0]
        x1, z1 = points[i1]
        dx, dz = x1 - x0, z1 - z0
        ln = math.hypot(dx, dz)
        best, bi = -1.0, -1
        for i in range(i0 + 1, i1):
            px, pz = points[i]
            if ln < 1e-12:
                d = math.hypot(px - x0, pz - z0)
            else:
                d = abs(dx * (z0 - pz) - dz * (x0 - px)) / ln
            if d > best:
                best, bi = d, i
        if best > tol and bi > 0:
            keep[bi] = True
            stack.append((i0, bi))
            stack.append((bi, i1))
    return [p for p, k in zip(points, keep) if k]


def rdp_ring(ring, tol):
    if len(ring) < 4:
        return ring
    # Split at the vertex farthest from the first one so both halves are open.
    far = max(range(len(ring)), key=lambda i: (ring[i][0] - ring[0][0]) ** 2 + (ring[i][1] - ring[0][1]) ** 2)
    a = rdp(ring[: far + 1], tol)
    b = rdp(ring[far:] + [ring[0]], tol)
    out = a[:-1] + b[:-1]
    return out if len(out) >= 3 else ring


# --- Triangulation ---------------------------------------------------------

def _cross(o, a, b):
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def _in_tri(p, a, b, c):
    d1 = _cross(a, b, p)
    d2 = _cross(b, c, p)
    d3 = _cross(c, a, p)
    neg = d1 < -1e-12 or d2 < -1e-12 or d3 < -1e-12
    pos = d1 > 1e-12 or d2 > 1e-12 or d3 > 1e-12
    return not (neg and pos)


def bridge_holes(outer, holes):
    """Merges hole rings into the outer ring with zero-width cuts, so a
    simple ear clipper can triangulate it. Outer CCW, holes CW (fixed here)."""
    ring = list(outer)
    if signed_area(ring) < 0:
        ring.reverse()
    hs = []
    for h in holes:
        h = list(h)
        if signed_area(h) > 0:
            h.reverse()
        hs.append(h)
    hs.sort(key=lambda h: -max(p[0] for p in h))
    for h in hs:
        hi = max(range(len(h)), key=lambda i: h[i][0])
        hp = h[hi]
        # Nearest outer vertex whose connecting segment crosses no edge.
        cands = sorted(range(len(ring)), key=lambda i: (ring[i][0] - hp[0]) ** 2 + (ring[i][1] - hp[1]) ** 2)
        chosen = cands[0]
        for i in cands[:40]:
            if not _segment_crosses_ring(hp, ring[i], ring) and not _segment_crosses_ring(hp, ring[i], h):
                chosen = i
                break
        seq = h[hi:] + h[:hi] + [h[hi]]
        ring = ring[: chosen + 1] + seq + [ring[chosen]] + ring[chosen + 1:]
    return ring


def _segment_crosses_ring(a, b, ring):
    n = len(ring)
    for i in range(n):
        c = ring[i]
        d = ring[(i + 1) % n]
        if c == a or c == b or d == a or d == b:
            continue
        if _segments_intersect(a, b, c, d):
            return True
    return False


def _segments_intersect(a, b, c, d):
    d1 = _cross(c, d, a)
    d2 = _cross(c, d, b)
    d3 = _cross(a, b, c)
    d4 = _cross(a, b, d)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))


def triangulate(ring):
    """Ear clipping of a simple (or weakly simple) polygon. Returns a list of
    (a, b, c) point triples, counter-clockwise."""
    pts = list(ring)
    if signed_area(pts) < 0:
        pts.reverse()
    idx = list(range(len(pts)))
    tris = []
    guard = 0
    while len(idx) > 3 and guard < 100000:
        guard += 1
        n = len(idx)
        found = False
        for k in range(n):
            i0, i1, i2 = idx[(k - 1) % n], idx[k], idx[(k + 1) % n]
            a, b, c = pts[i0], pts[i1], pts[i2]
            cr = _cross(a, b, c)
            if cr <= 1e-12:
                if abs(cr) <= 1e-12 and (a == b or b == c):
                    idx.pop(k)
                    found = True
                    break
                continue
            ok = True
            for j in idx:
                if j in (i0, i1, i2):
                    continue
                p = pts[j]
                if p == a or p == b or p == c:
                    continue
                if _in_tri(p, a, b, c):
                    ok = False
                    break
            if ok:
                tris.append((a, b, c))
                idx.pop(k)
                found = True
                break
        if not found:
            # Degenerate leftovers: drop the flattest vertex and go on.
            k = min(range(n), key=lambda k: abs(_cross(pts[idx[(k - 1) % n]], pts[idx[k]], pts[idx[(k + 1) % n]])))
            idx.pop(k)
    if len(idx) == 3:
        a, b, c = (pts[i] for i in idx)
        if _cross(a, b, c) > 1e-12:
            tris.append((a, b, c))
    return tris


# --- Rasters -----------------------------------------------------------------

class Grid:
    """A raster over [0, w] x [0, h] game units at `res` units per cell."""

    def __init__(self, w, h, res):
        self.res = res
        self.nx = int(math.ceil(w / res))
        self.nz = int(math.ceil(h / res))
        self.a = np.zeros((self.nz, self.nx), dtype=bool)

    def fill_rings(self, rings, value=True):
        """Even-odd scanline fill of a set of rings (outer + holes)."""
        res = self.res
        edges = []
        for ring in rings:
            n = len(ring)
            for i in range(n):
                x0, z0 = ring[i]
                x1, z1 = ring[(i + 1) % n]
                if z0 != z1:
                    edges.append((x0, z0, x1, z1))
        if not edges:
            return
        e = np.array(edges, dtype=np.float64)
        zmin = max(0, int(math.floor(min(e[:, 1].min(), e[:, 3].min()) / res)))
        zmax = min(self.nz - 1, int(math.ceil(max(e[:, 1].max(), e[:, 3].max()) / res)))
        xs_centers = (np.arange(self.nx) + 0.5) * res
        for row in range(zmin, zmax + 1):
            zc = (row + 0.5) * res
            m = ((e[:, 1] > zc) != (e[:, 3] > zc))
            if not m.any():
                continue
            ee = e[m]
            t = (zc - ee[:, 1]) / (ee[:, 3] - ee[:, 1])
            xi = np.sort(ee[:, 0] + t * (ee[:, 2] - ee[:, 0]))
            for k in range(0, len(xi) - 1, 2):
                c0 = int(np.searchsorted(xs_centers, xi[k]))
                c1 = int(np.searchsorted(xs_centers, xi[k + 1]))
                if c1 > c0:
                    self.a[row, c0:c1] = value

    def stroke(self, pts, half_width, value=True):
        """Cells within half_width of a polyline."""
        res = self.res
        for i in range(len(pts) - 1):
            x0, z0 = pts[i]
            x1, z1 = pts[i + 1]
            c0 = max(0, int((min(x0, x1) - half_width) / res))
            c1 = min(self.nx, int((max(x0, x1) + half_width) / res) + 2)
            r0 = max(0, int((min(z0, z1) - half_width) / res))
            r1 = min(self.nz, int((max(z0, z1) + half_width) / res) + 2)
            if c1 <= c0 or r1 <= r0:
                continue
            xs = (np.arange(c0, c1) + 0.5) * res
            zs = (np.arange(r0, r1) + 0.5) * res
            X, Z = np.meshgrid(xs, zs)
            dx, dz = x1 - x0, z1 - z0
            ll = dx * dx + dz * dz
            if ll < 1e-12:
                t = np.zeros_like(X)
            else:
                t = np.clip(((X - x0) * dx + (Z - z0) * dz) / ll, 0.0, 1.0)
            d2 = (X - (x0 + t * dx)) ** 2 + (Z - (z0 + t * dz)) ** 2
            sub = self.a[r0:r1, c0:c1]
            if value:
                sub |= d2 <= half_width * half_width
            else:
                sub &= ~(d2 <= half_width * half_width)


def coverage(grid, factor=2):
    """Box-filter a fine boolean raster down by `factor` into coverage 0..1."""
    a = grid.a.astype(np.float32)
    nz, nx = a.shape
    nz2, nx2 = nz // factor, nx // factor
    a = a[: nz2 * factor, : nx2 * factor]
    return a.reshape(nz2, factor, nx2, factor).mean(axis=(1, 3))


def contours(field, res, iso=0.5):
    """Marching squares on a coverage field (cell centers at (i+0.5)*res).
    The field is padded with zeros, so every ring closes. Returns rings of
    (x, z) points."""
    f = np.pad(field, 1, constant_values=0.0)
    nz, nx = f.shape
    segs = {}

    def pt(i, j):  # grid node (row i, col j) of the padded field -> world
        return ((j - 1 + 0.5) * res, (i - 1 + 0.5) * res)

    def interp(i0, j0, i1, j1):
        v0, v1 = f[i0, j0], f[i1, j1]
        t = 0.5 if abs(v1 - v0) < 1e-9 else (iso - v0) / (v1 - v0)
        p0, p1 = pt(i0, j0), pt(i1, j1)
        return (round(p0[0] + t * (p1[0] - p0[0]), 5), round(p0[1] + t * (p1[1] - p0[1]), 5))

    inside = f >= iso
    links = []
    for i in range(nz - 1):
        row_any = inside[i].any() or inside[i + 1].any()
        if not row_any:
            continue
        for j in range(nx - 1):
            tl, tr, br, bl = inside[i, j], inside[i, j + 1], inside[i + 1, j + 1], inside[i + 1, j]
            code = (tl << 3) | (tr << 2) | (br << 1) | bl
            if code == 0 or code == 15:
                continue
            top = lambda: interp(i, j, i, j + 1)  # noqa: E731
            right = lambda: interp(i, j + 1, i + 1, j + 1)  # noqa: E731
            bottom = lambda: interp(i + 1, j, i + 1, j + 1)  # noqa: E731
            left = lambda: interp(i, j, i + 1, j)  # noqa: E731
            # Every segment a -> b has the inside on the same side
            # (cross(b - a, inside - a) < 0), so they chain into rings.
            if code == 5 or code == 10:
                center = (f[i, j] + f[i, j + 1] + f[i + 1, j] + f[i + 1, j + 1]) / 4
                joined = center >= iso
                if code == 5:   # tr + bl
                    pairs = [(top, left), (bottom, right)] if joined else [(top, right), (bottom, left)]
                else:           # tl + br
                    pairs = [(right, top), (left, bottom)] if joined else [(left, top), (right, bottom)]
            else:
                pairs = {
                    1: [(bottom, left)], 2: [(right, bottom)], 3: [(right, left)], 4: [(top, right)],
                    6: [(top, bottom)], 7: [(top, left)], 8: [(left, top)],
                    9: [(bottom, top)], 11: [(right, top)], 12: [(left, right)],
                    13: [(bottom, right)], 14: [(left, bottom)],
                }[code]
            for a, b in pairs:
                links.append((a(), b()))
    # Chain segments into rings (each point starts exactly one segment).
    nxt = {}
    for a, b in links:
        nxt.setdefault(a, []).append(b)
    rings = []
    for start in list(nxt.keys()):
        if not nxt.get(start):
            continue
        ring = [start]
        cur = nxt[start].pop()
        steps = 0
        while cur != start and steps < 1000000:
            steps += 1
            ring.append(cur)
            outs = nxt.get(cur)
            if not outs:
                break
            cur = outs.pop()
        if len(ring) >= 3:
            rings.append(ring)
    return rings


def polygons_from_field(field, res, tol, min_area):
    """Field -> [(outer, [holes])] simplified polygons."""
    rings = [rdp_ring(dedupe(r), tol) for r in contours(field, res)]
    rings = [r for r in rings if len(r) >= 3 and area(r) >= min_area * 0.25]
    # Nesting depth decides outer (even) vs hole (odd).
    info = []
    for r in rings:
        p = r[0]
        depth = 0
        for o in rings:
            if o is r:
                continue
            if area(o) > area(r) and point_in_ring(_inner_probe(r), o):
                depth += 1
        info.append((r, depth))
    outers = [(r, []) for r, d in info if d % 2 == 0 and area(r) >= min_area]
    for r, d in info:
        if d % 2 == 1:
            best = None
            for o, holes in outers:
                if area(o) > area(r) and point_in_ring(_inner_probe(r), o):
                    if best is None or area(o) < area(best[0]):
                        best = (o, holes)
            if best is not None:
                best[1].append(r)
    return outers


def _inner_probe(ring):
    # A vertex nudged toward the centroid (avoids testing exactly on edges).
    c = centroid(ring)
    p = ring[0]
    return (p[0] + (c[0] - p[0]) * 1e-3, p[1] + (c[1] - p[1]) * 1e-3)
