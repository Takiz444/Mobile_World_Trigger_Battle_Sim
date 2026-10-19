class_name MatchState
extends RefCounted
## Holds the full runtime match: two squads, board cover, spider wires, and a
## seeded RNG so resolution is deterministic (replayable).

var teams: Array = []            # teams[team] -> Array[UnitState]
var wires: Dictionary = {}       # Vector2i -> true
var cover: Dictionary = {}       # Vector2i -> int (0 none, 1 half, 2 full)
var buildings: Dictionary = {}   # Vector2i -> int floors (1..4)
var tiles: Dictionary = {}       # Vector2i -> true (board extent; empty = unbounded)
var rng: RandomNumberGenerator


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


## First non-bailed unit at `hex` and `floor` (optionally filtered by team).
func get_unit_at(hex: Vector2i, floor: int = 0, team: int = -1) -> UnitState:
	for squad_index in teams.size():
		if team != -1 and squad_index != team:
			continue
		for u in teams[squad_index]:
			if not u.is_bailed and u.hex == hex and u.floor == floor:
				return u
	return null


## First non-bailed unit at `hex` regardless of floor (used for combat
## targeting, where ranged/melee acquire by hex rather than by elevation).
func get_unit_at_any_floor(hex: Vector2i, team: int = -1) -> UnitState:
	for squad_index in teams.size():
		if team != -1 and squad_index != team:
			continue
		for u in teams[squad_index]:
			if not u.is_bailed and u.hex == hex:
				return u
	return null


## Whether `hex` is on the board. An empty tile set means "no bounds" (used
## by small unit-test boards).
func has_tile(hex: Vector2i) -> bool:
	return tiles.is_empty() or tiles.has(hex)


## Number of elevated floors of the building at `hex` (0 = no building).
func building_floors(hex: Vector2i) -> int:
	return int(buildings.get(hex, 0))


## Whether a unit may stand at `floor` of `hex`. Floor 0 (ground) is only
## legal on open hexes; floors > 0 require a building tall enough.
func floor_legal(hex: Vector2i, floor: int) -> bool:
	if not has_tile(hex):
		return false
	if floor == 0:
		return building_floors(hex) == 0
	return building_floors(hex) >= floor
