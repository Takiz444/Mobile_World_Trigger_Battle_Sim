class_name MatchRunner
extends RefCounted
## Shared deterministic match logic used by both the local client and the
## headless server: squad placement, turn resolution, and winner detection.
## This is the single source of truth for the "server-authoritative" turn math.

const DEFAULT_SEED := 12345
## Result code for a drawn match (live matches that hit the turn cap even).
const DRAW := 2
## Every character starts with nobody else, friend or foe, within a 3-hex
## radius (about 5.2 m): any two are at least this far apart.
const SPAWN_MIN_DISTANCE := 4.0 * 1.7320508075688772
## Random placements tried before giving up on SPAWN_MIN_DISTANCE.
const SPAWN_ATTEMPTS := 64


## Builds a fresh MatchState on the city map (MapData) — the whole sheet, or
## only `section` (MapData.random_section) — and places both squads at random
## open street spots (random_spawns), facing open street. The placement
## follows from `seed`, so the server can rebuild a match; the server never
## reveals the seed, so nobody can predict where enemies start. The section
## is public (clients need it to draw the map).
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
	var squads := [player_data, enemy_data]
	var spots := random_spawns(ms, player_data.size() + enemy_data.size(), seed)
	var center := ms.bounds().get_center()
	var next := 0
	for team in 2:
		var states: Array[UnitState] = []
		var data: Array = squads[team]
		for i in data.size():
			var p: Vector2 = spots[next]
			next += 1
			states.append(UnitState.new(data[i], team, p, open_facing(ms, p, (center - p).angle())))
		ms.setup_team(team, states)
	return ms


## The direction with the longest clear street ahead of `p` (so nobody starts
## the match staring at a wall), out of 16; ties go toward `preferred`.
static func open_facing(ms: MatchState, p: Vector2, preferred: float) -> float:
	var geo := ms.geometry()
	var best := preferred
	var best_run := -1.0
	for k in 16:
		var a := preferred + TAU * k / 16.0
		var dir := Vector2.from_angle(a)
		var run := 0.0
		while run < Visibility.SIGHT_RANGE and geo.ground_clear(p, p + dir * (run + 0.5)):
			run += 0.5
		if run > best_run + 0.01:
			best_run = run
			best = a
	return wrapf(best, -PI, PI)


## `count` open street spots, at least SPAWN_MIN_DISTANCE apart, chosen from
## `seed` (its own RNG, so the combat RNG sequence is untouched). Only spots
## in the largest connected street area are used, so every character can
## reach every other.
static func random_spawns(ms: MatchState, count: int, seed: int) -> Array[Vector2]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed, "spawns"])
	var open := _street_spots(ms)
	for _attempt in SPAWN_ATTEMPTS:
		_shuffle(open, rng)
		var out := _spread(open, count, SPAWN_MIN_DISTANCE)
		if out.size() == count:
			return out
	push_warning("could not place %d characters %.1f m apart; placing them closer" % [count, SPAWN_MIN_DISTANCE])
	for gap in [SPAWN_MIN_DISTANCE * 0.66, SPAWN_MIN_DISTANCE * 0.33, 0.7]:
		var out := _spread(open, count, gap)
		if out.size() == count:
			return out
	push_error("not enough open street for %d spawns" % count)
	return _spread(open, count, 0.0)


## Candidate spawn spots: a 1 m lattice over the street, kept only where it
## belongs to the largest connected street area. Sorted, so results depend
## only on the seed.
static func _street_spots(ms: MatchState) -> Array[Vector2]:
	var geo := ms.geometry()
	var b := geo.bounds
	var cells := {}
	var nx := int(b.size.x)
	var ny := int(b.size.y)
	for x in nx:
		for y in ny:
			var p := b.position + Vector2(x + 0.5, y + 0.5)
			if geo.ground_ok(p):
				cells[Vector2i(x, y)] = p
	var seen := {}
	var best: Array[Vector2i] = []
	var keys: Array = cells.keys()
	keys.sort()
	for start in keys:
		if seen.has(start):
			continue
		var area: Array[Vector2i] = []
		var queue: Array[Vector2i] = [start]
		seen[start] = true
		while not queue.is_empty():
			var c: Vector2i = queue.pop_back()
			area.append(c)
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				if cells.has(n) and not seen.has(n) and geo.ground_clear(cells[c], cells[n]):
					seen[n] = true
					queue.append(n)
		if area.size() > best.size():
			best = area
	best.sort()
	var out: Array[Vector2] = []
	for c in best:
		out.append(cells[c])
	return out


## The first spots of `order` that are all at least `gap` apart (up to `count`).
static func _spread(order: Array[Vector2], count: int, gap: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for p in order:
		var ok := true
		for other in out:
			if p.distance_to(other) < gap:
				ok = false
				break
		if ok:
			out.append(p)
			if out.size() == count:
				break
	return out


## Fisher-Yates shuffle in place.
static func _shuffle(list: Array[Vector2], rng: RandomNumberGenerator) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Vector2 = list[i]
		list[i] = list[j]
		list[j] = tmp


## Seconds of match time per replay frame.
const FRAME_SECONDS := 0.25


## Plays one turn out on `ms` and returns each team's replay: [frames0,
## frames1], each frame {t, events, view} with only what that team may see.
## The first frame (t = 0) is the starting view. `salt_for(frame)` gives the
## radar salt of a frame. Shared with the client's local matches, which run
## the same pipeline on a hidden copy of the match (the server calls this too).
static func record_turn(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan, salt_for: Callable) -> Array:
	var engine := TurnEngine.new()
	engine.begin(ms, plan0, plan1)
	var frames: Array = [[], []]
	var pending: Array[CombatEvent] = []
	var frame := 0
	_add_frames(ms, frames, pending, 0.0, salt_for.call(frame))
	var per_frame := int(round(FRAME_SECONDS / TurnEngine.STEP))
	var steps := 0
	while not engine.done():
		pending.append_array(engine.step())
		steps += 1
		if steps % per_frame == 0 or engine.done():
			frame += 1
			_add_frames(ms, frames, pending, engine.time, salt_for.call(frame))
			pending.clear()
	return frames


static func _add_frames(ms: MatchState, frames: Array, events: Array[CombatEvent], t: float, salt: int) -> void:
	for team in 2:
		var states := Visibility.enemy_states(ms, team)
		var seen: Array[CombatEvent] = []
		for ev in events:
			if Visibility.event_visible(ev, team, states):
				seen.append(ev)
		frames[team].append({
			"t": snappedf(t, 0.001),
			"events": PlanCodec.encode_events(seen),
			"view": Visibility.encode_view(ms, team, salt, true),
		})


## Resolves a full turn deterministically.
static func resolve_turn(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan) -> Array[CombatEvent]:
	return TurnEngine.new().resolve(ms, plan0, plan1)


## Returns the winning team (0 or 1), DRAW when both squads bailed out at the
## same moment (attacks land simultaneously), or -1 while the match is ongoing.
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


## Defensive fallback plan per GDD 3.1: "Stand Ground + Shield" for the
## whole turn (a standing shield is a Full Guard).
static func build_fallback_plan(units: Array[UnitData]) -> TurnPlan:
	var plan := TurnPlan.new(units)
	var shield := TriggerLibrary.get_card("Shield")
	for i in units.size():
		var a := PlanAction.new(shield)
		a.hold = TurnPlan.TURN_SECONDS
		plan.add(i, a)
	return plan
