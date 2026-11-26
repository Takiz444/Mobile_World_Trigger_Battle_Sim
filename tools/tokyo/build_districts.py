"""Builds the game's Tokyo district maps from OpenStreetMap data.

    python -I tools/tokyo/build_districts.py [--cache build/osm_cache] [--out common/map/tokyo] [--only shibuya]

Reads the Overpass downloads made by fetch_osm.py and writes one JSON file per
district plus index.json. The game loads them with TokyoMap
(common/map/tokyo_map.gd). The output is low-poly on purpose:
  - buildings become oriented boxes (irregular footprints split into a few),
    with a height in game floors estimated from OSM tags and the street
    they face,
  - water, parks and the land around them become simplified polygons,
  - roads and at-grade railways stay polylines with a width,
  - elevated railways and the Shuto expressway become decks on pillars,
  - street furniture (trees, lamps, poles, vending machines, signs) is placed
    procedurally along the streets.

Data (c) OpenStreetMap contributors, ODbL 1.0.
"""
import argparse
import hashlib
import json
import math
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geom  # noqa: E402
import sources  # noqa: E402
import zones as zonelib  # noqa: E402
from districts import DISTRICTS, METERS_PER_UNIT  # noqa: E402

FORMAT = 1

# Battle zones are the size and shape of the original battle map, the 32 x 32
# flat-top hex sheet (MapData; hex size 1): 31 x 1.5 + 2 wide, 32.5 x sqrt3
# tall, so about 48.5 x 56.3 units. Zones aim for its area and proportions
# and are never longer than ZONE_ASPECT_MAX to one.
SHEET_W = 31 * 1.5 + 2.0
SHEET_H = 32.5 * math.sqrt(3.0)
ZONE_AREA = SHEET_W * SHEET_H
ZONE_ASPECT = SHEET_H / SHEET_W
ZONE_ASPECT_MAX = 1.6
ZONE_MARGIN = 32.0   # from the edge of the map data: the fog starts ~20 inside it
# A zone must be at least this much building footprint (by area).
ZONE_MIN_BUILT = 0.5

# Gameplay floors (a floor is 1 unit tall) from real heights (PLATEAU's
# measured heights where available). Heights are compressed (a 2.5 m unit
# horizontally, about 4.5-9 m per floor vertically) so streets stay visible
# from the battle camera; buildings over TOWER_M are sealed towers, drawn up
# to TOWER_MAX units tall.
FLOOR_BREAKS_M = [7.5, 12.0, 18.0, 25.0, 34.0, 45.0]   # floors 1..7
TOWER_M = 60.0
TOWER_MAX = 22.0
MAX_FLOORS = 7

# Building styles (the renderer picks palettes and facades by these).
S_HOUSE, S_APARTMENT, S_OFFICE, S_SHOP, S_TEMPLE, S_STATION, S_TOWER, S_SCHOOL = range(8)
# Solid styles.
SOL_PILLAR, SOL_TOWER, SOL_TEMPLE, SOL_GATE_POST, SOL_PAGODA = range(5)
# Deck kinds.
DK_RAIL, DK_ROAD, DK_GATE_ROOF, DK_SIGN = range(4)
# Road classes.
R_MAJOR, R_SECONDARY, R_TERTIARY, R_MINOR, R_SERVICE, R_PEDESTRIAN = range(6)

ROAD_CLASS = {
    "motorway": R_MAJOR, "trunk": R_MAJOR, "primary": R_MAJOR,
    "motorway_link": R_SECONDARY, "trunk_link": R_SECONDARY, "primary_link": R_SECONDARY,
    "secondary": R_SECONDARY, "secondary_link": R_TERTIARY,
    "tertiary": R_TERTIARY, "tertiary_link": R_TERTIARY,
    "unclassified": R_MINOR, "residential": R_MINOR, "living_street": R_MINOR, "road": R_MINOR,
    "service": R_SERVICE,
    "pedestrian": R_PEDESTRIAN,
}
# Default carriageway widths in metres.
ROAD_WIDTH_M = {
    "motorway": 14, "trunk": 22, "primary": 18, "secondary": 13, "tertiary": 9,
    "motorway_link": 7, "trunk_link": 7, "primary_link": 7, "secondary_link": 7, "tertiary_link": 6,
    "unclassified": 5.5, "residential": 5, "living_street": 4.5, "road": 5, "service": 3.5,
    "pedestrian": 5,
}
RAIL_KINDS = {"rail", "light_rail", "narrow_gauge", "monorail", "subway", "tram"}

DECK_RAIL_Y = 2.2
DECK_ROAD_Y = 3.2
DECK_THICK = 0.35
RAIL_TRACK_W = 1.7      # units per track
GRID_RES = 0.25         # fine raster for area layers (coverage at 0.5)


def r2(v):
    return round(float(v), 2)


def r3(v):
    return round(float(v), 3)


def stable_rand(*parts):
    h = hashlib.md5("|".join(str(p) for p in parts).encode()).hexdigest()
    return int(h[:8], 16) / 0xFFFFFFFF


class Projector:
    """lat/lon -> game units. The district is turned by `turn` radians so its
    main street grid runs along the axes (play areas are axis-aligned
    rectangles, so their edges can follow streets, and the camera looks
    straight down them). The square shrinks so the turned corners still lie
    inside the downloaded area (fetch_osm pads it by 45%)."""

    def __init__(self, d, turn=0.0):
        self.lat0 = d["lat"]
        self.lon0 = d["lon"]
        self.turn = turn
        full = d["size_m"] / METERS_PER_UNIT
        cover = full * 1.45 / (abs(math.cos(turn)) + abs(math.sin(turn)))
        self.size = round(min(full, cover), 1)
        self.kx = 111320.0 * math.cos(math.radians(self.lat0)) / METERS_PER_UNIT
        self.kz = 110574.0 / METERS_PER_UNIT
        self.c = math.cos(-turn)
        self.s = math.sin(-turn)

    def offset(self, ex, sz):
        """An east / south offset (game units) turned into the district frame."""
        return (ex * self.c - sz * self.s, ex * self.s + sz * self.c)

    def __call__(self, lat, lon):
        ox, oz = self.offset((lon - self.lon0) * self.kx, (self.lat0 - lat) * self.kz)
        return (ox + self.size / 2, oz + self.size / 2)


def grid_turn(osm, d):
    """The main street direction of a district (radians, folded into
    [-pi/4, pi/4)): the peak of a length-weighted histogram of road
    directions modulo 90 degrees."""
    proj = Projector(d)
    bins = [0.0] * 90
    for e in osm.get("elements", []):
        if e["type"] != "way":
            continue
        hw = e.get("tags", {}).get("highway")
        if hw not in ROAD_CLASS or ROAD_CLASS[hw] > R_MINOR:
            continue
        pts = way_points(e, proj)
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            ln = math.hypot(b[0] - a[0], b[1] - a[1])
            if ln < 0.5:
                continue
            deg = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 90.0
            bins[int(deg) % 90] += ln
    smooth = [sum(bins[(i + k) % 90] * w for k, w in ((-2, 0.25), (-1, 0.6), (0, 1.0), (1, 0.6), (2, 0.25))) for i in range(90)]
    peak = max(range(90), key=lambda i: smooth[i]) + 0.5
    if peak >= 45:
        peak -= 90
    return math.radians(peak)


def parse_num(v):
    if v is None:
        return None
    try:
        s = str(v).split(";")[0].strip().lower().replace("m", "").strip()
        return float(s)
    except ValueError:
        return None


# --- OSM element helpers -------------------------------------------------------

def way_points(el, proj):
    return [proj(g["lat"], g["lon"]) for g in el.get("geometry", []) if g]


def relation_rings(el, proj):
    """Assembles a multipolygon relation into (outers, inners) closed rings."""
    parts = {"outer": [], "inner": []}
    for m in el.get("members", []):
        if m.get("type") != "way" or not m.get("geometry"):
            continue
        role = m.get("role") or "outer"
        if role not in parts:
            role = "outer"
        pts = [proj(g["lat"], g["lon"]) for g in m["geometry"] if g]
        if len(pts) >= 2:
            parts[role].append(pts)
    return _join(parts["outer"]), _join(parts["inner"])


def _join(chains):
    rings = []
    chains = [list(c) for c in chains]
    while chains:
        cur = chains.pop()
        guard = 0
        while _dist(cur[0], cur[-1]) > 1e-6 and guard < 10000:
            guard += 1
            hit = False
            for i, c in enumerate(chains):
                if _dist(cur[-1], c[0]) < 1e-6:
                    cur += c[1:]
                elif _dist(cur[-1], c[-1]) < 1e-6:
                    cur += list(reversed(c))[1:]
                elif _dist(cur[0], c[-1]) < 1e-6:
                    cur = c[:-1] + cur
                elif _dist(cur[0], c[0]) < 1e-6:
                    cur = list(reversed(c))[:-1] + cur
                else:
                    continue
                chains.pop(i)
                hit = True
                break
            if not hit:
                break
        ring = geom.dedupe(cur)
        if len(ring) >= 3:
            rings.append(ring)
    return rings


def _dist(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def area_rings(el, proj):
    """(outers, inners) of a closed way or multipolygon relation."""
    if el["type"] == "way":
        pts = way_points(el, proj)
        if len(pts) >= 4 and _dist(pts[0], pts[-1]) < 1e-6:
            return [geom.dedupe(pts)], []
        return [], []
    if el["type"] == "relation":
        return relation_rings(el, proj)
    return [], []


# --- Spatial hash for boxes -----------------------------------------------------

class BoxIndex:
    def __init__(self, cell=6.0):
        self.cell = cell
        self.cells = {}
        self.boxes = []

    def add(self, box):
        i = len(self.boxes)
        self.boxes.append(box)
        xs = [p[0] for p in box["corners"]]
        zs = [p[1] for p in box["corners"]]
        for cx in range(int(min(xs) // self.cell), int(max(xs) // self.cell) + 1):
            for cz in range(int(min(zs) // self.cell), int(max(zs) // self.cell) + 1):
                self.cells.setdefault((cx, cz), []).append(i)
        return i

    def near(self, p, r=0.0):
        out = set()
        for cx in range(int((p[0] - r) // self.cell), int((p[0] + r) // self.cell) + 1):
            for cz in range(int((p[1] - r) // self.cell), int((p[1] + r) // self.cell) + 1):
                out.update(self.cells.get((cx, cz), ()))
        return [self.boxes[i] for i in out]

    def contains(self, p, grow=0.0):
        for b in self.near(p, grow + 1.0):
            lx, lz = geom.to_local(p, b["cx"], b["cz"], b["a"])
            if abs(lx) <= b["hx"] + grow and abs(lz) <= b["hz"] + grow:
                return b
        return None


def make_box(cx, cz, hx, hz, a, **kw):
    b = {"cx": cx, "cz": cz, "hx": hx, "hz": hz, "a": a}
    b["corners"] = geom.box_corners(cx, cz, hx, hz, a)
    b.update(kw)
    return b


# --- Buildings -------------------------------------------------------------------

def decompose(pieces, max_boxes=10, on_road=None):
    """A footprint -> list of (cx, cz, hx, hz, a) boxes. `pieces`:
    [(outer, holes)], unioned (pieces of one building cut by tile edges may
    overlap). With `on_road(p)`, the parts over a carriageway are left out
    (footprints that overhang the street, from loose mapping or from
    approximating an irregular lot by a rectangle)."""
    pts = [q for outer, _ in pieces for q in outer]
    if len(pts) < 3:
        return []
    cx, cz, hx, hz, a = geom.min_area_rect(pts)
    rect_area = 4 * hx * hz
    if rect_area <= 0.05:
        return []
    res = max(0.25, min(0.6, min(hx, hz) / 5.0))
    w, h = 2 * hx, 2 * hz
    grid = geom.Grid(w, h, res)
    for outer, holes in pieces:
        grid.fill_rings([[(lx + hx, lz + hz) for lx, lz in (geom.to_local(q, cx, cz, a) for q in r)] for r in [outer] + holes])
    total = float(grid.a.sum()) * res * res
    if total < 0.5:
        return []
    fill = total / rect_area
    touches_road = False
    if on_road is not None:
        for i in range(7):
            for j in range(7):
                q = geom.from_local(((i / 6 - 0.5) * 2 * hx * 0.96, (j / 6 - 0.5) * 2 * hz * 0.96), cx, cz, a)
                if on_road(q):
                    touches_road = True
                    break
            if touches_road:
                break
    if not touches_road and (fill >= 0.86 or total < 8.0 or min(hx, hz) < 1.0):
        return [(cx, cz, hx, hz, a)]
    if on_road is not None:
        for r in range(grid.nz):
            for c in range(grid.nx):
                if grid.a[r, c]:
                    q = geom.from_local(((c + 0.5) * res - hx, (r + 0.5) * res - hz), cx, cz, a)
                    if on_road(q):
                        grid.a[r, c] = False
    cells = grid.a.copy()
    filled = cells.sum()
    if filled == 0:
        return []
    out = []
    covered = 0
    min_cells = max(1, int(1.6 / (res * res)))
    while len(out) < max_boxes and covered < 0.95 * filled:
        r = _largest_rect(cells)
        if r is None:
            break
        r0, c0, r1, c1 = r
        n = (r1 - r0) * (c1 - c0)
        if n < min_cells:
            break
        cells[r0:r1, c0:c1] = False
        covered += n
        x0 = -hx + c0 * res
        x1 = min(hx, -hx + c1 * res)
        z0 = -hz + r0 * res
        z1 = min(hz, -hz + r1 * res)
        lc = ((x0 + x1) / 2, (z0 + z1) / 2)
        wc = geom.from_local(lc, cx, cz, a)
        out.append((wc[0], wc[1], (x1 - x0) / 2, (z1 - z0) / 2, a))
    return out


def height_to_floors(h):
    """Real height (m) -> game floors 1..MAX_FLOORS, or None for a tower."""
    if h >= TOWER_M:
        return None
    for k, lim in enumerate(FLOOR_BREAKS_M):
        if h < lim:
            return k + 1
    return MAX_FLOORS


def _largest_rect(cells):
    """Largest all-True rectangle: (r0, c0, r1, c1) exclusive ends."""
    nz, nx = cells.shape
    heights = [0] * nx
    best = None
    best_area = 0
    for r in range(nz):
        row = cells[r]
        for c in range(nx):
            heights[c] = heights[c] + 1 if row[c] else 0
        stack = []
        for c in range(nx + 1):
            hgt = heights[c] if c < nx else 0
            start = c
            while stack and stack[-1][1] >= hgt:
                s, sh = stack.pop()
                ar = sh * (c - s)
                if ar > best_area:
                    best_area = ar
                    best = (r - sh + 1, s, r + 1, c)
                start = s
            stack.append((start, hgt))
    return best


def estimate_storeys(tags, area_m2, frontage, d, key):
    lv = parse_num(tags.get("building:levels"))
    if lv is not None and lv > 0:
        return lv, True
    hm = parse_num(tags.get("height"))
    if hm is not None and hm > 0:
        return max(1.0, hm / 3.3), True
    b = tags.get("building", "yes")
    jit = stable_rand(key, "h")
    if b in ("shed", "garage", "garages", "hut", "kiosk", "roof", "carport", "toilets"):
        return 1, False
    if b in ("house", "detached", "semidetached_house", "terrace", "bungalow"):
        return 2 + (1 if jit > 0.75 else 0), False
    if b in ("temple", "shrine", "church", "chapel"):
        return 2, False
    if b in ("train_station", "transportation"):
        return 3 + jit * 2, False
    if b in ("school", "university", "college", "hospital", "public", "civic"):
        return 4 + jit * 2, False
    if b in ("apartments", "residential", "dormitory"):
        base = 3 if area_m2 < 150 else 5 if area_m2 < 400 else 8 if area_m2 < 1000 else 11
    else:
        base = (2 if area_m2 < 50 else 3 if area_m2 < 110 else 4 if area_m2 < 220 else
                6 if area_m2 < 500 else 8 if area_m2 < 1200 else 11 if area_m2 < 3000 else 15)
    s = base * d.get("density", 1.0)
    if frontage == 2:
        s = s * 1.6 + 2
    elif frontage == 1:
        s = s * 1.25 + 1
    s *= 0.8 + 0.45 * jit
    return max(1.0, s), False


def storeys_to_floors(s):
    """Real storeys -> game floors (a floor is one unit tall). Compressed so
    the streets stay visible from the battle camera."""
    s = round(s)
    if s <= 3:
        return 1
    if s <= 6:
        return 2
    if s <= 10:
        return 3
    if s <= 16:
        return 4
    return 5


def pick_style(tags, storeys, area_m2, frontage, d, key):
    b = tags.get("building", "yes")
    amen = tags.get("amenity", "")
    r = stable_rand(key, "style")
    if b in ("temple", "shrine") or amen == "place_of_worship" and b not in ("church", "yes", "apartments"):
        return S_TEMPLE
    if b in ("train_station", "transportation"):
        return S_STATION
    if b in ("school", "university", "college", "kindergarten", "hospital"):
        return S_SCHOOL
    if b in ("house", "detached", "semidetached_house", "terrace", "bungalow"):
        return S_HOUSE
    if b in ("apartments", "residential", "dormitory"):
        return S_APARTMENT if storeys > 2 else S_HOUSE
    if b in ("office",):
        return S_OFFICE
    if b in ("retail", "commercial", "supermarket", "hotel"):
        return S_SHOP if storeys < 8 or r < 0.5 else S_OFFICE
    res = d.get("residential", 0.3)
    if frontage == 0 and storeys <= 3 and area_m2 < 130 and r < res * 1.6:
        return S_HOUSE
    if frontage == 0 and r < res * 1.2:
        return S_APARTMENT
    if frontage > 0 and r < 0.35 + 0.5 * d.get("neon", 0.5):
        return S_SHOP
    return S_OFFICE if storeys >= 5 else (S_SHOP if r < 0.6 else S_APARTMENT)


# --- Build -----------------------------------------------------------------------

args_cache_tiles = os.path.join("build", "tile_cache")


def build(d, osm, out_dir):
    turn = grid_turn(osm, d) if d.get("align_grid", True) else 0.0
    proj = Projector(d, turn)
    W = H = proj.size
    rng = random.Random(d["id"])
    els = osm.get("elements", [])
    ways = [e for e in els if e["type"] == "way"]
    rels = [e for e in els if e["type"] == "relation"]
    nodes = [e for e in els if e["type"] == "node"]

    def inside(p, m=0.0):
        return -m <= p[0] <= W + m and -m <= p[1] <= H + m

    # Landmarks and the zones kept free for them.
    landmarks = []
    noplay = []
    clear_zones = []
    for lm in d.get("landmarks", []):
        x, z = proj(lm["lat"], lm["lon"])
        landmarks.append({"type": lm["type"], "x": r2(x), "z": r2(z), "rot": r3(math.radians(lm.get("rot", 0)) - turn)})
        if lm.get("noplay_m"):
            noplay.append([r2(x), r2(z), r2(lm["noplay_m"] / METERS_PER_UNIT)])
        clear = {"tokyo_tower": 0.0, "kaminarimon": 3.2, "kabukicho_gate": 0.0, "scramble": 0.0}.get(lm["type"], 0.0)
        if clear > 0:
            clear_zones.append((x, z, clear))

    # --- Roads -----------------------------------------------------------------
    path_lines = []     # footpaths (drawn, and zone borders)
    roads = []          # [cls, width, pts]
    bridges = []        # walkable over water / rail
    decks = []
    solids = []
    rail_lines = []     # at-grade, blocked
    way_nodes = {}      # node id -> [(road record, index)]
    road_recs = []
    elevated_lines = []
    for w in ways:
        t = w.get("tags", {})
        hw = t.get("highway")
        rw = t.get("railway")
        layer = parse_num(t.get("layer")) or 0
        tunnel = t.get("tunnel") not in (None, "no") or t.get("covered") == "yes" or layer < 0
        bridge = t.get("bridge") not in (None, "no")
        pts = way_points(w, proj)
        if len(pts) < 2:
            continue
        if not any(inside(p, 30) for p in pts):
            continue
        if hw in ROAD_CLASS and not tunnel and t.get("area") != "yes":
            width_m = parse_num(t.get("width"))
            lanes = parse_num(t.get("lanes"))
            if width_m is None and lanes is not None:
                width_m = lanes * 3.1 + 1.0
            if width_m is None:
                width_m = ROAD_WIDTH_M[hw]
            width_m = max(2.5, min(40.0, width_m))
            wu = width_m / METERS_PER_UNIT
            if hw.startswith("motorway") and (bridge or layer >= 1):
                elevated_lines.append({"pts": pts, "width": max(2.8, wu), "kind": DK_ROAD,
                                       "y0": DECK_ROAD_Y + max(0, layer - 1) * 0.9})
                continue
            rec = {"cls": ROAD_CLASS[hw], "w": wu, "pts": pts, "bridge": bridge,
                   "oneway": t.get("oneway") in ("yes", "1", "-1"), "hw": hw, "nodes": w.get("nodes", [])}
            road_recs.append(rec)
            for i, nid in enumerate(rec["nodes"]):
                way_nodes.setdefault(nid, []).append((rec, i))
            if bridge:
                bridges.append(rec)
        elif rw in RAIL_KINDS and t.get("usage") != "industrial":
            if tunnel or rw == "subway" and not bridge and layer < 1:
                continue
            if t.get("service") in ("yard", "siding", "spur") and not bridge:
                continue
            if bridge or layer >= 1:
                elevated_lines.append({"pts": pts, "width": RAIL_TRACK_W, "kind": DK_RAIL,
                                       "y0": DECK_RAIL_Y + max(0, layer - 1) * 1.0})
            else:
                rail_lines.append(pts)

    # Railway platforms on the ground are part of the fenced railway.
    platform_rings = []
    for e in ways + rels:
        t = e.get("tags", {})
        if t.get("railway") == "platform" or t.get("public_transport") == "platform" and t.get("train") == "yes":
            layer = parse_num(t.get("layer")) or 0
            if layer != 0 or t.get("covered") == "yes" and False:
                continue
            outs, _ = area_rings(e, proj)
            platform_rings += outs

    # --- Area layers (water, green) ------------------------------------------------
    water = geom.Grid(W, H, GRID_RES)
    green = geom.Grid(W, H, GRID_RES)
    parking = geom.Grid(W, H, GRID_RES)
    parking_rings = []
    for e in ways + rels:
        t = e.get("tags", {})
        is_water = (t.get("natural") == "water" or t.get("waterway") in ("riverbank", "dock", "canal") and e["type"] == "relation"
                    or t.get("waterway") == "riverbank" or t.get("landuse") in ("reservoir", "basin")
                    or (t.get("water") is not None and t.get("natural") == "water"))
        if t.get("leisure") == "swimming_pool" or t.get("water") in ("pool", "fountain", "wastewater"):
            is_water = False
        is_green = (t.get("leisure") in ("park", "garden", "playground", "common")
                    or t.get("landuse") in ("grass", "forest", "recreation_ground", "village_green", "meadow", "cemetery", "religious")
                    or t.get("natural") in ("wood", "scrub", "grassland"))
        is_parking = t.get("amenity") == "parking" and t.get("parking") not in ("underground", "multi-storey", "rooftop") \
            and (parse_num(t.get("layer")) or 0) == 0
        if is_parking and not is_water:
            outs, ins = area_rings(e, proj)
            if outs and any(inside(q, 10) for r in outs for q in r):
                parking.fill_rings(outs + ins)
                parking_rings += outs
            continue
        if not (is_water or is_green):
            continue
        outs, ins = area_rings(e, proj)
        if not outs:
            continue
        if not any(inside(p, 20) for r in outs for p in r):
            continue
        (water if is_water else green).fill_rings(outs + ins)
    for w in ways:
        t = w.get("tags", {})
        ww = t.get("waterway")
        if ww in ("river", "canal") and t.get("tunnel") in (None, "no") and t.get("layer", "0") not in ("-1", "-2"):
            width_m = parse_num(t.get("width")) or (22.0 if ww == "river" else 12.0)
            pts = way_points(w, proj)
            if len(pts) >= 2:
                water.stroke(pts, width_m / METERS_PER_UNIT / 2)
    water_cov = geom.coverage(water, 2)
    green.a &= ~water.a
    green_cov = geom.coverage(green, 2)
    parking.a &= ~water.a & ~green.a
    parking_cov = geom.coverage(parking, 2)
    parking_polys = geom.polygons_from_field(parking_cov, GRID_RES * 2, 0.25, 4.0)
    water_polys = geom.polygons_from_field(water_cov, GRID_RES * 2, 0.22, 6.0)
    green_polys = geom.polygons_from_field(green_cov, GRID_RES * 2, 0.3, 6.0)
    land_cov = 1.0 - water_cov
    land_polys = geom.polygons_from_field(land_cov, GRID_RES * 2, 0.22, 1.0)

    def tris_of(polys, keep_holes=True):
        out = []
        for outer, holes in polys:
            ring = geom.bridge_holes(outer, holes) if (holes and keep_holes) else outer
            for a, b, c in geom.triangulate(ring):
                out += [r2(a[0]), r2(a[1]), r2(b[0]), r2(b[1]), r2(c[0]), r2(c[1])]
        return out

    def in_water(p):
        c = int(p[0] / (GRID_RES * 2))
        r = int(p[1] / (GRID_RES * 2))
        if 0 <= r < water_cov.shape[0] and 0 <= c < water_cov.shape[1]:
            return water_cov[r, c] >= 0.5
        return False

    def in_green(p):
        c = int(p[0] / (GRID_RES * 2))
        r = int(p[1] / (GRID_RES * 2))
        if 0 <= r < green_cov.shape[0] and 0 <= c < green_cov.shape[1]:
            return green_cov[r, c] >= 0.5
        return False

    # Road proximity rasters: which buildings front a big street.
    major = geom.Grid(W, H, 1.0)
    medium = geom.Grid(W, H, 1.0)
    on_road = geom.Grid(W, H, 0.5)
    road_core = geom.Grid(W, H, 0.25)
    for rec in road_recs:
        if rec["cls"] <= R_SERVICE:
            road_core.stroke(rec["pts"], max(0.0, rec["w"] / 2 - 0.3))
    for rec in road_recs:
        if rec["cls"] == R_MAJOR or rec["cls"] == R_SECONDARY and rec["w"] >= 4.5:
            major.stroke(rec["pts"], rec["w"] / 2 + 3.0)
        elif rec["cls"] <= R_TERTIARY:
            medium.stroke(rec["pts"], rec["w"] / 2 + 2.5)
        on_road.stroke(rec["pts"], rec["w"] / 2)
    for el in elevated_lines:
        if el["kind"] == DK_ROAD:
            major.stroke(el["pts"], el["width"] / 2 + 3.0)

    def grid_at(g, p):
        c = int(p[0] / g.res)
        r = int(p[1] / g.res)
        return 0 <= r < g.nz and 0 <= c < g.nx and bool(g.a[r, c])

    def frontage(corners):
        if any(grid_at(major, p) for p in corners):
            return 2
        if any(grid_at(medium, p) for p in corners):
            return 1
        return 0

    # Elevated decks: segment boxes; their footprint caps buildings below.
    deck_index = BoxIndex(8.0)
    for el in elevated_lines:
        pts = geom.rdp(el["pts"], 0.25)
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            ln = math.hypot(b[0] - a[0], b[1] - a[1])
            if ln < 0.05:
                continue
            mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            if not inside(mid, 20):
                continue
            ang = math.atan2(b[1] - a[1], b[0] - a[0])
            box = make_box(mid[0], mid[1], ln / 2 + 0.12, el["width"] / 2, ang,
                           y0=el["y0"], y1=el["y0"] + DECK_THICK, kind=el["kind"])
            deck_index.add(box)
            decks.append(box)
        # Piers.
        spacing = 6.0 if el["kind"] == DK_RAIL else 8.5
        total = sum(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]) for i in range(len(pts) - 1))
        s = spacing * 0.5
        while s < total:
            p, ang = _along(pts, s)
            s += spacing
            if not inside(p, 4) or in_water(p) and el["kind"] == DK_RAIL and False:
                continue
            if grid_at(on_road, p) and (el["kind"] == DK_RAIL or not grid_at(major, p)):
                continue
            if el["kind"] == DK_RAIL:
                solids.append(make_box(p[0], p[1], 0.22, el["width"] * 0.42, ang, h=el["y0"], style=SOL_PILLAR))
            else:
                solids.append(make_box(p[0], p[1], 0.4, 0.4, ang, h=el["y0"], style=SOL_PILLAR))

    # --- Buildings -------------------------------------------------------------
    # Footprints and heights from PLATEAU (complete, measured); OSM buildings
    # only tell what a building is (temple, station, house...) and stand in
    # where PLATEAU has nothing.
    bindex = BoxIndex(6.0)
    buildings = []
    group = 0
    stats = {"plateau": 0, "measured": 0, "osm": 0}
    osm_bld = []      # (outer ring, tags)
    osm_cells = {}
    for e in ways + rels:
        t = e.get("tags", {})
        bt = t.get("building")
        if bt is None or bt in ("no", "roof", "ruins", "carport"):
            continue
        layer = parse_num(t.get("layer")) or 0
        if layer < 0 or t.get("location") in ("underground", "roof"):
            continue
        outs, ins = area_rings(e, proj)
        outs = [r for r in outs if geom.area(r) > 0.6]
        if not outs:
            continue
        k = len(osm_bld)
        osm_bld.append((outs, ins, t, f"{e['type']}{e['id']}"))
        for r in outs:
            xs = [q[0] for q in r]
            zs = [q[1] for q in r]
            for gx in range(int(min(xs) // 8), int(max(xs) // 8) + 1):
                for gz in range(int(min(zs) // 8), int(max(zs) // 8) + 1):
                    osm_cells.setdefault((gx, gz), []).append(k)

    def osm_at(q):
        for k in osm_cells.get((int(q[0] // 8), int(q[1] // 8)), []):
            if any(geom.point_in_ring(q, r) for r in osm_bld[k][0]):
                return osm_bld[k]
        return None

    plateau = sources.load_plateau(args_cache_tiles, d, proj, inside)
    tower_spots = [(lm["x"], lm["z"]) for lm in landmarks if lm["type"] == "tokyo_tower"]
    entries = []      # (pieces, height m or None, tags, key)
    if plateau:
        for pb in plateau:
            outer = max((o for o, _ in pb["pieces"]), key=geom.area)
            c = geom.centroid(outer)
            h = pb["h"]
            if h is not None and h > 150 and any(math.hypot(c[0] - x, c[1] - z) < 25 for x, z in tower_spots):
                # Tokyo Tower: PLATEAU models it with its base building. Keep
                # the footprint as Foot Town (about 25 m) and draw the
                # lattice tower over it as a landmark.
                h = 25.0
            hit = osm_at(c)
            entries.append((pb["pieces"], h, hit[2] if hit else {}, pb["id"]))
            stats["plateau"] += 1
            stats["measured"] += 1 if pb["h"] is not None else 0
    else:
        for outs, ins, t, key in osm_bld:
            entries.append(([(o, ins if o is max(outs, key=geom.area) else []) for o in outs], None, t, key))
            stats["osm"] += 1
    footprints = [pc for pieces, _h, _t, _k in entries for pc in pieces]
    for pieces, h_m, t, key in entries:
        b = t.get("building", "yes")
        outer = max((o for o, _ in pieces), key=geom.area)
        c = geom.centroid(outer)
        if not inside(c, 2):
            continue
        if any(math.hypot(c[0] - x, c[1] - z) < rr for x, z, rr in clear_zones):
            continue
        boxes = decompose(pieces, on_road=lambda q: grid_at(road_core, q))
        if not boxes:
            continue
        tot = sum(4 * bx[2] * bx[3] for bx in boxes)
        if tot < 1.6:
            continue
        area_m2 = tot * METERS_PER_UNIT ** 2
        corners = [q for pc in boxes for q in geom.box_corners(*pc)]
        fr = frontage(corners)
        if h_m is None:
            storeys, _tagged = estimate_storeys(t, area_m2, fr, d, key)
            h_m = storeys * 3.3
        storeys = max(1.0, h_m / 3.3)
        style = pick_style(t, storeys, area_m2, fr, d, key)
        pagoda = b == "pagoda" or t.get("tower:type") == "pagoda" or "塔" in t.get("name", "") and b in ("temple", "yes") and tot < 120
        # Under a deck: keep below it.
        cap = None
        for q in [c] + corners:
            for dk in deck_index.near(q, 0.5):
                lx, lz = geom.to_local(q, dk["cx"], dk["cz"], dk["a"])
                if abs(lx) <= dk["hx"] + 0.3 and abs(lz) <= dk["hz"] + 0.3:
                    cap = min(cap if cap is not None else 99, int(dk["y0"] - 1.0))
        group += 1
        if pagoda:
            pc = boxes[0]
            solids.append(make_box(pc[0], pc[1], max(pc[2], pc[3]) * 0.8, max(pc[2], pc[3]) * 0.8, pc[4],
                                   h=round(min(9.0, max(5.5, h_m / 5.0)), 2), style=SOL_PAGODA))
            continue
        if style == S_TEMPLE:
            for pc in boxes:
                solids.append(make_box(*pc, h=round(min(5.0, max(2.4, h_m / 5.0)), 2), style=SOL_TEMPLE))
            continue
        floors = height_to_floors(h_m)
        if floors is None and cap is None:
            hgt = min(TOWER_MAX, 8.0 + (h_m - TOWER_M) / 12.0)
            for pc in boxes:
                solids.append(make_box(*pc, h=round(hgt, 2), style=SOL_TOWER))
            continue
        if floors is None:
            floors = MAX_FLOORS
        if cap is not None:
            floors = max(1, min(floors, cap))
        for pc in boxes:
            cx, cz, hx, hz, a = pc
            # Inset outer walls a little: neighbours don't share faces.
            hx2, hz2 = max(0.3, hx - 0.05), max(0.3, hz - 0.05)
            cs = geom.box_corners(cx, cz, hx2, hz2, a)
            if max(q[0] for q in cs) < 0.2 or max(q[1] for q in cs) < 0.2 or min(q[0] for q in cs) > W - 0.2 or min(q[1] for q in cs) > H - 0.2:
                continue
            buildings.append(make_box(cx, cz, hx2, hz2, a, floors=floors, style=style, group=group))

    # Overlaps between different buildings: drop the smaller duplicate.
    buildings.sort(key=lambda b: -(b["hx"] * b["hz"]))
    kept = []
    for b in buildings:
        dup = False
        for o in bindex.near((b["cx"], b["cz"]), max(b["hx"], b["hz"])):
            if o["group"] == b["group"]:
                continue
            if _overlap_share(b, o) > 0.45:
                dup = True
                break
        if not dup:
            bindex.add(b)
            kept.append(b)
    buildings = kept
    for s in solids:
        bindex.add(dict(s, floors=0, group=-1))

    # Gates that span a street turn to follow it.
    for lm, cfg in zip(landmarks, d.get("landmarks", [])):
        if not cfg.get("align_road"):
            continue
        best = None
        for rec in road_recs:
            pts = rec["pts"]
            for i in range(len(pts) - 1):
                a, b = pts[i], pts[i + 1]
                ab = (b[0] - a[0], b[1] - a[1])
                ll = ab[0] ** 2 + ab[1] ** 2
                if ll < 1e-9:
                    continue
                t = max(0.0, min(1.0, ((lm["x"] - a[0]) * ab[0] + (lm["z"] - a[1]) * ab[1]) / ll))
                dd = math.hypot(a[0] + ab[0] * t - lm["x"], a[1] + ab[1] * t - lm["z"])
                if abs(math.cos(math.atan2(ab[1], ab[0]) - lm["rot"])) < math.cos(math.pi / 4):
                    continue
                if best is None or dd < best[0]:
                    best = (dd, math.atan2(ab[1], ab[0]))
        if best is not None and best[0] < 6:
            ang = best[1]
            # Keep the configured general direction (a road runs both ways).
            want = lm["rot"]
            if math.cos(ang - want) < 0:
                ang += math.pi
            lm["rot"] = r3(math.atan2(math.sin(ang), math.cos(ang)))

    # --- Markings ----------------------------------------------------------------
    markings = []
    junction = {}
    for nid, lst in way_nodes.items():
        recs = {id(r) for r, _ in lst}
        through = any(0 < i < len(r["nodes"]) - 1 for r, i in lst)
        if len(recs) >= 2 or (len(recs) == 1 and len(lst) >= 2) or (len(recs) >= 2 and through):
            if len(lst) >= 2 and (len(recs) >= 2):
                rec, i = lst[0]
                p = rec["pts"][i] if i < len(rec["pts"]) else None
                if p is not None:
                    junction[nid] = (p, max(r["w"] for r, _ in lst) / 2 + 0.4)
    junction_pts = list(junction.values())

    def near_junction(p, extra=0.0):
        for q, r in junction_pts:
            if abs(p[0] - q[0]) < r + extra and abs(p[1] - q[1]) < r + extra and math.hypot(p[0] - q[0], p[1] - q[1]) < r + extra:
                return True
        return False

    for rec in road_recs:
        if rec["cls"] > R_TERTIARY or rec["w"] < 2.8:
            continue
        pts = rec["pts"]
        yellow = rec["cls"] == R_MAJOR and not rec["oneway"]
        dash, gap = (1.4, 1.0) if rec["cls"] >= R_TERTIARY else (2.0, 1.2)
        lines = []
        if not rec["oneway"]:
            lines.append((0.0, 1 if yellow else 0, rec["cls"] <= R_SECONDARY))
        if rec["w"] >= 6.0:
            for off in (-rec["w"] / 4, rec["w"] / 4):
                lines.append((off, 0, False))
        for off, kind, solid in lines:
            total = sum(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]) for i in range(len(pts) - 1))
            s = 0.6
            step = (dash + gap) if not solid else dash
            ln = dash if not solid else dash
            while s + ln < total:
                p, ang = _along(pts, s + ln / 2)
                s += step
                q = (p[0] - math.sin(ang) * off, p[1] + math.cos(ang) * off)
                if not inside(q, 2) or near_junction(q, 0.6) or in_water(q) and not rec["bridge"]:
                    continue
                markings.append([r2(q[0]), r2(q[1]), r2(ln / 2), 0.05, r3(ang), kind])
    # Zebra crossings at OSM crossing nodes.
    for n in nodes:
        t = n.get("tags", {})
        if t.get("highway") != "crossing" and not (t.get("highway") == "traffic_signals" and t.get("crossing")):
            continue
        if t.get("crossing") in ("unmarked", "no") or t.get("crossing:markings") == "no":
            continue
        refs = way_nodes.get(n["id"], [])
        if not refs:
            continue
        rec, i = max(refs, key=lambda ri: ri[0]["w"])
        if rec["cls"] == R_PEDESTRIAN:
            continue
        p = proj(n["lat"], n["lon"])
        if not inside(p, 1):
            continue
        pts = rec["pts"]
        a = pts[max(0, i - 1)] if i > 0 else pts[i]
        b = pts[min(len(pts) - 1, i + 1)]
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        _zebra(markings, p, ang, rec["w"], depth=1.6)

    # Shibuya-style scramble: diagonal crossings over the whole junction.
    for lm in landmarks:
        if lm["type"] != "scramble":
            continue
        c = (lm["x"], lm["z"])
        best = {}
        for rec in road_recs:
            pts = rec["pts"]
            for i in range(len(pts) - 1):
                m = ((pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2)
                if math.hypot(m[0] - c[0], m[1] - c[1]) < 14:
                    ang = math.atan2(pts[i + 1][1] - pts[i][1], pts[i + 1][0] - pts[i][0]) % (math.pi / 2)
                    k = round(ang / (math.pi / 36))
                    best[k] = best.get(k, 0) + math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
        base = (max(best, key=best.get) * math.pi / 36) if best else 0.0
        lm["rot"] = r3(base)
        for diag in (base + math.pi / 4, base - math.pi / 4):
            # Walking direction `diag`: stripes across it, 15 units long.
            ux, uz = math.cos(diag), math.sin(diag)
            s = -7.5
            while s <= 7.5:
                q = (c[0] + ux * s, c[1] + uz * s)
                if not (abs(s) < 1.0):
                    markings.append([r2(q[0]), r2(q[1]), 0.13, 1.5, r3(diag), 0])
                s += 0.5

    # --- Props -----------------------------------------------------------------------
    def blocked(p, grow=0.35):
        if not inside(p, -0.5) or in_water(p):
            return True
        if bindex.contains(p, grow) is not None:
            return True
        return False

    def on_any_road(p, margin=0.0):
        return grid_at(on_road, p)

    trees, lamps, poles, wires, vending, signs, signals = [], [], [], [], [], [], []
    for n in nodes:
        t = n.get("tags", {})
        if t.get("natural") == "tree":
            p = proj(n["lat"], n["lon"])
            if inside(p, 0) and not blocked(p, 0.4) and not on_any_road(p):
                trees.append([r2(p[0]), r2(p[1]), r2(0.8 + 0.5 * stable_rand(n["id"], "t"))])
    # Parks: a jittered grid of trees.
    gx = 0.0
    while gx < W:
        gz = 0.0
        while gz < H:
            p = (gx + rng.uniform(0.4, 2.6), gz + rng.uniform(0.4, 2.6))
            if in_green(p) and not blocked(p, 0.6) and not on_any_road(p) and rng.random() < 0.72:
                trees.append([r2(p[0]), r2(p[1]), r2(rng.uniform(0.75, 1.35))])
            gz += 3.2
        gx += 3.2
    # Along streets: lamps, avenue trees, utility poles + wires, vending machines.
    for rec in road_recs:
        pts = rec["pts"]
        cls = rec["cls"]
        hw = rec["w"] / 2
        total = sum(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]) for i in range(len(pts) - 1))
        if total < 2:
            continue
        key = id(rec)
        if cls <= R_TERTIARY and not rec["bridge"]:
            s = rng.uniform(1, 5)
            side = 1
            while s < total:
                p, ang = _along(pts, s)
                q = (p[0] - math.sin(ang) * (hw + 0.45) * side, p[1] + math.cos(ang) * (hw + 0.45) * side)
                if inside(q, -1) and not blocked(q, 0.3) and not on_any_road(q) and not near_junction(q, 0.3):
                    lamps.append([r2(q[0]), r2(q[1]), r3(ang + (math.pi / 2 if side > 0 else -math.pi / 2))])
                s += 9.0
                side = -side
            if cls <= R_SECONDARY and rec["w"] >= 5.0:
                for sd in (-1, 1):
                    s = rng.uniform(2, 4)
                    while s < total:
                        p, ang = _along(pts, s)
                        q = (p[0] - math.sin(ang) * (hw + 0.9) * sd, p[1] + math.cos(ang) * (hw + 0.9) * sd)
                        if inside(q, -1) and not blocked(q, 0.6) and not on_any_road(q) and not near_junction(q, 1.2):
                            trees.append([r2(q[0]), r2(q[1]), r2(0.7 + 0.25 * rng.random())])
                        s += 4.5
        if cls in (R_MINOR, R_SERVICE, R_TERTIARY) and rec["w"] <= 4.0 and not rec["bridge"]:
            sd = 1 if stable_rand(key, "side") < 0.5 else -1
            s = rng.uniform(1, 4)
            prev = None
            while s < total:
                p, ang = _along(pts, s)
                q = (p[0] - math.sin(ang) * (hw + 0.22) * sd, p[1] + math.cos(ang) * (hw + 0.22) * sd)
                ok = inside(q, -0.5) and not blocked(q, 0.05) and not on_any_road(q)
                if ok:
                    poles.append([r2(q[0]), r2(q[1])])
                    if prev is not None and math.hypot(prev[0] - q[0], prev[1] - q[1]) < 11:
                        wires.append([r2(prev[0]), r2(prev[1]), r2(q[0]), r2(q[1])])
                    prev = q
                else:
                    prev = None
                s += 7.5
        if cls in (R_MINOR, R_SERVICE, R_TERTIARY, R_PEDESTRIAN):
            s = rng.uniform(2, 12)
            while s < total:
                p, ang = _along(pts, s)
                sd = 1 if rng.random() < 0.5 else -1
                q = (p[0] - math.sin(ang) * (hw + 0.2) * sd, p[1] + math.cos(ang) * (hw + 0.2) * sd)
                wall = bindex.contains(q, 0.45)
                if wall is not None and wall.get("floors", 0) > 0 and inside(q, -1) and not bindex.contains(q, 0.12) \
                        and not on_any_road(q) and not near_junction(q, 0.5):
                    face = ang + (math.pi / 2 if sd < 0 else -math.pi / 2)
                    n_m = 2 if rng.random() < 0.4 else 1
                    for k in range(n_m):
                        off = (k - (n_m - 1) / 2) * 0.32
                        vending.append([r2(q[0] + math.cos(ang) * off), r2(q[1] + math.sin(ang) * off), r3(face), rng.randrange(4)])
                s += rng.uniform(10, 22)
    # Signal heads at signalised junction nodes.
    for n in nodes:
        t = n.get("tags", {})
        if t.get("highway") != "traffic_signals":
            continue
        refs = way_nodes.get(n["id"], [])
        if not refs:
            continue
        rec, i = max(refs, key=lambda ri: ri[0]["w"])
        p = proj(n["lat"], n["lon"])
        pts = rec["pts"]
        a = pts[max(0, i - 1)]
        b = pts[min(len(pts) - 1, i + 1)]
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        q = (p[0] - math.sin(ang) * (rec["w"] / 2 + 0.35), p[1] + math.cos(ang) * (rec["w"] / 2 + 0.35))
        if inside(q, -1) and not blocked(q, 0.1):
            signals.append([r2(q[0]), r2(q[1]), r3(ang)])
    # Shop signs: blade signs on facades that face a street, and big screens
    # on tall buildings over main roads.
    neon = d.get("neon", 0.5)
    for b in buildings:
        if b["style"] not in (S_SHOP, S_OFFICE, S_STATION) or b["floors"] < 2:
            continue
        key = f"{b['cx']:.1f},{b['cz']:.1f}"
        if stable_rand(key, "sign") > neon * (1.0 if b["style"] == S_SHOP else 0.45):
            continue
        # Find the box side facing open street.
        best = None
        for side in range(4):
            ang = b["a"] + side * math.pi / 2
            nx, nz = math.cos(ang), math.sin(ang)
            half = b["hx"] if side % 2 == 0 else b["hz"]
            along = b["hz"] if side % 2 == 0 else b["hx"]
            probe = (b["cx"] + nx * (half + 1.2), b["cz"] + nz * (half + 1.2))
            if on_any_road(probe) and bindex.contains(probe, 0.0) is None:
                best = (ang, half, along)
                break
        if best is None:
            continue
        ang, half, along = best
        nx, nz = math.cos(ang), math.sin(ang)
        tx, tz = -nz, nx
        if along < 0.8:
            continue
        col = int(stable_rand(key, "col") * 6)
        # Blade sign near one corner, perpendicular to the wall.
        side = 1 if stable_rand(key, "c") < 0.5 else -1
        corner = along - 0.35
        px = b["cx"] + nx * (half + 0.22) + tx * corner * side
        pz = b["cz"] + nz * (half + 0.22) + tz * corner * side
        h = min(b["floors"] - 0.35, 0.45 + 0.55 * b["floors"])
        signs.append([r2(px), r2(pz), r3(ang), 0.38, r2(h), r2(b["floors"] - 0.15 - h / 2 - 0.05), col, 0])
        if b["floors"] >= 3 and along >= 2.2 and stable_rand(key, "screen") < neon * 0.55:
            w = min(along * 1.2, 4.5)
            sh = min(1.6, b["floors"] * 0.32)
            px = b["cx"] + nx * (half + 0.03)
            pz = b["cz"] + nz * (half + 0.03)
            signs.append([r2(px), r2(pz), r3(ang), r2(w), r2(sh), r2(b["floors"] - 0.3 - sh / 2), int(stable_rand(key, "sc") * 6), 1])

    # Parked cars in the open-air lots, in rows along each lot's long side.
    cars = []
    car_colors = 8
    for ring in parking_rings:
        if geom.area(ring) < 12.0:
            continue
        cx, cz, hx, hz, a = geom.min_area_rect(ring)
        if hx < hz:
            a += math.pi / 2
            hx, hz = hz, hx
        x = -hx + 1.0
        while x <= hx - 1.0:
            z = -hz + 1.0
            while z <= hz - 1.0:
                q = geom.from_local((x, z), cx, cz, a)
                if geom.point_in_ring(q, ring) and not blocked(q, 0.5) and not on_any_road(q) and rng.random() < 0.7:
                    cars.append([r2(q[0]), r2(q[1]), r3(a + math.pi / 2 + rng.uniform(-0.05, 0.05)), rng.randrange(car_colors)])
                z += 2.2
            x += 1.05
    # Torii at Shinto shrines: in front of the shrine, toward the nearest street.
    torii = []
    for e in ways + rels:
        t = e.get("tags", {})
        if t.get("amenity") != "place_of_worship" or t.get("religion") != "shinto":
            continue
        outs, _ = area_rings(e, proj)
        if not outs:
            continue
        ring = max(outs, key=geom.area)
        c = geom.centroid(ring)
        if not inside(c, -2):
            continue
        best = None
        for k in range(16):
            ang = k * math.pi / 8
            for dist in range(2, 16):
                p = (c[0] + math.cos(ang) * dist, c[1] + math.sin(ang) * dist)
                if on_any_road(p):
                    if best is None or dist < best[0]:
                        best = (dist, ang)
                    break
        if best is None:
            continue
        dist, ang = best
        for back in (1.5, 2.5, 3.5):
            p = (c[0] + math.cos(ang) * (dist - back), c[1] + math.sin(ang) * (dist - back))
            if not blocked(p, 0.9):
                torii.append([r2(p[0]), r2(p[1]), r3(ang), r2(1.0 if geom.area(ring) < 200 else 1.4)])
                break

    # --- Battle zones ----------------------------------------------------------------
    zg = geom.Grid(W, H, zonelib.RES)
    chunks = zonelib.Chunks(zg.a.shape)
    for rec in road_recs:
        major = rec["cls"] <= R_SECONDARY or rec["w"] >= 5.0
        chunks.add(rec["pts"], rec["w"] / 2, "major" if major else "minor")
    for pts in rail_lines:
        chunks.add(pts, RAIL_TRACK_W / 2, "major")
    # Lanes mapped as footways / paths: Tokyo backstreets and park paths
    # (drawn as paths, so zone borders along them are visible).
    for w in ways:
        t = w.get("tags", {})
        if t.get("highway") in ("footway", "path", "steps", "cycleway", "pedestrian", "track", "bridleway") \
                and t.get("area") != "yes" and t.get("tunnel") in (None, "no") \
                and t.get("footway") not in ("sidewalk", "crossing") and (parse_num(t.get("layer")) or 0) == 0:
            pts = way_points(w, proj)
            if len(pts) >= 2 and any(inside(p, 4) for p in pts):
                path_lines.append(pts)
                chunks.add(pts, 0.6, "path")
    chunks.finish()
    zg.a |= chunks.mask()
    sep = zg.a
    if platform_rings:
        zg.fill_rings(platform_rings)
    wmask = _resize(water_cov >= 0.5, sep.shape)
    sep |= wmask
    built = geom.Grid(W, H, zonelib.RES)
    for b in buildings + solids:
        built.fill_rings([geom.box_corners(b["cx"], b["cz"], b["hx"] + 0.3, b["hz"] + 0.3, b["a"])])
    railg = geom.Grid(W, H, zonelib.RES)
    for pts in rail_lines:
        railg.stroke(pts, RAIL_TRACK_W / 2 + 0.3)
    walkable = ~built.a & ~wmask & ~railg.a
    for rec in bridges:
        bg = geom.Grid(W, H, zonelib.RES)
        bg.stroke(rec["pts"], max(0.0, rec["w"] / 2 - 0.3))
        walkable |= bg.a & ~built.a
    green_mask = _resize(green_cov >= 0.5, sep.shape)
    bfoot = geom.Grid(W, H, zonelib.RES)
    for bx in buildings + solids:
        bfoot.fill_rings([geom.box_corners(bx["cx"], bx["cz"], bx["hx"], bx["hz"], bx["a"])])
    zone_list, cut_paths = zonelib.build_zones(W, H, sep, walkable, [tuple(n) for n in noplay], ZONE_MARGIN, ZONE_AREA, chunks,
                                    water=wmask, built=built.a, spacing=7.0, seed=d["id"], max_zones=72, log=lambda m: print(f"  {d['id']} {m}"), green=green_mask,
                                    footprint=bfoot.a, min_built=ZONE_MIN_BUILT,
                                    aspect=ZONE_ASPECT, aspect_max=ZONE_ASPECT_MAX)
    path_lines += cut_paths

    # --- Checks against the official maps -----------------------------------------
    # P: PLATEAU footprints, G: GSI base map buildings, B: our boxes. Within
    # one cell (0.5 units) of tolerance, as the sources differ by a metre.
    quality = {}
    gsi = sources.load_gsi(args_cache_tiles, d, proj, inside)
    braster = geom.Grid(W, H, 0.5)
    for bx in buildings + solids:
        braster.fill_rings([geom.box_corners(bx["cx"], bx["cz"], bx["hx"], bx["hz"], bx["a"])])
    B = braster.a
    P = sources.coverage(footprints, W, H, 0.5)
    if gsi:
        G = sources.coverage(gsi, W, H, 0.5)
        quality["source_recall"] = round(float((G & sources.dilate(P, 1)).sum()) / max(1, G.sum()), 3)
        quality["source_precision"] = round(float((P & sources.dilate(G, 1)).sum()) / max(1, P.sum()), 3)
        quality["box_vs_gsi_recall"] = round(float((G & sources.dilate(B, 1)).sum()) / max(1, G.sum()), 3)
    quality["box_recall"] = round(float((P & sources.dilate(B, 1)).sum()) / max(1, P.sum()), 3)
    quality["box_precision"] = round(float((B & sources.dilate(P, 1)).sum()) / max(1, B.sum()), 3)
    quality["built_share"] = round(float(B.mean()), 3)
    print(f"  {d['id']} quality {quality}")

    # Water names (for messages): the OSM feature each water polygon is in.
    named = []
    for e in ways + rels:
        t = e.get("tags", {})
        nm = t.get("name:en") or t.get("name:ja-Latn") or t.get("name:ja_rm")
        if not nm:
            continue
        if t.get("natural") == "water" or t.get("waterway") in ("riverbank", "river", "canal") or t.get("water"):
            outs, _ = area_rings(e, proj)
            pts = outs if outs else [way_points(e, proj)]
            named.append((nm, outs, pts))

    def water_name(outer):
        probe = geom.centroid(outer)
        if not geom.point_in_ring(probe, outer):
            probe = outer[0]
        best = (None, 1e9)
        for nm, outs, lines in named:
            if any(geom.point_in_ring(probe, r) for r in outs):
                return nm
            for line in lines:
                for q in line:
                    dd = math.hypot(q[0] - probe[0], q[1] - probe[1])
                    if dd < best[1]:
                        best = (nm, dd)
        return best[0] if best[1] < 40 else None

    # --- Output ----------------------------------------------------------------------
    def box_row(b):
        return [r2(b["cx"]), r2(b["cz"]), r2(b["hx"]), r2(b["hz"]), r3(b["a"])]

    data = {
        "format": FORMAT,
        "id": d["id"], "name": d["name"], "area": d["area"],
        "size": [r2(W), r2(H)],
        "meters_per_unit": METERS_PER_UNIT,
        "center_latlon": [d["lat"], d["lon"]],
        "attribution": "Map data (c) OpenStreetMap contributors, ODbL; buildings: Project PLATEAU (MLIT), CC BY 4.0; checked against GSI vector tiles",
        "buildings": [box_row(b) + [b["floors"], b["style"], b["group"]] for b in buildings],
        "solids": [box_row(s) + [r2(s["h"]), s["style"]] for s in solids],
        "decks": [box_row(k) + [r2(k["y0"]), r2(k["y1"]), k["kind"]] for k in decks],
        "roads": [[r["cls"], r2(r["w"]), 1 if r["bridge"] else 0] + [v for p in geom.rdp(r["pts"], 0.12) for v in (r2(p[0]), r2(p[1]))] for r in road_recs],
        "paths": [[v for p in geom.rdp(pts, 0.12) for v in (r2(p[0]), r2(p[1]))] for pts in path_lines],
        "rail": [[RAIL_TRACK_W] + [v for p in geom.rdp(pts, 0.12) for v in (r2(p[0]), r2(p[1]))] for pts in rail_lines],
        "platforms": tris_of([(geom.rdp_ring(geom.dedupe(r), 0.1), []) for r in platform_rings if len(r) >= 3]),
        "crossings": [[r2(p[0]), r2(p[1]), 1.8] for p in (proj(n["lat"], n["lon"]) for n in nodes if n.get("tags", {}).get("railway") == "level_crossing") if inside(p, 2)],
        "water": [{"rings": [[v for p in r for v in (r2(p[0]), r2(p[1]))] for r in [outer] + holes],
                   "tris": tris_of([(outer, holes)]), "name": water_name(outer) or ""} for outer, holes in water_polys],
        "zones": [[v for p in z["ring"] for v in (r2(p[0]), r2(p[1]))] for z in zone_list],
        "land": tris_of(land_polys),
        "green": tris_of(green_polys, keep_holes=False),
        "parking": tris_of(parking_polys, keep_holes=False),
        "markings": markings,
        "props": {
            "tree": trees, "lamp": lamps, "pole": poles, "wire": wires,
            "vending": vending, "sign": signs, "signal": signals, "torii": torii, "car": cars,
        },
        "landmarks": landmarks,
        "noplay": noplay,
        "quality": quality,
        "far": [dict(f, dir=[r3(v) for v in proj.offset(math.sin(math.radians(f["bearing_deg"])), -math.cos(math.radians(f["bearing_deg"])))])
                for f in d.get("far", [])],
        "north_deg": r2(math.degrees(turn)),
    }
    path = os.path.join(out_dir, d["id"] + ".json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
    kb = os.path.getsize(path) / 1024
    print(f"{d['id']}: turned {math.degrees(turn):+.1f} deg, {W:.0f} units, {len(buildings)} building boxes ({stats['plateau']} PLATEAU buildings, {stats['measured']} measured, {stats['osm']} OSM-only), "
          f"{len(solids)} solids, {len(decks)} deck boxes, {len(road_recs)} roads, {len(rail_lines)} rail, "
          f"{len(water_polys)} water, {len(zone_list)} zones, {len(trees)} trees, {len(signs)} signs, {len(markings)} markings -> {kb:.0f} KB")
    return {"id": d["id"], "name": d["name"], "area": d["area"], "lat": d["lat"], "lon": d["lon"],
            "size": [r2(W), r2(H)]}


def _resize(a, shape):
    """Crop / zero-pad a boolean grid to `shape`."""
    out = np.zeros(shape, dtype=bool)
    nz = min(shape[0], a.shape[0])
    nx = min(shape[1], a.shape[1])
    out[:nz, :nx] = a[:nz, :nx]
    return out


def _zebra(markings, p, road_ang, width, depth=1.6):
    """Stripes across a road of `width` at p (stripes run along the road)."""
    nx, nz = -math.sin(road_ang), math.cos(road_ang)
    k = -width / 2 + 0.3
    while k <= width / 2 - 0.3:
        q = (p[0] + nx * k, p[1] + nz * k)
        markings.append([r2(q[0]), r2(q[1]), r2(depth / 2), 0.11, r3(road_ang), 0])
        k += 0.48


def _along(pts, s):
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        ln = math.hypot(b[0] - a[0], b[1] - a[1])
        if s <= ln or i == len(pts) - 2:
            t = 0.0 if ln < 1e-9 else min(1.0, s / ln)
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t), math.atan2(b[1] - a[1], b[0] - a[0])
        s -= ln
    return pts[-1], 0.0


def _overlap_share(a, b):
    """Approximate share of the smaller box covered by the other (sampled)."""
    small, big = (a, b) if a["hx"] * a["hz"] <= b["hx"] * b["hz"] else (b, a)
    n = 0
    hit = 0
    for i in range(5):
        for j in range(5):
            lx = (i / 4 - 0.5) * 2 * small["hx"] * 0.9
            lz = (j / 4 - 0.5) * 2 * small["hz"] * 0.9
            p = geom.from_local((lx, lz), small["cx"], small["cz"], small["a"])
            q = geom.to_local(p, big["cx"], big["cz"], big["a"])
            n += 1
            if abs(q[0]) <= big["hx"] and abs(q[1]) <= big["hz"]:
                hit += 1
    return hit / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.path.join("build", "osm_cache"))
    ap.add_argument("--out", default=os.path.join("common", "map", "tokyo"))
    ap.add_argument("--only", default="")
    ap.add_argument("--tiles", default=os.path.join("build", "tile_cache"))
    args = ap.parse_args()
    global args_cache_tiles
    args_cache_tiles = args.tiles
    os.makedirs(args.out, exist_ok=True)
    only = {s for s in args.only.split(",") if s}
    index_path = os.path.join(args.out, "index.json")
    index = {}
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as f:
            for e in json.load(f).get("districts", []):
                index[e["id"]] = e
    for d in DISTRICTS:
        if only and d["id"] not in only:
            continue
        src = os.path.join(args.cache, d["id"] + ".json")
        if not os.path.exists(src):
            print(f"{d['id']}: no OSM download (run fetch_osm.py)")
            continue
        with open(src, encoding="utf-8") as f:
            osm = json.load(f)
        index[d["id"]] = build(d, osm, args.out)
    order = [d["id"] for d in DISTRICTS if d["id"] in index]
    with open(index_path, "w", encoding="utf-8") as f:
        json.dump({"format": FORMAT, "meters_per_unit": METERS_PER_UNIT,
                   "attribution": "Map data (c) OpenStreetMap contributors, ODbL; buildings: Project PLATEAU (MLIT), CC BY 4.0",
                   "districts": [index[i] for i in order]}, f, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
