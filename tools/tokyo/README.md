# Tokyo map pipeline

Builds the game's Tokyo districts (`common/map/tokyo/*.json`) from
OpenStreetMap. Pure Python 3 + numpy (no GIS libraries needed).

```bash
python -I tools/tokyo/fetch_osm.py                 # Overpass downloads -> build/osm_cache/ (gitignored)
python -I tools/tokyo/fetch_tiles.py               # PLATEAU + GSI vector tiles -> build/tile_cache/
python -I tools/tokyo/build_districts.py           # -> common/map/tokyo/<id>.json + index.json
python -I tools/tokyo/build_districts.py --only shibuya,ginza
python -I tools/tokyo/preview.py common/map/tokyo/shibuya.json out.png 4 [zone]   # top-down debug PNG (+ zone outlines)
```

Then look at it in the game's lighting:

```bash
godot --path . res://test/tokyo_shot.tscn -- out.png asakusa:6 40 52 0   # district:zone
```

## Adding or changing a district

Edit `districts.py` (centre, size, density / residential / neon mood,
landmarks), re-run both scripts, and run `res://test/tokyo_test.tscn`.

**Changing a shipped district changes the battlefield for everyone**: the
server and every client must load identical data, so bump
`NetProtocol.VERSION` and `MIN_SUPPORTED` (`common/net/protocol.gd`) whenever
existing district files change. Adding a new district only needs a version
bump if old clients may be sent a section in it (they would not have the
file), so in practice bump for every data release.

## What the build does

| OSM | Game |
| --- | --- |
| PLATEAU buildings (measured height) | footprints and heights of every building (OSM `building=*` only tags what they are, and stands in outside PLATEAU) |
| GSI base map buildings | the check: `quality` in each district's JSON (coverage / precision of PLATEAU and of our boxes) |
| footprints | oriented boxes: one per building, or a few for L-shapes / irregular lots (rasterised in the building's own frame, then split into rectangles) |
| `building:levels`, `height` | game floors 1–5; otherwise estimated from footprint, use, frontage to big streets, district density |
| 20+ storeys, temples, pagodas | sealed solids (nobody stands on them) |
| `railway=*` / `highway=motorway` with `bridge` or `layer>=1` | elevated decks with piers (walk under, block sight) |
| at-grade `railway=*`, platforms | fenced no-walk corridors (seen across); `railway=level_crossing` and road bridges cut through |
| `natural=water`, riverbanks, river / canal lines | water polygons sunk below the street (no-walk) |
| parks, grass, woods, shrine grounds | green polygons + trees |
| `highway=*` | roads (width from `width` / `lanes` / class) with curbs, lane lines; `highway=crossing` nodes become zebra crossings |
| `natural=tree`, `highway=traffic_signals`, shrines | trees, signal poles, torii |
| (procedural) | lamps, utility poles + wires on narrow streets, vending machines, neon signs on shop facades |
| streets, footways, rivers, railways | battle zones (`zones.py`): whole city blocks in near-rectangular areas the size and proportions of the original hex sheet (~2,730 unit², at most 1.6:1) with straightened outlines, 32 units clear of the data edge; small streets in at full width, avenues / railways a hard edge unless both sides are in |
| footways, paths | drawn as gravel / paving paths (and zone borders through big parks follow them) |

Scale: 1 game unit = 2.5 m (`METERS_PER_UNIT`). X runs east, Z south, origin
at each district's north-west corner.

## Licence

Buildings: Project PLATEAU (Ministry of Land, Infrastructure, Transport and
Tourism), CC BY 4.0, via Indigo Lab's vector tiles
(plateau-tokyo23ku-building-mvt-2020). Checked against GSI vector tiles
(Geospatial Information Authority of Japan). Credit both in the store
listing / about screen.


The district files are derived from OpenStreetMap data, © OpenStreetMap
contributors, available under the Open Database License (ODbL 1.0,
https://www.openstreetmap.org/copyright). The game shows the credit
"Map data © OpenStreetMap contributors (ODbL)" in every battle
(`levels/board/place_banner.gd`); keep it, and credit OpenStreetMap in the
store listing / about screen. The ODbL's share-alike applies to the derived
database (the JSON files), not to the game itself.
