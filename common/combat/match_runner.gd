class_name MatchRunner
extends RefCounted
## Shared deterministic match logic used by both the local client and the
## headless server: squad placement, turn resolution, and winner detection.
## This is the single source of truth for the "server-authoritative" turn math.

const DEFAULT_SEED := 12345


## Builds a fresh MatchState and places two squads on the standard starting
## positions. Player (team 0) along the -Z edge, enemy (team 1) along +Z.
static func build_match(
	player_data: Array[UnitData],
	enemy_data: Array[UnitData],
	seed: int = DEFAULT_SEED
) -> MatchState:
	var ms := MatchState.new(seed)
	var p0: Array[UnitState] = []
	var p1: Array[UnitState] = []
	for i in player_data.size():
		p0.append(UnitState.new(player_data[i], 0, Vector2i(-3 + i * 2, -2), 5))
	for i in enemy_data.size():
		p1.append(UnitState.new(enemy_data[i], 1, Vector2i(-3 + i * 2, 2), 2))
	ms.setup_team(0, p0)
	ms.setup_team(1, p1)
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
