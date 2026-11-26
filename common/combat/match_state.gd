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

var _geometry: CityGeometry
var _geometry_key := ""
var _rects: Array = []
var _rects_for_size := -1


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


## The enterable buildings (CityBox boxes). On hex maps they are rebuilt
## when the set of building hexes changes (or after invalidate_buildings()).
func building_rects() -> Array:
	if layout != null:
		return layout.buildings
	if _rects_for_size != buildings.size():
		_rects = []
		for r in BuildingRects.compute(buildings):
			_rects.append(CityBox.from_rect(BuildingRects.bounds(r), int(r["floors"])))
		_rects_for_size = buildings.size()
	return _rects


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
	var key := "%d|%d|%d" % [buildings.size(), tiles.size(), layout.get_instance_id() if layout != null else 0]
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
