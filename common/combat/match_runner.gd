class_name MatchRunner
extends RefCounted
## Shared deterministic match logic used by both the local client and the
## headless server: squad placement, turn resolution, and winner detection.
## This is the single source of truth for the "server-authoritative" turn math.

const DEFAULT_SEED := 12345
## Result code for a drawn match (live matches that hit the turn cap even).
const DRAW := 2


## Builds a fresh MatchState on the city map (MapData) and places both
## squads on their spawn hexes facing the map center. Team 0 starts on the
## bottom half, team 1 on the top half.
static func build_match(
	player_data: Array[UnitData],
	enemy_data: Array[UnitData],
	seed: int = DEFAULT_SEED
) -> MatchState:
	var ms := MatchState.new(seed)
	var map := MapData.city()
	ms.tiles = map.tiles
	ms.buildings = map.buildings
	ms.cover = map.cover
	var squads := [player_data, enemy_data]
	for team in 2:
		var states: Array[UnitState] = []
		var data: Array = squads[team]
		for i in data.size():
			var hex: Vector2i = map.spawns[team][i % map.spawns[team].size()]
			states.append(UnitState.new(data[i], team, hex, map.facing_toward_center(hex)))
		ms.setup_team(team, states)
	return ms


## Resolves a full 6-tick turn deterministically.
static func resolve_turn(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan) -> Array[CombatEvent]:
	var engine := TickEngine.new()
	return engine.resolve(ms, plan0, plan1)


## Returns the winning team (0 or 1), or -1 while the match is ongoing.
static func winner(ms: MatchState) -> int:
	if team_all_bailed(ms, 0):
		return 1
	if team_all_bailed(ms, 1):
		return 0
	return -1


## Winner when a live match reaches its turn cap: more units standing, then
## more remaining Trion (as a share of the squad's total), else DRAW.
static func tiebreak_winner(ms: MatchState) -> int:
	var alive := [0, 0]
	var share := [0.0, 0.0]
	for team in 2:
		var hp := 0
		var max_hp := 0
		for u in ms.teams[team]:
			max_hp += u.unit_data.base_trion_hp
			if not u.is_bailed:
				alive[team] += 1
				hp += u.trion_hp
		share[team] = float(hp) / maxf(1.0, max_hp)
	if alive[0] != alive[1]:
		return 0 if alive[0] > alive[1] else 1
	if absf(share[0] - share[1]) > 0.0001:
		return 0 if share[0] > share[1] else 1
	return DRAW


static func team_all_bailed(ms: MatchState, team: int) -> bool:
	for u in ms.teams[team]:
		if not u.is_bailed:
			return false
	return true


## Defensive fallback plan per GDD 3.1: "Stand Ground + Set Main Shield".
static func build_fallback_plan(units: Array[UnitData]) -> TurnPlan:
	var plan := TurnPlan.new(units)
	var shield := TriggerLibrary.get_card("Shield")
	if shield == null:
		return plan
	for i in units.size():
		for tick in TurnPlan.TICKS_PER_TURN:
			plan.assign(i, tick, TurnPlan.MAIN_SLOT, shield)
	return plan
