class_name Visibility
extends RefCounted
## Fog of war: per-character vision, 3D line of sight, radar, and Bagworm
## stealth (GDD 4.3). Shared by the server (to filter what each player
## receives) and the client (to draw vision). Distances are in metres.
##
## Every character's vision has two parts (see profile()):
##   - detection radius: short and all-round (DETECT_RANGE). Enemies this
##     close are noticed whichever way the character faces.
##   - sight cone: long, in the facing direction (SIGHT_RANGE, half-angle
##     SIGHT_HALF_ANGLE_DEG). What the character sees with its eyes.
##   Both need a clear sight line: nobody detects through a building.
##   - scopes: sniper rifles (Egret / Ibis) extend the sight range,
##   - elevation: each level above the street extends the sight range.
## Line of sight is traced in 3D from eye height to body height against the
## real building boxes (what the renderer draws). A character inside a
## building sees out (and is seen) only through its outer walls.
##
## An enemy no friendly character sees shows as a Radar Signal: a ghost ping
## offset a few metres (presence only). An enemy with Bagworm active is off
## radar and only revealed within STEALTH_REVEAL_RANGE (or when it attacks).

enum State { SIGHT, RADAR, HIDDEN }

const HEX := 1.7320508075688772
const DETECT_RANGE := 2.0 * HEX
const SIGHT_RANGE := 9.0 * HEX
const SIGHT_HALF_ANGLE_DEG := 45.0
const SCOPE_BONUS := 3.0 * HEX
## Sight range per level of height, up to MAX_ELEVATION_LEVELS levels.
const LEVEL_SIGHT_BONUS := HEX
const MAX_ELEVATION_LEVELS := 4
## How far a sight line may run inside its own building before leaving it
## (standing at a window).
const WINDOW_REACH := 1.4
const SAME_ROOM_RANGE := 1.0 * HEX
const STEALTH_REVEAL_RANGE := 3.0 * HEX
## Radar ghost offset range (metres from the true position).
const PING_MIN := 1.5
const PING_MAX := 3.5
## Heights in floors above a character's level.
const EYE_HEIGHT := 0.8
const BODY_HEIGHT := 0.5
## A sight line that passes through less than this much of a building
## (metres) only grazes it, and is not blocked.
const GRAZE_EPSILON := 0.001
## How far building boxes are padded when testing for a graze.
const TOUCH_PAD := 0.0001


# --- Vision Profiles ---------------------------------------------------------

## A character's vision: {detect, sight_range} in metres, sight_half in degrees.
static func profile(u: UnitState) -> Dictionary:
	var sight := SIGHT_RANGE
	for slots in [u.unit_data.main_trigger_slots, u.unit_data.sub_trigger_slots]:
		for c in slots:
			var card: TriggerCard = c
			if card != null and card.card_type == TriggerCard.CardType.RANGED and card.attack_range >= 15.0:
				sight = SIGHT_RANGE + SCOPE_BONUS  # sniper scope
	return {
		"detect": DETECT_RANGE,
		"sight_range": sight + mini(u.level, MAX_ELEVATION_LEVELS) * LEVEL_SIGHT_BONUS,
		"sight_half": SIGHT_HALF_ANGLE_DEG,
	}


## Angle (degrees) between the viewer's facing and the direction to `p`.
static func view_angle(viewer: UnitState, p: Vector2) -> float:
	var to := p - viewer.pos
	if to.length() < 0.0001:
		return 0.0
	return rad_to_deg(absf(viewer.forward().angle_to(to)))


## Whether `p` lies inside the viewer's sight cone angle (its "firing arc").
static func in_cone(viewer: UnitState, p: Vector2) -> bool:
	return view_angle(viewer, p) <= SIGHT_HALF_ANGLE_DEG


## Whether `p` is within the viewer's vision volume (range + angle only).
static func in_view(viewer: UnitState, p: Vector2, prof: Dictionary = {}) -> bool:
	if prof.is_empty():
		prof = profile(viewer)
	var dist := viewer.pos.distance_to(p)
	if dist <= float(prof["detect"]):
		return true
	if dist > float(prof["sight_range"]):
		return false
	return view_angle(viewer, p) <= float(prof["sight_half"])


# --- Line of Sight ----------------------------------------------------------

## 3D line of sight from (a, a_level) to (b, b_level), traced against the
## city's boxes (buildings, sealed solids, elevated decks) from eye height to
## body height. Nobody sees through buildings. A character inside a building
## sees out only through its outer wall: the line may run at most
## WINDOW_REACH inside before leaving. Two characters inside the same
## building see each other only within SAME_ROOM_RANGE. Lines that only
## graze a corner are clear; a line through the point where two buildings
## touch corner to corner is blocked.
static func has_los(ms: MatchState, a: Vector2, a_level: int, b: Vector2, b_level: int) -> bool:
	if a.distance_to(b) < 0.0001 and a_level == b_level:
		return true
	var pa := Vector3(a.x, a_level + EYE_HEIGHT, a.y)
	var pb := Vector3(b.x, b_level + BODY_HEIGHT, b.y)
	var length := pa.distance_to(pb)
	var grazes: Array[float] = []
	var geo := ms.geometry()
	for i in geo.sight_candidates(a, b):
		var r: Dictionary = geo.sight[i]
		var hit := CityBox.segment_overlap(r, pa, pb, TOUCH_PAD)
		if hit.is_empty():
			continue
		if (float(hit["t1"]) - float(hit["t0"])) * length < GRAZE_EPSILON + 2.0 * TOUCH_PAD:
			var t := (float(hit["t0"]) + float(hit["t1"])) * 0.5
			for other in grazes:
				if absf(other - t) * length < 0.01:
					return false
			grazes.append(t)
			continue
		var a_in := float(hit["t0"]) <= 0.0
		var b_in := float(hit["t1"]) >= 1.0
		if a_in and b_in:
			if a.distance_to(b) > SAME_ROOM_RANGE:
				return false
		elif a_in:
			if float(hit["t1"]) * length > WINDOW_REACH:
				return false
		elif b_in:
			if (1.0 - float(hit["t0"])) * length > WINDOW_REACH:
				return false
		else:
			return false
	return true


## Whether `viewer` can see position (p, level) right now: inside its vision
## volume with a clear 3D sight line.
static func sees_position(ms: MatchState, viewer: UnitState, p: Vector2, level: int, prof: Dictionary = {}) -> bool:
	if viewer.is_bailed or not in_view(viewer, p, prof):
		return false
	return has_los(ms, viewer.pos, viewer.level, p, level)


# --- Team Views -------------------------------------------------------------

## Visibility of every enemy from `team`'s perspective: UnitState -> State.
## Bailed units are public (SIGHT).
static func enemy_states(ms: MatchState, team: int) -> Dictionary:
	var out := {}
	var friends: Array = []
	var profiles: Array = []
	for f in ms.teams[team]:
		if not (f as UnitState).is_bailed:
			friends.append(f)
			profiles.append(profile(f))
	for e in ms.teams[1 - team]:
		var enemy: UnitState = e
		if enemy.is_bailed:
			out[enemy] = State.SIGHT
			continue
		var seen := false
		var near := false
		for i in friends.size():
			var friend: UnitState = friends[i]
			if friend.pos.distance_to(enemy.pos) <= STEALTH_REVEAL_RANGE:
				near = true
			if not seen and sees_position(ms, friend, enemy.pos, enemy.level, profiles[i]):
				seen = true
		if enemy.stealth_active:
			out[enemy] = State.SIGHT if (near and seen) else (State.RADAR if near else State.HIDDEN)
		else:
			out[enemy] = State.SIGHT if seen else State.RADAR
	return out


## Whether `team` currently has eyes on `enemy` (what it may shoot at).
static func spotted(ms: MatchState, team: int, enemy: UnitState) -> bool:
	return int(enemy_states(ms, team).get(enemy, State.HIDDEN)) == State.SIGHT


## Whether some living character of `team` sees ground point `p`.
static func team_sees_point(ms: MatchState, team: int, p: Vector2, level: int = 0) -> bool:
	for f in ms.teams[team]:
		if sees_position(ms, f, p, level):
			return true
	return false


## Radar ghost position for an unseen enemy: a few metres off its true
## position, deterministic per (salt, unit) so it doesn't jitter.
static func radar_ping(ms: MatchState, enemy: UnitState, unit_index: int, salt: int) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = salt * 1000003 + enemy.team * 7919 + unit_index * 104729
	var angle := rng.randf_range(-PI, PI)
	var dist := rng.randf_range(PING_MIN, PING_MAX)
	var p := enemy.pos + Vector2.from_angle(angle) * dist
	var b := ms.bounds().grow(-0.5)
	return Vector2(clampf(p.x, b.position.x, b.end.x), clampf(p.y, b.position.y, b.end.y))


# --- Filtered Views (what one team is allowed to know) ---------------------

## Serializable snapshot of the match as seen by `team`. Own units are exact;
## enemies are exact only in SIGHT, a ping position in RADAR, nothing when
## HIDDEN. `salt` varies the radar offsets; the server passes a value keyed
## with a per-match secret so they can't be reproduced by a client. With
## `fog_wires`, enemy Spider wires are included only where the team sees them.
static func encode_view(ms: MatchState, team: int, salt: int, fog_wires: bool = false) -> Dictionary:
	var states := enemy_states(ms, team)
	var units: Array = []
	var index := 0
	for u in ms.all_units():
		var vis: int = State.SIGHT if u.team == team else int(states[u])
		match vis:
			State.SIGHT:
				units.append({
					"vis": State.SIGHT,
					"pos": [snappedf(u.pos.x, 0.001), snappedf(u.pos.y, 0.001)],
					"level": u.level,
					"facing": snappedf(u.facing, 0.0001),
					"hp": u.trion_hp,
					"bailed": u.is_bailed,
					"stealth": u.stealth_active,
					"weight": snappedf(u.weight_time, 0.01),
					"shield": u.shield_active,
				})
			State.RADAR:
				var ping := radar_ping(ms, u, index, salt)
				units.append({ "vis": State.RADAR, "ping": [snappedf(ping.x, 0.01), snappedf(ping.y, 0.01)] })
			_:
				units.append({ "vis": State.HIDDEN })
		index += 1
	var wires: Array = []
	for w in ms.wires:
		var owner := int(w["team"])
		if fog_wires and owner != team and not team_sees_point(ms, team, w["pos"]):
			continue
		wires.append([snappedf((w["pos"] as Vector2).x, 0.001), snappedf((w["pos"] as Vector2).y, 0.001), owner])
	return { "units": units, "wires": wires }


## Whether `team` may see a combat event: anything its own units do or
## suffer, plus actions by enemies currently in sight.
static func event_visible(ev: CombatEvent, team: int, states: Dictionary) -> bool:
	for u in [ev.actor, ev.target]:
		if u != null and (u as UnitState).team == team:
			return true
	return ev.actor != null and int(states.get(ev.actor, State.HIDDEN)) == State.SIGHT
