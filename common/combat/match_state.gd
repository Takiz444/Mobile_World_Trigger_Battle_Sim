class_name MatchState
extends RefCounted
## Holds the full runtime match: two squads, board cover, spider wires, and a
## seeded RNG so resolution is deterministic (replayable).

var teams: Array = []            # teams[team] -> Array[UnitState]
var wires: Dictionary = {}       # Vector2i -> true
var cover: Dictionary = {}       # Vector2i -> int (0 none, 1 half, 2 full)
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


## First non-bailed unit at `hex` (optionally filtered by team).
func get_unit_at(hex: Vector2i, team: int = -1) -> UnitState:
	for squad_index in teams.size():
		if team != -1 and squad_index != team:
			continue
		for u in teams[squad_index]:
			if not u.is_bailed and u.hex == hex:
				return u
	return null
