class_name MatchState
extends RefCounted
## The whole runtime match: two squads, the city (building heights per map
## hex, from which the continuous geometry is built), Spider wires, and a
## seeded RNG so resolution is deterministic (replayable).

const WIRE_RADIUS := 1.5

var teams: Array = []            # teams[team] -> Array[UnitState]
## Spider wires: [{pos: Vector2, team: int}], each a circle of WIRE_RADIUS.
var wires: Array = []
var buildings: Dictionary = {}   # map hex (Vector2i) -> floors (1..4); rendering + geometry source
var tiles: Dictionary = {}       # map hexes of the play area (rendering + bounds)
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


## Building geometry (BuildingRects), cached; rebuilt when the set of
## building hexes changes (or after invalidate_buildings()).
func building_rects() -> Array:
	if _rects_for_size != buildings.size():
		_rects = BuildingRects.compute(buildings)
		_rects_for_size = buildings.size()
	return _rects


## Call after changing building heights in place (same set of hexes).
func invalidate_buildings() -> void:
	_rects_for_size = -1
	_geometry = null


## The play area in world units (X, Z): the map hexes' cells.
func bounds() -> Rect2:
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
	var key := "%d|%d" % [buildings.size(), tiles.size()]
	if _geometry == null or _geometry_key != key:
		_geometry = CityGeometry.new(bounds(), building_rects())
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
