class_name TokyoDistrict
extends RefCounted
## One district of Tokyo (common/map/tokyo/<id>.json, built from
## OpenStreetMap by tools/tokyo/build_districts.py): the city boxes the rules
## use, plus everything the renderer draws (ground polygons, roads, rail,
## markings, street furniture, landmarks).
##
## World space: X east, Z south, in game units (the build's meters_per_unit
## real metres each), origin at the district's north-west corner.

## Building styles (palettes / facades; see TokyoCity).
enum Style { HOUSE, APARTMENT, OFFICE, SHOP, TEMPLE, STATION, TOWER, SCHOOL }
## Solid styles.
enum SolidStyle { PILLAR, TOWER, TEMPLE, GATE_POST, PAGODA }
## Deck kinds.
enum DeckKind { RAIL, ROAD, GATE_ROOF, SIGN }
## Road classes.
enum RoadClass { MAJOR, SECONDARY, TERTIARY, MINOR, SERVICE, PEDESTRIAN }

const INDEX_CELL := 8.0

var id := ""
var display_name := ""
var area_name := ""
var size := Vector2.ZERO
var meters_per_unit := 2.5
var attribution := ""
## How well the build matches the official maps (see build_districts.py):
## box_recall / box_precision against PLATEAU footprints, source_recall /
## source_precision of PLATEAU against the GSI base map.
var quality: Dictionary = {}

var buildings: Array = []     # CityBox BUILDING
var solids: Array = []        # CityBox SOLID
var decks: Array = []         # CityBox DECK
var roads: Array = []         # {cls, w, bridge, pts: PackedVector2Array}
var rail: Array = []          # {w, pts}
var paths: Array[PackedVector2Array] = []   # footpaths (drawn; zone borders may follow them)
var platforms := PackedFloat32Array()
var crossings: Array = []     # Vector3(x, z, r)
var water: Array = []         # {rings: Array[PackedVector2Array], tris: PackedFloat32Array, name: String}
var water_tris := PackedFloat32Array()
var land := PackedFloat32Array()
var green := PackedFloat32Array()
var parking := PackedFloat32Array()
var markings: Array = []      # [cx, cz, hx, hz, a, kind]
var props: Dictionary = {}
var landmarks: Array = []     # {type, pos: Vector2, rot}
var noplay: Array = []        # Vector3(x, z, r)
## Battle zones: play areas following the streets (outer rings, CCW).
var zones: Array[PackedVector2Array] = []
var far: Array = []

var _cells := {}              # Vector2i -> [ [kind, index], ... ]


static func load_file(path: String) -> TokyoDistrict:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("Tokyo district data missing: %s" % path)
		return null
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		push_error("Tokyo district data unreadable: %s" % path)
		return null
	var d := TokyoDistrict.new()
	d._parse(data)
	return d


func _parse(data: Dictionary) -> void:
	id = str(data.get("id", ""))
	display_name = str(data.get("name", id))
	area_name = str(data.get("area", ""))
	var sz: Array = data.get("size", [0, 0])
	size = Vector2(float(sz[0]), float(sz[1]))
	meters_per_unit = float(data.get("meters_per_unit", 2.5))
	attribution = str(data.get("attribution", ""))
	quality = data.get("quality", {})
	for row in data.get("buildings", []):
		buildings.append(CityBox.make(Vector2(row[0], row[1]), Vector2(row[2], row[3]), float(row[4]),
			CityBox.Kind.BUILDING, int(row[5]), 0.0, -1.0, int(row[6]), int(row[7])))
	for row in data.get("solids", []):
		solids.append(CityBox.make(Vector2(row[0], row[1]), Vector2(row[2], row[3]), float(row[4]),
			CityBox.Kind.SOLID, 0, 0.0, float(row[5]), int(row[6])))
	for row in data.get("decks", []):
		decks.append(CityBox.make(Vector2(row[0], row[1]), Vector2(row[2], row[3]), float(row[4]),
			CityBox.Kind.DECK, 0, float(row[5]), float(row[6]), int(row[7])))
	for row in data.get("roads", []):
		roads.append({ "cls": int(row[0]), "w": float(row[1]), "bridge": int(row[2]) == 1, "pts": _pts(row, 3) })
	for row in data.get("paths", []):
		paths.append(_pts(row, 0))
	for row in data.get("rail", []):
		rail.append({ "w": float(row[0]), "pts": _pts(row, 1) })
	platforms = PackedFloat32Array(data.get("platforms", []))
	for c in data.get("crossings", []):
		crossings.append(Vector3(c[0], c[1], c[2]))
	for w in data.get("water", []):
		var rings: Array[PackedVector2Array] = []
		for r in w.get("rings", []):
			rings.append(_pts(r, 0))
		var tris := PackedFloat32Array(w.get("tris", []))
		water.append({ "rings": rings, "tris": tris, "name": str(w.get("name", "")) })
		water_tris.append_array(tris)
	land = PackedFloat32Array(data.get("land", []))
	green = PackedFloat32Array(data.get("green", []))
	parking = PackedFloat32Array(data.get("parking", []))
	markings = data.get("markings", [])
	props = data.get("props", {})
	for lm in data.get("landmarks", []):
		landmarks.append({ "type": str(lm["type"]), "pos": Vector2(lm["x"], lm["z"]), "rot": float(lm.get("rot", 0.0)) })
	for z in data.get("noplay", []):
		noplay.append(Vector3(z[0], z[1], z[2]))
	far = data.get("far", [])
	for z in data.get("zones", []):
		zones.append(_pts(z, 0))
	_add_landmark_parts()
	_build_index()


static func _pts(row: Array, start: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(start, row.size() - 1, 2):
		out.append(Vector2(row[i], row[i + 1]))
	return out


## Gameplay pieces of the hand-modelled landmarks (the renderer adds the
## decoration around them). Local x of a landmark runs along its passage.
func _add_landmark_parts() -> void:
	for lm in landmarks:
		var p: Vector2 = lm["pos"]
		var a: float = lm["rot"]
		var along := Vector2.from_angle(a)
		var across := along.orthogonal()
		match lm["type"]:
			"kaminarimon":
				# Two halls flanking a central passage, under one roof.
				# (Box angle a + PI/2: local x runs across the passage.)
				for s in [-1.0, 1.0]:
					solids.append(CityBox.make(p + across * s * 1.58, Vector2(0.78, 1.4), a + PI / 2.0, CityBox.Kind.SOLID,
						0, 0.0, 2.0, SolidStyle.GATE_POST))
				decks.append(CityBox.make(p, Vector2(1.9, 3.0), a, CityBox.Kind.DECK, 0, 2.0, 3.1, DeckKind.GATE_ROOF))
			"kabukicho_gate":
				for s in [-1.0, 1.0]:
					solids.append(CityBox.make(p + across * s * 2.1, Vector2(0.16, 0.16), a, CityBox.Kind.SOLID,
						0, 0.0, 2.7, SolidStyle.GATE_POST))
				decks.append(CityBox.make(p + Vector2(0, 0), Vector2(0.12, 2.3), a, CityBox.Kind.DECK, 0, 2.05, 2.7, DeckKind.SIGN))


func _build_index() -> void:
	var lists := [buildings, solids, decks]
	for k in lists.size():
		var list: Array = lists[k]
		for i in list.size():
			var r: Rect2 = list[i]["aabb"]
			for cx in range(int(floor(r.position.x / INDEX_CELL)), int(floor(r.end.x / INDEX_CELL)) + 1):
				for cz in range(int(floor(r.position.y / INDEX_CELL)), int(floor(r.end.y / INDEX_CELL)) + 1):
					var key := Vector2i(cx, cz)
					if not _cells.has(key):
						_cells[key] = []
					_cells[key].append(Vector2i(k, i))


## Boxes whose footprint bounds meet `area`: [buildings, solids, decks], each
## in district order (so a section's layout is deterministic).
func boxes_in(area: Rect2) -> Array:
	var picked := [{}, {}, {}]
	for cx in range(int(floor(area.position.x / INDEX_CELL)), int(floor(area.end.x / INDEX_CELL)) + 1):
		for cz in range(int(floor(area.position.y / INDEX_CELL)), int(floor(area.end.y / INDEX_CELL)) + 1):
			for ki in _cells.get(Vector2i(cx, cz), []):
				var key: Vector2i = ki
				var list: Array = [buildings, solids, decks][key.x]
				if (list[key.y]["aabb"] as Rect2).intersects(area, true):
					picked[key.x][key.y] = true
	var out := [[], [], []]
	for k in 3:
		var idx: Array = picked[k].keys()
		idx.sort()
		var list: Array = [buildings, solids, decks][k]
		for i in idx:
			out[k].append(list[i])
	return out


## The water body at `p`: {name} ({} if `p` is not on water; name may be
## empty for unnamed ponds and canals).
func water_at(p: Vector2) -> Dictionary:
	for w in water:
		var rings: Array = w["rings"]
		if rings.is_empty() or not Geometry2D.is_point_in_polygon(p, rings[0]):
			continue
		var in_hole := false
		for k in range(1, rings.size()):
			in_hole = in_hole or Geometry2D.is_point_in_polygon(p, rings[k])
		if not in_hole:
			return { "name": w["name"] }
	return {}


## Whether `p` is inside a building or sealed solid (street-level clutter
## a play-area edge should not cut through), at least `depth` from its walls.
func built_at(p: Vector2, depth := 0.0) -> bool:
	for ki in _cells.get(Vector2i(int(floor(p.x / INDEX_CELL)), int(floor(p.y / INDEX_CELL))), []):
		var key: Vector2i = ki
		if key.x == 2:
			continue
		var b: Dictionary = (buildings if key.x == 0 else solids)[key.y]
		if CityBox.has_point(b, p, -depth):
			return true
	return false


## Blocked ground (water + railway, and everything outside `zone`) for a
## play area.
func blocked_mask(area: Rect2, margin: float, zone := PackedVector2Array()) -> BlockedMask:
	var grown := area.grow(margin + 1.0)
	var tris := PackedFloat32Array()
	for src in [water_tris, platforms]:
		var t: PackedFloat32Array = src
		for i in range(0, t.size() - 5, 6):
			var lo := Vector2(minf(t[i], minf(t[i + 2], t[i + 4])), minf(t[i + 1], minf(t[i + 3], t[i + 5])))
			var hi := Vector2(maxf(t[i], maxf(t[i + 2], t[i + 4])), maxf(t[i + 1], maxf(t[i + 3], t[i + 5])))
			if Rect2(lo, hi - lo).intersects(grown, true):
				tris.append_array(t.slice(i, i + 6))
	var strokes: Array = []
	for r in rail:
		if _polyline_near(r["pts"], grown, float(r["w"])):
			strokes.append({ "pts": r["pts"], "half": float(r["w"]) * 0.5 })
	var cuts: Array = []
	for r in roads:
		if r["bridge"] and _polyline_near(r["pts"], grown, float(r["w"])):
			cuts.append({ "pts": r["pts"], "half": float(r["w"]) * 0.5 })
	var discs: Array = []
	for c in crossings:
		if grown.grow(c.z).has_point(Vector2(c.x, c.y)):
			discs.append(c)
	return BlockedMask.new(area, tris, strokes, cuts, discs, margin, zone)


static func _polyline_near(pts: PackedVector2Array, area: Rect2, width: float) -> bool:
	if pts.is_empty():
		return false
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r.grow(width).intersects(area, true)
