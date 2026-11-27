class_name MatchState
extends RefCounted
## The whole runtime match: two squads, the city, Spider wires, and a seeded
## RNG so resolution is deterministic (replayable).
##
## The city is either a section of Tokyo (`layout`, see TokyoMap) or, for
## test arenas and the old map sheet, building heights per map hex
## (`tiles` / `buildings`), turned into the same boxes (BuildingRects).

const WIRE_RADIUS := 1.5

var teams: Array = []            # teams[team] -> Array[UnitState]
## Spider wires: [{pos: Vector2, team: int}], each a circle of WIRE_RADIUS.
var wires: Array = []
var buildings: Dictionary = {}   # hex maps: map hex (Vector2i) -> floors (1..4)
var tiles: Dictionary = {}       # hex maps: map hexes of the play area (bounds)
## Tokyo: the section's city (null on hex maps), and the section itself
## ({district, rect}; see TokyoMap).
var layout: CityLayout
var section: Dictionary = {}
var rng: RandomNumberGenerator
## Buildings brought down (Ibis): indices into all_building_rects() -> true.
## Gone for good: nobody walks, stands or is hidden there any more.
var destroyed: Dictionary = {}

var _geometry: CityGeometry
var _geometry_key := ""
var _rects: Array = []
var _rects_for_size := -1
var _standing: Array = []
var _standing_index := PackedInt32Array()   # standing list index -> all_building_rects() index
var _standing_key := ""
var _destroyed_rev := 0


func _init(seed: int = 0) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = seed
	teams = [[], []]


func setup_team(team: int, units: Array[UnitState]) -> void:
	teams[team] = units.duplicate()


func all_units() -> Array[UnitState]:
	var result: Array[UnitState] = []
	for squad in teams:
		for u in squad:
			result.append(u)
	return result


## Every enterable building of the city (CityBox boxes), standing or not.
## On hex maps they are rebuilt when the set of building hexes changes (or
## after invalidate_buildings()).
func all_building_rects() -> Array:
	if layout != null:
		return layout.buildings
	if _rects_for_size != buildings.size():
		_rects = []
		for r in BuildingRects.compute(buildings):
			_rects.append(CityBox.from_rect(BuildingRects.bounds(r), int(r["floors"])))
		_group_blocks(_rects)
		_rects_for_size = buildings.size()
	return _rects


## The enterable buildings still standing (what the rules and geometry use).
func building_rects() -> Array:
	var all := all_building_rects()
	if destroyed.is_empty():
		return all
	var key := "%d|%d|%d" % [all.size(), _rects_for_size, _destroyed_rev]
	if key != _standing_key:
		_standing = []
		_standing_index = PackedInt32Array()
		for i in all.size():
			if not destroyed.has(i):
				_standing.append(all[i])
				_standing_index.append(i)
		_standing_key = key
	return _standing


## The all_building_rects() index of building_rects()[i].
func building_id(i: int) -> int:
	if destroyed.is_empty():
		return i
	building_rects()
	return _standing_index[i] if i >= 0 and i < _standing_index.size() else -1


## Hex maps: the rects of one connected block of building hexes are one
## building (they share a "group"), like a Tokyo building split into boxes.
static func _group_blocks(rects: Array) -> void:
	var group := range(rects.size())
	var find := func(i: int) -> int:
		while group[i] != i:
			i = group[i]
		return i
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var a: Rect2 = (rects[i]["aabb"] as Rect2).grow(0.02)
			if a.intersects(rects[j]["aabb"]):
				group[find.call(j)] = find.call(i)
	for i in rects.size():
		rects[i]["group"] = find.call(i)


## Brings down building `id` (an all_building_rects() index) for good, with
## every other box of the same building (its "group"). Returns the
## indices that came down now.
func destroy_building(id: int) -> Array:
	var all := all_building_rects()
	if id < 0 or id >= all.size() or destroyed.has(id):
		return []
	var gone: Array = [id]
	var group := int(all[id].get("group", -1))
	if group >= 0:
		for i in all.size():
			if i != id and int(all[i].get("group", -1)) == group and not destroyed.has(i):
				gone.append(i)
	for i in gone:
		destroyed[i] = true
	_destroyed_rev += 1
	_geometry = null
	return gone


## The destroyed buildings' indices, ascending (for views and snapshots).
func destroyed_list() -> Array:
	var out: Array = destroyed.keys()
	out.sort()
	return out


## Replaces the destroyed set (from a view or snapshot).
func set_destroyed(ids: Array) -> void:
	var next := {}
	var count := all_building_rects().size()
	for v in ids:
		var id := int(v)
		if id >= 0 and id < count:
			next[id] = true
	if next.keys().size() == destroyed.size() and next.keys().all(func(k: int) -> bool: return destroyed.has(k)):
		return
	destroyed = next
	_destroyed_rev += 1
	_geometry = null


## Hex maps: the building hexes of the buildings still standing.
func standing_hexes() -> Dictionary:
	if destroyed.is_empty():
		return buildings
	var out := buildings.duplicate()
	var rects := BuildingRects.compute(buildings)
	for id in destroyed:
		if int(id) < rects.size():
			for hex in rects[int(id)]["hexes"]:
				out.erase(hex)
	return out


## Sealed solids and elevated decks (Tokyo only).
func solid_boxes() -> Array:
	return layout.solids if layout != null else []


func deck_boxes() -> Array:
	return layout.decks if layout != null else []


## Call after changing building heights in place (same set of hexes).
func invalidate_buildings() -> void:
	_rects_for_size = -1
	_geometry = null


## The play area in world units (X, Z): the section, or the map hexes' cells.
func bounds() -> Rect2:
	if layout != null:
		return layout.bounds
	if tiles.is_empty():
		return Rect2(-500, -500, 1000, 1000)
	var first := true
	var box := Rect2()
	for hex in tiles:
		var p3 := HexCoord.axial_to_world(hex, 1.0)
		var cell := Rect2(Vector2(p3.x, p3.z) - Vector2(1.0, HexCoord.SQRT3 / 2.0), Vector2(2.0, HexCoord.SQRT3))
		box = cell if first else box.merge(cell)
		first = false
	return box


## Continuous geometry of this match's city (walkability, routes).
func geometry() -> CityGeometry:
	var key := "%d|%d|%d|%d" % [buildings.size(), tiles.size(), layout.get_instance_id() if layout != null else 0, _destroyed_rev]
	if _geometry == null or _geometry_key != key:
		_geometry = CityGeometry.new(bounds(), building_rects(), solid_boxes(), deck_boxes(),
			layout.blocked if layout != null else null)
		_geometry_key = key
	return _geometry


## The living unit standing nearest `p` on `level` within `radius`, or null.
func unit_near(p: Vector2, level: int, radius: float, team: int = -1) -> UnitState:
	var best: UnitState = null
	var best_d := radius
	for u in all_units():
		if u.is_bailed or u.level != level or (team != -1 and u.team != team):
			continue
		var d := u.pos.distance_to(p)
		if d <= best_d:
			best_d = d
			best = u
	return best


## The Spider wire of `team` under a character at `p` / `level`, if any.
func on_team_wire(p: Vector2, level: int, team: int) -> bool:
	if level != 0:
		return false
	for w in wires:
		if int(w["team"]) == team and (w["pos"] as Vector2).distance_to(p) <= WIRE_RADIUS:
			return true
	return false
