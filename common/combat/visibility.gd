class_name Visibility
extends RefCounted
## Fog of war: per-character vision, 3D line of sight, radar, and Bagworm
## stealth (GDD 4.3). Shared by the server (to filter what each player
## receives) and the client (to render the fog and vision cones).
##
## Every character has its own vision profile (see profile()):
##   - focus cone: narrow and long (where the character is looking),
##   - peripheral cone: wide and short,
##   - awareness: a small all-round radius (still needs a clear sight line),
##   - scopes: sniper rifles (Egret / Ibis) extend the focus range,
##   - elevation: each floor above the street adds range (rooftop overlook).
## Line of sight is traced in 3D from eye height to body height against the
## real building boxes: nobody sees through a building, and full cover blocks
## low lines. Units inside a building see and are seen only through its outer
## walls (windows).
##
## An enemy seen by no friendly unit shows as a Radar Signal: a ghost ping
## offset 1-2 hexes (presence only). An enemy with Bagworm active is removed
## from radar and only revealed within STEALTH_REVEAL_RANGE (or when it attacks).

enum State { SIGHT, RADAR, HIDDEN }

const FOCUS_RANGE := 8
const FOCUS_HALF_ANGLE_DEG := 30.0
const PERIPHERAL_RANGE := 5
const PERIPHERAL_HALF_ANGLE_DEG := 70.0
const AWARENESS_RANGE := 2
## How far a sight line may run inside a unit's own building before leaving
## it (standing at the window). Covers hexes along the outer wall.
const WINDOW_REACH := 1.4
const SAME_ROOM_RANGE := 1
const SCOPE_BONUS := 4
const MAX_ELEVATION_BONUS := 4
const STEALTH_REVEAL_RANGE := 3
## Heights in floors above a unit's floor.
const EYE_HEIGHT := 0.8
const BODY_HEIGHT := 0.5
## Full cover (walls, barricades) is about one floor tall.
const FULL_COVER_HEIGHT := 1.0


# --- Vision Profiles ---------------------------------------------------------

## A character's vision: ranges (hexes) and half-angles (degrees).
static func profile(u: UnitState) -> Dictionary:
	var focus := FOCUS_RANGE
	for slots in [u.unit_data.main_trigger_slots, u.unit_data.sub_trigger_slots]:
		for c in slots:
			var card: TriggerCard = c
			if card != null and card.card_type == TriggerCard.CardType.RANGED and card.attack_range >= 9:
				focus = FOCUS_RANGE + SCOPE_BONUS  # sniper scope
	var height_bonus := mini(u.floor, MAX_ELEVATION_BONUS)
	return {
		"focus_range": focus + height_bonus,
		"focus_half": FOCUS_HALF_ANGLE_DEG,
		"peripheral_range": PERIPHERAL_RANGE + height_bonus,
		"peripheral_half": PERIPHERAL_HALF_ANGLE_DEG,
		"awareness": AWARENESS_RANGE,
	}


## Angle (degrees) between the viewer's facing and the direction to `hex`.
static func view_angle(viewer: UnitState, hex: Vector2i) -> float:
	if hex == viewer.hex:
		return 0.0
	var to := HexCoord.axial_to_world(hex, 1.0) - HexCoord.axial_to_world(viewer.hex, 1.0)
	var fwd := HexCoord.axial_to_world(HexCoord.AXIAL_DIRECTIONS[viewer.facing], 1.0)
	return rad_to_deg(fwd.normalized().angle_to(to.normalized()))


## Whether `hex` lies inside the viewer's peripheral arc (its "firing arc").
static func in_cone(viewer: UnitState, hex: Vector2i) -> bool:
	return view_angle(viewer, hex) <= PERIPHERAL_HALF_ANGLE_DEG


## Whether `hex` is within the viewer's vision volume (range + angle only).
static func in_view(viewer: UnitState, hex: Vector2i, p: Dictionary = {}) -> bool:
	if p.is_empty():
		p = profile(viewer)
	var dist := HexCoord.distance(viewer.hex, hex)
	if dist <= int(p["awareness"]):
		return true
	if dist > int(p["focus_range"]):
		return false
	var angle := view_angle(viewer, hex)
	if dist <= int(p["peripheral_range"]) and angle <= float(p["peripheral_half"]):
		return true
	return angle <= float(p["focus_half"])


# --- Line of Sight ----------------------------------------------------------

## 3D line of sight from (a, a_floor) to (b, b_floor), traced against the
## actual building geometry (BuildingRects boxes — exactly what's rendered):
## the sight line runs from eye height to body height and is blocked by any
## building box it passes through, and by full cover under a low line.
## Nobody sees through buildings. A unit inside a building sees out (and is
## seen) only through its outer wall: the line may run at most WINDOW_REACH
## inside the unit's own building before leaving it. Two units inside the
## same building see each other only within SAME_ROOM_RANGE.
static func has_los(ms: MatchState, a: Vector2i, a_floor: int, b: Vector2i, b_floor: int) -> bool:
	if a == b:
		return true
	var pa := HexCoord.axial_to_world(a, 1.0)
	var pb := HexCoord.axial_to_world(b, 1.0)
	pa.y = a_floor + EYE_HEIGHT
	pb.y = b_floor + BODY_HEIGHT
	var length := pa.distance_to(pb)

	var path := HexCoord.line(a, b)
	var rects := ms.building_rects()
	var checked := {}
	for hex in path:
		for h in [hex] + HexCoord.neighbors(hex):
			var idx := ms.building_rect_index(h)
			if idx == -1 or checked.has(idx):
				continue
			checked[idx] = true
			var r: Dictionary = rects[idx]
			var hit := _segment_box(pa, pb, r)
			if hit.is_empty():
				continue
			var a_in := float(hit["t0"]) <= 0.0
			var b_in := float(hit["t1"]) >= 1.0
			if a_in and b_in:
				# Both inside the same building: only within the same room.
				if HexCoord.distance(a, b) > SAME_ROOM_RANGE:
					return false
			elif a_in:
				if float(hit["t1"]) * length > WINDOW_REACH:
					return false
			elif b_in:
				if (1.0 - float(hit["t0"])) * length > WINDOW_REACH:
					return false
			else:
				return false

	# Full cover (walls, barricades) blocks low lines.
	var n := path.size() - 1
	for i in range(1, n):
		if int(ms.cover.get(path[i], 0)) >= 2 and lerpf(pa.y, pb.y, float(i) / float(n)) < FULL_COVER_HEIGHT:
			return false
	return true


## Parametric overlap [t0, t1] (clamped to [0, 1]) of segment pa->pb with a
## building box, or {} if they don't meet. Slab method.
static func _segment_box(pa: Vector3, pb: Vector3, r: Dictionary) -> Dictionary:
	var b := BuildingRects.bounds(r)
	var lo := Vector3(b.position.x, 0.0, b.position.y)
	var hi := Vector3(b.end.x, float(r["floors"]), b.end.y)
	var d := pb - pa
	var t0 := 0.0
	var t1 := 1.0
	for axis in 3:
		var o := pa[axis]
		var v := d[axis]
		if absf(v) < 1e-9:
			if o <= lo[axis] or o >= hi[axis]:
				return {}
			continue
		var ta := (lo[axis] - o) / v
		var tb := (hi[axis] - o) / v
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 >= t1:
			return {}
	return { "t0": t0, "t1": t1 }


## Whether `viewer` can see position (hex, floor) right now: inside its vision
## volume with a clear 3D sight line (no seeing through buildings).
static func sees_position(ms: MatchState, viewer: UnitState, hex: Vector2i, floor: int, p: Dictionary = {}) -> bool:
	if viewer.is_bailed:
		return false
	if not in_view(viewer, hex, p):
		return false
	return has_los(ms, viewer.hex, viewer.floor, hex, floor)


# --- Team Views -------------------------------------------------------------

## Visibility of every enemy unit from `team`'s perspective:
## Dictionary UnitState -> State. Bailed units are public (SIGHT).
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
			if HexCoord.distance(friend.hex, enemy.hex) <= STEALTH_REVEAL_RANGE:
				near = true
			if not seen and sees_position(ms, friend, enemy.hex, enemy.floor, profiles[i]):
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
		if not friend.is_bailed:
			unit_visible_hexes(ms, friend, out)
	return out


## Hexes one character can see — at street level or on the rooftop there.
## Adds into `out` (and returns it) so team views can accumulate.
static func unit_visible_hexes(ms: MatchState, u: UnitState, out: Dictionary = {}) -> Dictionary:
	var p := profile(u)
	for hex in HexCoord.spiral(u.hex, int(p["focus_range"])):
		if out.has(hex) or not ms.has_tile(hex) or not in_view(u, hex, p):
			continue
		var roof := ms.building_floors(hex)
		if sees_position(ms, u, hex, 0, p) or (roof > 0 and sees_position(ms, u, hex, roof, p)):
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
					"weight": u.weight_ticks,
				})
			State.RADAR:
				var ping := radar_ping(ms, u, index, salt)
				units.append({ "vis": State.RADAR, "ping": [ping.x, ping.y] })
			_:
				units.append({ "vis": State.HIDDEN })
		index += 1
	var wires: Array = []
	for hex in ms.wires:
		wires.append([hex.x, hex.y, int(ms.wires[hex])])
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
