"""Downloads OpenStreetMap data for every district (tools/tokyo/districts.py)
from the Overpass API, one JSON file per district.

    python -I tools/tokyo/fetch_osm.py [--cache build/osm_cache] [--only shibuya,ginza] [--force]

Data (c) OpenStreetMap contributors, available under the Open Database License
(ODbL): https://www.openstreetmap.org/copyright
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from districts import DISTRICTS  # noqa: E402

ENDPOINTS = [
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
USER_AGENT = "trion-tactics-map-builder/1.0 (game map generator)"

QUERY = """[out:json][timeout:600][maxsize:536870912];
(
  way["building"]({bb});
  relation["building"]({bb});
  way["highway"]({bb});
  way["railway"]({bb});
  way["waterway"]({bb});
  way["natural"~"^(water|wood|scrub|grassland)$"]({bb});
  relation["natural"~"^(water|wood)$"]({bb});
  way["water"]({bb});
  relation["water"]({bb});
  way["leisure"~"^(park|garden|playground|pitch|common)$"]({bb});
  relation["leisure"~"^(park|garden)$"]({bb});
  way["landuse"~"^(grass|forest|recreation_ground|religious|village_green|meadow|cemetery)$"]({bb});
  relation["landuse"~"^(forest|grass|religious|recreation_ground)$"]({bb});
  way["amenity"="place_of_worship"]({bb});
  way["amenity"="parking"]({bb});
  relation["amenity"="parking"]({bb});
  relation["amenity"="place_of_worship"]({bb});
  node["natural"="tree"]({bb});
  node["highway"~"^(crossing|traffic_signals)$"]({bb});
  node["railway"="level_crossing"]({bb});
);
out geom;
"""


def bbox(d, pad=1.45):
    # 45% margin: a district turned to its street grid still has data in its corners.
    half = d["size_m"] * 0.5 * pad
    dlat = half / 110574.0
    dlon = half / (111320.0 * math.cos(math.radians(d["lat"])))
    return (d["lat"] - dlat, d["lon"] - dlon, d["lat"] + dlat, d["lon"] + dlon)


def fetch(query):
    last = None
    for attempt in range(6):
        url = ENDPOINTS[attempt % len(ENDPOINTS)]
        data = urllib.parse.urlencode({"data": query}).encode()
        req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001 - retry any network failure
            last = e
            wait = 20 * (attempt + 1)
            print(f"  {url}: {e}; retrying in {wait}s", flush=True)
            time.sleep(wait)
    raise RuntimeError(f"Overpass failed: {last}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.path.join("build", "osm_cache"))
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    only = {s for s in args.only.split(",") if s}
    for d in DISTRICTS:
        if only and d["id"] not in only:
            continue
        out = os.path.join(args.cache, d["id"] + ".json")
        if os.path.exists(out) and not args.force:
            print(f"{d['id']}: cached")
            continue
        s, w, n, e = bbox(d)
        q = QUERY.replace("{bb}", f"{s:.6f},{w:.6f},{n:.6f},{e:.6f}")
        print(f"{d['id']}: fetching ...", flush=True)
        res = fetch(q)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(res, f)
        print(f"{d['id']}: {len(res.get('elements', []))} elements", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    main()
