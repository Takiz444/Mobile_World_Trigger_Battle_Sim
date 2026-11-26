class_name TokyoMap
extends RefCounted
## The battlefield is Tokyo: a set of real districts (common/map/tokyo/,
## built from OpenStreetMap by tools/tokyo/), and every match is fought in a
## battle zone of one of them: a "section".
##
##   { "district": "asakusa", "zone": 12 }
##
## Zones are irregular areas made of whole city blocks, so their borders run
## along street centrelines and riverbanks (see tools/tokyo/zones.py). The
## server picks the section from its own randomness and sends it to the
## clients (it is public; the match seed is not). The rest of the district
## is drawn around the zone, shaded out.
##
## Older section forms are still understood, so saved matches can finish:
##   { "district": "shibuya", "rect": Rect2i(x, z, w, h) }   (rectangle zones)
##   { "district": "sheet", "rect": Rect2i(col, row, w, h) } (the hex sheet)

const DATA_DIR := "res://common/map/tokyo/"
const SHEET := "sheet"
## Old rectangle sections: side limits and distance from the district edge.
const SECTION_MIN_SIDE := 28
const SECTION_MAX_SIDE := 86
const EDGE_MARGIN := 6
## A zone is played only if enough of it is open street, and most of that
## street is one connected area (the build checks this too).
const MIN_OPEN_SHARE := 0.27
const MIN_CONNECTED_SHARE := 0.72
const SECTION_ATTEMPTS := 16
const LAYOUT_CACHE := 12

## QA only (screenshots, local tests): when set, random sections come from
## this district. Never set by the game or the server.
static var only_district := ""

static var _index: Array = []
static var _districts := {}
static var _layouts := {}
static var _layout_order: Array = []


# --- Districts -----------------------------------------------------------------

## Every district: [{id, name, area, lat, lon, size}], in a fixed order.
static func districts() -> Array:
	if _index.is_empty():
		var text := FileAccess.get_file_as_string(DATA_DIR + "index.json")
		var data: Variant = JSON.parse_string(text) if not text.is_empty() else null
		if data is Dictionary:
			_index = data.get("districts", [])
		if _index.is_empty():
			push_error("Tokyo map index missing (%sindex.json)" % DATA_DIR)
	return _index


static func district_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for d in districts():
		out.append(str(d["id"]))
	return out


static func has_district(id: String) -> bool:
	return id in district_ids()


## The district's index entry ({} if unknown).
static func district_info(id: String) -> Dictionary:
	for d in districts():
		if str(d["id"]) == id:
			return d
	return {}


## Loaded district data (cached), or null.
static func district(id: String) -> TokyoDistrict:
	if not _districts.has(id):
		if not has_district(id):
			return null
		_districts[id] = TokyoDistrict.load_file(DATA_DIR + id + ".json")
	return _districts[id]


# --- Sections ------------------------------------------------------------------

## A random playable battle zone, chosen from `seed` alone (same seed, same
## section, on every machine).
static func random_section(seed: int) -> Dictionary:
	var ids := district_ids()
	if only_district != "" and only_district in ids:
		ids = PackedStringArray([only_district])
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed, "tokyo_zone"])
	var with_zones := PackedStringArray()
	for id in ids:
		var d := district(id)
		if d != null and not d.zones.is_empty():
			with_zones.append(id)
	if with_zones.is_empty():
		return { "district": SHEET, "rect": MapData.random_section(seed) }
	var first := with_zones[rng.randi_range(0, with_zones.size() - 1)]
	var fallback := {}
	for attempt in SECTION_ATTEMPTS:
		# Stay in the drawn district for most attempts, then try others.
		var id := first if attempt < SECTION_ATTEMPTS / 2 else with_zones[rng.randi_range(0, with_zones.size() - 1)]
		var s := { "district": id, "zone": rng.randi_range(0, district(id).zones.size() - 1) }
		if fallback.is_empty():
			fallback = s
		if playable(s):
			return s
	push_warning("no well-connected Tokyo zone for seed %d; using a rougher one" % seed)
	return fallback


static func zone_count(id: String) -> int:
	var d := district(id)
	return d.zones.size() if d != null else 0


## Whether `s` is a section a match may be played on (also used to check
## saved records and anything a client sends).
static func valid_section(s: Variant) -> bool:
	if not (s is Dictionary) or not s.has("district"):
		return false
	var id := str(s["district"])
	if s.has("zone"):
		return typeof(s["zone"]) == TYPE_INT and id != SHEET and int(s["zone"]) >= 0 and int(s["zone"]) < zone_count(id)
	if not (s.get("rect") is Rect2i):
		return false
	var r: Rect2i = s["rect"]
	if id == SHEET:
		return r == Rect2i() or MapData.valid_section(r)
	var info := district_info(id)
	if info.is_empty():
		return false
	var size: Array = info["size"]
	if r.size.x < SECTION_MIN_SIDE or r.size.y < SECTION_MIN_SIDE or r.size.x > SECTION_MAX_SIDE or r.size.y > SECTION_MAX_SIDE:
		return false
	if r.position.x < 0 or r.position.y < 0 or r.end.x > float(size[0]) or r.end.y > float(size[1]):
		return false
	var d := district(id)
	if d == null:
		return false
	var area := Rect2(r)
	for z in d.noplay:
		var c := Vector2(z.x, z.y)
		var nearest := Vector2(clampf(c.x, area.position.x, area.end.x), clampf(c.y, area.position.y, area.end.y))
		if nearest.distance_to(c) < z.z:
			return false
	return true


## The section's play area as a polygon (the zone, or a rectangle's corners).
static func section_polygon(s: Dictionary) -> PackedVector2Array:
	if s.has("zone"):
		var d := district(str(s["district"]))
		if d != null and int(s["zone"]) >= 0 and int(s["zone"]) < d.zones.size():
			return d.zones[int(s["zone"])]
		return PackedVector2Array()
	var r := Rect2(s.get("rect", Rect2i()))
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


## Enough open, connected street to play on.
static func playable(s: Dictionary) -> bool:
	var lay := layout(s)
	if lay == null:
		return false
	var geo := CityGeometry.new(lay.bounds, lay.buildings, lay.solids, lay.decks, lay.blocked)
	var b := lay.bounds
	var cells := {}
	var inside := 0
	var nx := int(b.size.x)
	var nz := int(b.size.y)
	for x in nx:
		for z in nz:
			var p := b.position + Vector2(x + 0.5, z + 0.5)
			if lay.blocked == null or lay.blocked.in_zone(p):
				inside += 1
			if geo.ground_ok(p):
				cells[Vector2i(x, z)] = p
	var open := cells.size()
	if open < MIN_OPEN_SHARE * inside:
		return false
	var seen := {}
	var best := 0
	for start in cells:
		if seen.has(start):
			continue
		var count := 0
		var queue: Array[Vector2i] = [start]
		seen[start] = true
		while not queue.is_empty():
			var c: Vector2i = queue.pop_back()
			count += 1
			for dv in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + dv
				if cells.has(n) and not seen.has(n) and geo.ground_clear(cells[c], cells[n]):
					seen[n] = true
					queue.append(n)
		best = maxi(best, count)
	return best >= MIN_CONNECTED_SHARE * open


## JSON form: ["asakusa", 12]. Older forms: ["shibuya", x, z, w, h],
## [col, row, w, h] or ["sheet", 0, 0, 0, 0] for the hex sheet.
static func section_to_json(s: Dictionary) -> Variant:
	if s.is_empty():
		return null
	if s.has("zone"):
		return [str(s["district"]), int(s["zone"])]
	var r: Rect2i = s["rect"]
	if str(s["district"]) == SHEET and r.has_area():
		return MapData.section_to_array(r)
	return [str(s["district"]), r.position.x, r.position.y, r.size.x, r.size.y]


## A section from its JSON form, or {} if it is malformed or not playable.
static func section_from(v: Variant) -> Dictionary:
	if v is Array and (v as Array).size() == 2 and v[0] is String:
		if typeof(v[1]) != TYPE_INT and typeof(v[1]) != TYPE_FLOAT:
			return {}
		if typeof(v[1]) == TYPE_FLOAT and float(v[1]) != floorf(float(v[1])):
			return {}
		var z := { "district": str(v[0]), "zone": int(v[1]) }
		return z if valid_section(z) else {}
	if v is Array and (v as Array).size() == 5 and v[0] is String:
		for i in range(1, 5):
			if typeof(v[i]) != TYPE_INT and typeof(v[i]) != TYPE_FLOAT:
				return {}
		var s := { "district": str(v[0]), "rect": Rect2i(int(v[1]), int(v[2]), int(v[3]), int(v[4])) }
		return s if valid_section(s) else {}
	if v is Array and (v as Array).size() == 4:
		var r := MapData.section_from(v)
		return { "district": SHEET, "rect": r } if r.has_area() else {}
	return {}


static func is_sheet(s: Dictionary) -> bool:
	return str(s.get("district", "")) == SHEET


## Display name of a section's place: "Shibuya — Scramble Crossing".
static func place_name(s: Dictionary) -> String:
	if s.is_empty() or is_sheet(s):
		return "Training Sheet"
	var info := district_info(str(s["district"]))
	if info.is_empty():
		return str(s["district"])
	return "%s — %s" % [info.get("name", ""), info.get("area", "")]


# --- Layouts ---------------------------------------------------------------------

## The city boxes and no-walk zones of a section (cached; shared read-only).
static func layout(s: Dictionary) -> CityLayout:
	if is_sheet(s) or not s.has("district"):
		return null
	var key := str(section_to_json(s))
	if _layouts.has(key):
		return _layouts[key]
	var d := district(str(s["district"]))
	var zone := section_polygon(s)
	if d == null or zone.size() < 3:
		return null
	var lay := CityLayout.new()
	lay.district = d
	lay.section = s.duplicate()
	lay.zone = zone
	var box := Rect2(zone[0], Vector2.ZERO)
	for p in zone:
		box = box.expand(p)
	lay.bounds = box
	var picked := d.boxes_in(lay.bounds.grow(0.5))
	lay.buildings = picked[0]
	lay.solids = picked[1]
	lay.decks = picked[2]
	lay.blocked = d.blocked_mask(lay.bounds, CityGeometry.UNIT_RADIUS, zone)
	_layouts[key] = lay
	_layout_order.append(key)
	while _layout_order.size() > LAYOUT_CACHE:
		_layouts.erase(_layout_order.pop_front())
	return lay
