class_name MatchRunner
extends RefCounted
## Shared deterministic match logic used by both the local client and the
## headless server: squad placement, turn resolution, and winner detection.
## This is the single source of truth for the "server-authoritative" turn math.

const DEFAULT_SEED := 12345
## Result code for a drawn match (live matches that hit the turn cap even).
const DRAW := 2
## No two characters (of either team) start closer than this many hexes.
const SPAWN_MIN_DISTANCE := 3


## Builds a fresh MatchState on the city map (MapData) — the whole sheet, or
## only `section` (MapData.random_section) — and places both squads at random
## street hexes (random_spawns), facing open street. The placement follows
## from `seed`, so the server can rebuild a match; the server never reveals
## the seed, so nobody can predict where enemies start. The section is
## public (clients need it to draw the map).
static func build_match(
	player_data: Array[UnitData],
	enemy_data: Array[UnitData],
	seed: int = DEFAULT_SEED,
	section: Rect2i = Rect2i()
) -> MatchState:
	var ms := MatchState.new(seed)
	var map := MapData.city(section)
	ms.tiles = map.tiles
	ms.buildings = map.buildings
	ms.cover = map.cover
	var squads := [player_data, enemy_data]
	var spots := random_spawns(ms, player_data.size() + enemy_data.size(), seed)
	var next := 0
	for team in 2:
		var states: Array[UnitState] = []
		var data: Array = squads[team]
		for i in data.size():
			var hex: Vector2i = spots[next]
			next += 1
			states.append(UnitState.new(data[i], team, hex, open_facing(ms, hex, map.facing_toward_center(hex))))
		ms.setup_team(team, states)
	return ms


## The direction with the longest open street ahead of `hex` (so nobody
## starts the match staring at a wall); ties go to `preferred`.
static func open_facing(ms: MatchState, hex: Vector2i, preferred: int) -> int:
	var best := preferred
	var best_run := -1
	for k in 6:
		var d := posmod(preferred + (k + 1) / 2 * (1 if k % 2 == 1 else -1), 6)
		var run := 0
		var at := hex
		while run < Visibility.SIGHT_RANGE:
			at = HexCoord.neighbor(at, d)
			if not ms.floor_legal(at, 0):
				break
			run += 1
		if run > best_run:
			best_run = run
			best = d
	return best


## `count` distinct open street hexes, at least SPAWN_MIN_DISTANCE apart,
## chosen from `seed` (its own RNG, so the combat RNG sequence is untouched).
## Only hexes in the largest connected street area are used, so every
## character can reach every other.
static func random_spawns(ms: MatchState, count: int, seed: int) -> Array[Vector2i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed, "spawns"])
	var open := _largest_street_area(ms)
	# Fisher-Yates over a sorted list, so the result depends only on the seed.
	open.sort()
	for i in range(open.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Vector2i = open[i]
		open[i] = open[j]
		open[j] = tmp
	var out: Array[Vector2i] = []
	for min_gap in [SPAWN_MIN_DISTANCE, 2, 1]:
		out.clear()
		for hex in open:
			var ok := true
			for other in out:
				if HexCoord.distance(hex, other) < min_gap:
					ok = false
					break
			if ok:
				out.append(hex)
				if out.size() == count:
					return out
	push_error("not enough street hexes for %d spawns" % count)
	return out


static func _largest_street_area(ms: MatchState) -> Array[Vector2i]:
	var seen := {}
	var best: Array[Vector2i] = []
	var keys: Array = ms.tiles.keys()
	keys.sort()
	for start in keys:
		if seen.has(start) or not _spawnable(ms, start):
			continue
		var area: Array[Vector2i] = []
		var queue: Array[Vector2i] = [start]
		seen[start] = true
		while not queue.is_empty():
			var hex: Vector2i = queue.pop_back()
			area.append(hex)
			for n in HexCoord.neighbors(hex):
				if not seen.has(n) and _spawnable(ms, n):
					seen[n] = true
					queue.append(n)
		if area.size() > best.size():
			best = area
	return best


static func _spawnable(ms: MatchState, hex: Vector2i) -> bool:
	return ms.tiles.has(hex) and ms.floor_legal(hex, 0) and int(ms.cover.get(hex, 0)) == 0


## Resolves a full 6-tick turn deterministically.
static func resolve_turn(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan) -> Array[CombatEvent]:
	var engine := TickEngine.new()
	return engine.resolve(ms, plan0, plan1)


## Returns the winning team (0 or 1), DRAW when both squads bailed out on the
## same tick (attacks land simultaneously), or -1 while the match is ongoing.
static func winner(ms: MatchState) -> int:
	if team_all_bailed(ms, 0):
		return DRAW if team_all_bailed(ms, 1) else 1
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
