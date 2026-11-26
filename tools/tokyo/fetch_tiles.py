"""Downloads the official building data for every district as vector tiles:

  plateau  Project PLATEAU (MLIT) 3D city model of the 23 wards: every
           building footprint with its measured height. Tiles converted by
           Indigo Lab (plateau-tokyo23ku-building-mvt-2020), CC BY 4.0.
  gsi      Geospatial Information Authority of Japan vector tiles
           (optimal_bvmap): the national base map's building outlines, used to
           check the PLATEAU data and our simplification against.

    python -I tools/tokyo/fetch_tiles.py [--cache build/tile_cache] [--only shiba]
"""
import argparse
import math
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from districts import DISTRICTS  # noqa: E402
from fetch_osm import bbox  # noqa: E402

ZOOM = 16
SOURCES = {
    "plateau": "https://indigo-lab.github.io/plateau-tokyo23ku-building-mvt-2020/{z}/{x}/{y}.pbf",
    "gsi": "https://cyberjapandata.gsi.go.jp/xyz/optimal_bvmap-v1/{z}/{x}/{y}.pbf",
}
USER_AGENT = "trion-tactics-map-builder/1.0 (game map generator)"


def tile_xy(lat, lon, z=ZOOM):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.log(math.tan(math.radians(lat)) + 1.0 / math.cos(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def tiles_for(d):
    s, w, n, e = bbox(d)
    x0, y0 = tile_xy(n, w)
    x1, y1 = tile_xy(s, e)
    return [(x, y) for x in range(int(x0), int(x1) + 1) for y in range(int(y0), int(y1) + 1)]


def tile_path(cache, src, x, y, z=ZOOM):
    return os.path.join(cache, src, str(z), str(x), "%d.pbf" % y)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.path.join("build", "tile_cache"))
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    for d in DISTRICTS:
        if only and d["id"] not in only:
            continue
        tiles = tiles_for(d)
        got = 0
        for src, url in SOURCES.items():
            for x, y in tiles:
                path = tile_path(args.cache, src, x, y)
                if os.path.exists(path):
                    continue
                os.makedirs(os.path.dirname(path), exist_ok=True)
                req = urllib.request.Request(url.format(z=ZOOM, x=x, y=y), headers={"User-Agent": USER_AGENT})
                for attempt in range(4):
                    try:
                        with urllib.request.urlopen(req, timeout=60) as r:
                            data = r.read()
                        break
                    except urllib.error.HTTPError as e:
                        if e.code == 404:
                            data = b""
                            break
                        time.sleep(3 * (attempt + 1))
                    except Exception:  # noqa: BLE001
                        time.sleep(3 * (attempt + 1))
                else:
                    raise RuntimeError("failed: %s" % url.format(z=ZOOM, x=x, y=y))
                with open(path, "wb") as f:
                    f.write(data)
                got += 1
                time.sleep(0.3)
        print(f"{d['id']}: {len(tiles)} tiles per source, {got} downloaded", flush=True)


if __name__ == "__main__":
    main()
