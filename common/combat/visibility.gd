class_name Visibility
extends RefCounted
## Fog of war: line of sight, vision cones, radar, and Bagworm stealth
## (GDD 4.3). Shared by the server (to filter what each player receives) and
## the client (to render the fog).
##
## Each unit sees enemies that are:
##   - within SIGHT_RANGE inside its forward vision cone, or
##   - within AWARENESS_RANGE in any direction,
## and not blocked by a building taller than both eyes (or full cover when
## both units are on the ground). An enemy seen by no friendly unit shows as
## a Radar Signal: a ghost ping offset 1-2 hexes (presence only). An enemy
## with Bagworm active is removed from radar entirely and is only revealed
## when a friendly unit comes within STEALTH_REVEAL_RANGE (or it attacks).

enum State { SIGHT, RADAR, HIDDEN }

const SIGHT_RANGE := 8
const AWARENESS_RANGE := 2
const CONE_HALF_ANGLE_DEG := 65.0
const STEALTH_REVEAL_RANGE := 3


# --- Line of Sight ----------------------------------------------------------

## Whether the straight line between two positions is unobstructed. A
## building blocks if it is taller than both endpoints' floors; full cover
## only blocks ground-level lines.
static func has_los(ms: MatchState, a: Vector2i, a_floor: int, b: Vector2i, b_floor: int) -> bool:
	var eye := maxi(a_floor, b_floor)
	for hex in HexCoord.line(a, b):
		if hex == a or hex == b:
			continue
		if ms.building_floors(hex) > eye:
			return false
		if eye == 0 and int(ms.cover.get(hex, 0)) >= 2:
			return false
	return true


## Whether `hex` lies inside the viewer's forward vision cone.
static func in_cone(viewer: UnitState, hex: Vector2i) -> bool:
	if hex == viewer.hex:
		return true
	var origin := HexCoord.axial_to_world(viewer.hex, 1.0)
	var to := HexCoord.axial_to_world(hex, 1.0) - origin
	var fwd := HexCoord.axial_to_world(HexCoord.AXIAL_DIRECTIONS[viewer.facing], 1.0)
	var cos_angle := fwd.normalized().dot(to.normalized())
	return cos_angle >= cos(deg_to_rad(CONE_HALF_ANGLE_DEG))


## Whether `viewer` can see position (hex, floor) right now.
static func sees_position(ms: MatchState, viewer: UnitState, hex: Vector2i, floor: int) -> bool:
	if viewer.is_bailed:
		return false
	var dist := HexCoord.distance(viewer.hex, hex)
	if dist > SIGHT_RANGE:
		return false
	if dist > AWARENESS_RANGE and not in_cone(viewer, hex):
		return false
	return has_los(ms, viewer.hex, viewer.floor, hex, floor)


# --- Team Views -------------------------------------------------------------

## Visibility of every enemy unit from `team`'s perspective:
## Dictionary UnitState -> State. Bailed units are public (SIGHT).
static func enemy_states(ms: MatchState, team: int) -> Dictionary:
	var out := {}
	var friends: Array = ms.teams[team]
	for e in ms.teams[1 - team]:
		var enemy: UnitState = e
		if enemy.is_bailed:
			out[enemy] = State.SIGHT
			continue
		var seen := false
		var near := false
		for f in friends:
			var friend: UnitState = f
			if friend.is_bailed:
				continue
			if HexCoord.distance(friend.hex, enemy.hex) <= STEALTH_REVEAL_RANGE:
				near = true
			if sees_position(ms, friend, enemy.hex, enemy.floor):
				seen = true
		if enemy.stealth_active:
			out[enemy] = State.SIGHT if (near and seen) else (State.RADAR if near else State.HIDDEN)
		else:
			out[enemy] = State.SIGHT if seen else State.RADAR
	return out


## Every hex currently inside some friendly unit's sight (for the fog overlay).
static func visible_hexes(ms: MatchState, team: int) -> Dictionary:
	var out := {}
	for f in ms.teams[team]:
		var friend: UnitState = f
		if friend.is_bailed:
			continue
		for hex in HexCoord.spiral(friend.hex, SIGHT_RANGE):
			if out.has(hex) or not ms.has_tile(hex):
				continue
			if sees_position(ms, friend, hex, 0) or sees_position(ms, friend, hex, ms.building_floors(hex)):
				out[hex] = true
	return out


## Radar ghost position for an unseen enemy: 1-2 hexes off its true hex,
## deterministic per (salt, unit) so pings don't jitter within a tick.
static func radar_ping(ms: MatchState, enemy: UnitState, unit_index: int, salt: int) -> Vector2i:
	var options: Array[Vector2i] = []
	for radius in [1, 2]:
		for hex in HexCoord.ring(enemy.hex, radius):
			if ms.has_tile(hex):
				options.append(hex)
	if options.is_empty():
		return enemy.hex
	var rng := RandomNumberGenerator.new()
	rng.seed = salt * 1000003 + enemy.team * 7919 + unit_index * 104729
	return options[rng.randi_range(0, options.size() - 1)]


# --- Filtered Views (what one team is allowed to know) ---------------------

## Serializable snapshot of the match as seen by `team`. Own units are exact;
## enemies are exact only in SIGHT, a ping position in RADAR, nothing when
## HIDDEN. `salt` varies the radar offsets (e.g. turn * 10 + tick).
static func encode_view(ms: MatchState, team: int, salt: int) -> Dictionary:
	var states := enemy_states(ms, team)
	var units: Array = []
	var index := 0
	for u in ms.all_units():
		var vis: int = State.SIGHT if u.team == team else int(states[u])
		match vis:
			State.SIGHT:
				units.append({
					"vis": State.SIGHT,
					"hex": [u.hex.x, u.hex.y],
					"floor": u.floor,
					"facing": u.facing,
					"hp": u.trion_hp,
					"bailed": u.is_bailed,
					"stealth": u.stealth_active,
				})
			State.RADAR:
				var ping := radar_ping(ms, u, index, salt)
				units.append({ "vis": State.RADAR, "ping": [ping.x, ping.y] })
			_:
				units.append({ "vis": State.HIDDEN })
		index += 1
	var wires: Array = []
	for hex in ms.wires:
		wires.append([hex.x, hex.y])
	return { "units": units, "wires": wires }


## Whether `team` may see a combat event: anything its own units do or
## suffer, plus actions by enemies currently in sight.
static func event_visible(ev: CombatEvent, team: int, states: Dictionary) -> bool:
	for u in [ev.actor, ev.target]:
		if u == null:
			continue
		var unit: UnitState = u
		if unit.team == team:
			return true
	if ev.actor != null and int(states.get(ev.actor, State.HIDDEN)) == State.SIGHT:
		return true
	return false
