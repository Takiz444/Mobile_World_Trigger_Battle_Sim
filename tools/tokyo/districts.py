"""The Tokyo districts the game is played in.

Each district is a square of real Tokyo, centred on (lat, lon) and `size_m`
metres a side. The build turns it into a game map at METERS_PER_UNIT metres
per game unit (a character is about 1.5 units tall, a floor 1 unit), and every
match is played on a random part of one district (see common/map/tokyo_map.gd).

To add a district: add an entry here, then run
    python -I tools/tokyo/fetch_osm.py   (downloads OpenStreetMap data)
    python -I tools/tokyo/build_districts.py
and commit common/map/tokyo/<id>.json.

Fields:
  id         file name and wire id (lowercase, stable: it is saved with matches)
  name       shown in game
  area       subtitle (the neighbourhood)
  lat, lon   centre
  size_m     side of the square in metres
  density    scales estimated building heights (1.0 = typical central Tokyo)
  residential  share of buildings styled as homes/apartments (0..1), sets mood
  neon       commercial street signs per facade (0..1)
  landmarks  [{type, lat, lon, rot, noplay_m, align_road}] hand-modelled
             landmarks (rot: degrees from east toward south, the direction
             of a gate's passage; align_road: turn it along the nearest
             street instead); a
             landmark with noplay_m keeps matches that far away from it (it is
             scenery only), and buildings under it are removed.
  far        [{type, bearing_deg, dist_u}] distant skyline landmarks drawn
             outside the district (bearing clockwise from north, distance in
             game units from the district centre, compressed from reality).
"""

METERS_PER_UNIT = 2.5

DISTRICTS = [
    {
        "id": "shibuya", "name": "Shibuya", "area": "Scramble Crossing",
        "lat": 35.65960, "lon": 139.70040, "size_m": 800,
        "density": 1.25, "residential": 0.15, "neon": 0.9,
        "landmarks": [{"type": "scramble", "lat": 35.659520, "lon": 139.700560, "rot": 0}],
    },
    {
        "id": "shinjuku", "name": "Shinjuku", "area": "Kabukicho",
        "lat": 35.69380, "lon": 139.70220, "size_m": 800,
        "density": 1.25, "residential": 0.1, "neon": 1.0,
        "landmarks": [{"type": "kabukicho_gate", "lat": 35.693370, "lon": 139.702460, "rot": 90, "align_road": True}],
    },
    {
        "id": "akihabara", "name": "Akihabara", "area": "Electric Town",
        "lat": 35.70000, "lon": 139.77100, "size_m": 800,
        "density": 1.15, "residential": 0.15, "neon": 0.9,
    },
    {
        "id": "ginza", "name": "Ginza", "area": "Yurakucho & 4-chome",
        "lat": 35.67250, "lon": 139.76300, "size_m": 800,
        "density": 1.2, "residential": 0.05, "neon": 0.6,
    },
    {
        "id": "asakusa", "name": "Asakusa", "area": "Kaminarimon & Sumida River",
        "lat": 35.71200, "lon": 139.79720, "size_m": 860,
        "density": 0.85, "residential": 0.45, "neon": 0.35,
        "landmarks": [
            {"type": "kaminarimon", "lat": 35.711060, "lon": 139.796380, "rot": 90},
        ],
        "far": [{"type": "skytree", "bearing_deg": 95, "dist_u": 175}],
    },
    {
        "id": "ikebukuro", "name": "Ikebukuro", "area": "Sunshine Street",
        "lat": 35.73020, "lon": 139.71480, "size_m": 800,
        "density": 1.1, "residential": 0.2, "neon": 0.8,
    },
    {
        "id": "ueno", "name": "Ueno", "area": "Ameyoko",
        "lat": 35.70980, "lon": 139.77380, "size_m": 800,
        "density": 1.0, "residential": 0.2, "neon": 0.6,
    },
    {
        "id": "roppongi", "name": "Roppongi", "area": "Roppongi Crossing",
        "lat": 35.66290, "lon": 139.73140, "size_m": 800,
        "density": 1.15, "residential": 0.25, "neon": 0.6,
    },
    {
        "id": "harajuku", "name": "Harajuku", "area": "Takeshita Street",
        "lat": 35.67080, "lon": 139.70480, "size_m": 800,
        "density": 0.9, "residential": 0.35, "neon": 0.45,
    },
    {
        "id": "nihonbashi", "name": "Nihonbashi", "area": "Nihonbashi Bridge",
        "lat": 35.68420, "lon": 139.77420, "size_m": 800,
        "density": 1.15, "residential": 0.1, "neon": 0.3,
    },
    {
        "id": "shimokitazawa", "name": "Shimokitazawa", "area": "Backstreets",
        "lat": 35.66150, "lon": 139.66800, "size_m": 800,
        "density": 0.7, "residential": 0.7, "neon": 0.3,
    },
    {
        "id": "shiba", "name": "Shiba", "area": "Tokyo Tower & Kamiyacho",
        "lat": 35.66050, "lon": 139.74900, "size_m": 960,
        "density": 0.95, "residential": 0.3, "neon": 0.25,
        "landmarks": [{"type": "tokyo_tower", "lat": 35.658580, "lon": 139.745440, "rot": 0, "noplay_m": 75}],
    },
]
