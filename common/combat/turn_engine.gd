class_name TurnEngine
extends RefCounted
## Deterministic resolution of one turn in continuous time.
##
## Both squads' plans (TurnPlan) play out at once over TURN_SECONDS, simulated
## in fixed STEP increments. Each step:
##   1. State     — Look, Bagworm and Spider actions that finish now
##   2. Movement  — every character advances along its route at once; a move
##                  that would bump into another character waits (fair: the
##                  same rule for everyone, whatever order they're processed in)
##   3. Defense   — shields that are up now (standing still = Full Guard)
##   4. Attack    — attacks whose wind-up finishes now fire, all against the
##                  same moment (simultaneous)
##   5. Resolution — damage lands, characters at 0 Trion bail out
##
## The two lanes of a plan run side by side. The Action lane keeps its planned
## times; the Movement lane runs move after move, so a move that had to wait
## finishes later (and whatever doesn't finish by the end of the turn is cut).
##
## Attacks target an enemy character. The shot only goes off if the
## attacker's team sees the target at that moment and (except curved Viper
## shots) the attacker has a clear line to it; melee needs the target within
## MELEE_RANGE on the same level. All randomness goes through MatchState.rng.

const TURN_SECONDS := TurnPlan.TURN_SECONDS
const STEP := 0.05
const HEX := 1.7320508075688772

const MELEE_RANGE := 1.0 * HEX + 0.1
const BASE_RANGED_HIT := 0.9
const BASE_MELEE_HIT := 0.95
const EVASION_PER_MOBILITY := 0.02
## Dodge bonus of a moving target against straight shots (Hound tracks it).
const MOVING_TARGET_EVADE := 0.1
## Accuracy lost shooting while on the move.
const MOVING_SHOOTER_PENALTY := 0.15
const STEALTH_REVEAL_RANGE := 3.0 * HEX
const FULL_GUARD_DEF_MULT := 1.5
const WIRE_DEF_BONUS := 0.2
const WIRE_EVADE_BONUS := 0.1
## Lead Bullet: how long the target can't move or dodge.
const WEIGHT_SECONDS := 3.0
const SPIDER_RANGE := 3.0 * HEX
## A shield covers this many degrees either side of the facing.
const SHIELD_HALF_ARC_DEG := 90.0

## Test hook: when true, skip hit rolls so every valid attack lands.
var always_hit := false
var time := 0.0

var _ms: MatchState
var _plans: Array = []
var _runs: Array = []   # per unit (all_units order): run state, see begin()


## Resolves a whole turn and returns its events.
func resolve(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan) -> Array[CombatEvent]:
	begin(ms, plan0, plan1)
	var events: Array[CombatEvent] = []
	while not done():
		events.append_array(step())
	return events


## Prepares a turn: schedules both squads' plans from the current state.
func begin(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan) -> void:
	_ms = ms
	_plans = [plan0, plan1]
	time = 0.0
	_runs.clear()
	for team in 2:
		var squad: Array = ms.teams[team]
		var plan: TurnPlan = _plans[team]
		for i in squad.size():
			var u: UnitState = squad[i]
			# Bagworm and Look last one turn; nothing carries over.
			u.stealth_active = false
			u.watching = false
			u.shield_active = false
			u.full_guard = false
			u.moving = false
			var moves: Array = []
			var acts: Array = []
			if plan != null and i < plan.units.size() and not u.is_bailed:
				moves = plan.move_schedule(ms, u, i)
				acts = plan.act_schedule(i)
			_runs.append({ "unit": u, "team": team, "index": i, "moves": moves, "move_i": 0, "seg_i": 0,
				"seg_t": 0.0, "wait_left": -1.0, "started": false, "blocked_noted": false,
				"acts": acts, "act_done": {} })


func done() -> bool:
	return time >= TURN_SECONDS - 1e-6 or MatchRunner.team_all_bailed(_ms, 0) or MatchRunner.team_all_bailed(_ms, 1)


## Advances one STEP; returns the events of that step.
func step() -> Array[CombatEvent]:
	var events: Array[CombatEvent] = []
	var t0 := time
	var t1 := minf(time + STEP, TURN_SECONDS)
	_state_phase(t0, t1, events)
	_movement_phase(t1, events)
	_defense_phase(t1)
	var pending := _attack_phase(t0, t1, events)
	_resolution_phase(pending, t1, events)
	for r in _runs:
		var u: UnitState = r["unit"]
		if u.weight_time > 0.0:
			u.weight_time = maxf(0.0, u.weight_time - (t1 - t0))
	time = t1
	return events


# --- Helpers ------------------------------------------------------------------

func _alive_runs() -> Array:
	return _runs.filter(func(r: Dictionary) -> bool: return not (r["unit"] as UnitState).is_bailed)


## Action-lane entries of `r` that finish in (t0, t1], in order.
func _finishing(r: Dictionary, t0: float, t1: float) -> Array:
	var out: Array = []
	var acts: Array = r["acts"]
	for k in acts.size():
		var e: Dictionary = acts[k]
		if r["act_done"].has(k):
			continue
		if float(e["end"]) > t0 + 1e-9 and float(e["end"]) <= t1 + 1e-9:
			out.append(k)
	return out


func _face(u: UnitState, toward: Vector2) -> void:
	var d := toward - u.pos
	if d.length() > 0.0001:
		u.facing = d.angle()


# --- 1. State -----------------------------------------------------------------

func _state_phase(t0: float, t1: float, events: Array[CombatEvent]) -> void:
	for r in _alive_runs():
		var u: UnitState = r["unit"]
		for k in _finishing(r, t0, t1):
			var a: PlanAction = r["acts"][k]["action"]
			match a.card.card_name:
				"Look":
					r["act_done"][k] = true
					u.watching = true
					u.watch_point = a.point
					_face(u, a.point)
					events.append(CombatEvent.new(t1, CombatEvent.Phase.STATE, "%s turns to keep watch" % u.display_name(), u))
				"Bagworm":
					r["act_done"][k] = true
					if not u.stealth_active:
						u.stealth_active = true
						events.append(CombatEvent.new(t1, CombatEvent.Phase.STATE, "%s activates Bagworm (stealth)" % u.display_name(), u))
				"Spider":
					r["act_done"][k] = true
					if u.pos.distance_to(a.point) <= SPIDER_RANGE + 0.01 and _ms.geometry().ground_ok(a.point):
						_ms.wires.append({ "pos": a.point, "team": u.team })
						events.append(CombatEvent.new(t1, CombatEvent.Phase.STATE, "%s strings a Spider wire" % u.display_name(), u))
					else:
						events.append(CombatEvent.new(t1, CombatEvent.Phase.STATE, "%s can't string Spider wire there" % u.display_name(), u))
				"Wait":
					r["act_done"][k] = true


# --- 2. Movement --------------------------------------------------------------

## Advances every character along its Movement lane at once. A step that
## would bring two characters on the same level within two radii of each
## other is cancelled for the one(s) moving; repeated until nothing overlaps,
## so the result doesn't depend on processing order.
func _movement_phase(t1: float, events: Array[CombatEvent]) -> void:
	var dt := STEP
	var intents: Dictionary = {}   # run index -> {pos, level, state}
	var runs := _runs
	for ri in runs.size():
		var r: Dictionary = runs[ri]
		var u: UnitState = r["unit"]
		if u.is_bailed:
			continue
		var intent := _advance(r, dt, t1)
		if not intent.is_empty():
			intents[ri] = intent
	# Cancel conflicting moves until stable. Every round finds all conflicts
	# against the same snapshot and cancels them together, so no character
	# gets priority from being processed first.
	var limit := CityGeometry.UNIT_RADIUS * 2.0
	while true:
		var cancel: Array = []
		for ri in intents:
			var me: Dictionary = intents[ri]
			var u: UnitState = runs[ri]["unit"]
			for rj in runs.size():
				if rj == ri:
					continue
				var other: UnitState = runs[rj]["unit"]
				if other.is_bailed:
					continue
				var o_pos: Vector2 = intents[rj]["pos"] if intents.has(rj) else other.pos
				var o_level: int = intents[rj]["level"] if intents.has(rj) else other.level
				if o_level != int(me["level"]):
					continue
				var d_new := o_pos.distance_to(me["pos"])
				# Moving apart is always fine (even when already too close).
				if d_new < limit and d_new < other.pos.distance_to(u.pos) - 0.0001:
					cancel.append(ri)
					break
		if cancel.is_empty():
			break
		for ri in cancel:
			intents.erase(ri)
			var u: UnitState = runs[ri]["unit"]
			if not bool(runs[ri]["blocked_noted"]):
				runs[ri]["blocked_noted"] = true
				events.append(CombatEvent.new(t1, CombatEvent.Phase.MOVEMENT, "%s has to wait (path blocked)" % u.display_name(), u))
	for ri in runs.size():
		var r: Dictionary = runs[ri]
		var u: UnitState = r["unit"]
		if u.is_bailed:
			u.moving = false
			continue
		if intents.has(ri):
			var me: Dictionary = intents[ri]
			var old := u.pos
			u.pos = me["pos"]
			u.level = me["level"]
			for key in me["state"]:
				r[key] = me["state"][key]
			for ev in me["events"]:
				events.append(ev)
			u.moving = old.distance_to(u.pos) > 0.0001
			if u.moving and not u.watching:
				_face(u, u.pos + (u.pos - old))
		else:
			u.moving = false
		if u.watching:
			_face(u, u.watch_point)


## Where `r`'s character would be after `dt` more seconds of its Movement
## lane: {pos, level, state} (state = run fields to commit), or {} when it
## stays put (idle, waiting, weighed down).
func _advance(r: Dictionary, dt: float, t1: float) -> Dictionary:
	var events: Array[CombatEvent] = []   # committed only if this step's move is
	var u: UnitState = r["unit"]
	var moves: Array = r["moves"]
	var move_i: int = r["move_i"]
	var seg_i: int = r["seg_i"]
	var seg_t: float = r["seg_t"]
	var wait_left: float = r["wait_left"]
	var started: bool = r["started"]
	var noted: bool = r["blocked_noted"]
	if u.weight_time > 0.0:
		return {}
	var pos := u.pos
	var level := u.level
	var budget := dt
	var moved := false
	var data := u.unit_data
	while budget > 1e-9 and move_i < moves.size():
		var e: Dictionary = moves[move_i]
		var a: PlanAction = e["action"]
		if not started:
			started = true
			noted = false
			if a.card.card_name == "Wait":
				wait_left = clampf(a.hold, TurnPlan.MIN_HOLD, TURN_SECONDS)
			elif not bool(e["ok"]):
				events.append(CombatEvent.new(t1, CombatEvent.Phase.MOVEMENT, "%s can't get there (move skipped)" % u.display_name(), u))
				move_i += 1
				started = false
				continue
			else:
				events.append(CombatEvent.new(t1, CombatEvent.Phase.MOVEMENT, _move_text(u, e), u))
		if a.card.card_name == "Wait":
			var use := minf(budget, wait_left)
			wait_left -= use
			budget -= use
			if wait_left <= 1e-9:
				move_i += 1
				started = false
			continue
		var segs: Array = e["segments"]
		if seg_i >= segs.size():
			move_i += 1
			seg_i = 0
			seg_t = 0.0
			started = false
			continue
		var s: Dictionary = segs[seg_i]
		var dur := TurnPlan.segment_time(s, data)
		var use := minf(budget, dur - seg_t)
		seg_t += use
		budget -= use
		var f := seg_t / maxf(dur, 0.0001)
		pos = (s["from"] as Vector2).lerp(s["to"], clampf(f, 0.0, 1.0))
		level = int(s["l0"])
		moved = true
		if seg_t >= dur - 1e-9:
			level = int(s["l1"])
			pos = s["to"]
			seg_i += 1
			seg_t = 0.0
	if not moved and move_i == int(r["move_i"]) and wait_left == float(r["wait_left"]) and started == bool(r["started"]):
		return {}
	return { "pos": pos, "level": level, "events": events, "state": { "move_i": move_i, "seg_i": seg_i,
		"seg_t": seg_t, "wait_left": wait_left, "started": started, "blocked_noted": noted } }


func _move_text(u: UnitState, e: Dictionary) -> String:
	var a: PlanAction = e["action"]
	var to_level := int(e["to_level"])
	var floors := _ms.geometry().floors_at(e["to_pos"])
	var where := ""
	if to_level > 0:
		where = " onto a roof" if to_level >= floors else " into a building (floor %d)" % to_level
	elif int(e["from_level"]) > 0:
		where = " down to the street"
	if a.card.jump:
		return "%s jumps (Grasshopper)%s" % [u.display_name(), where]
	return "%s moves%s" % [u.display_name(), where]


# --- 3. Defense ---------------------------------------------------------------

func _defense_phase(t: float) -> void:
	for r in _runs:
		var u: UnitState = r["unit"]
		var shield := false
		var guard_blade := false
		if not u.is_bailed:
			for e in r["acts"]:
				if t > float(e["start"]) + 1e-9 and t <= float(e["end"]) + 1e-9:
					var card: TriggerCard = (e["action"] as PlanAction).card
					if card.card_type == TriggerCard.CardType.SHIELD:
						shield = true
					elif card.guard:
						guard_blade = true
		u.shield_active = shield or guard_blade
		u.full_guard = shield and not u.moving


# --- 4. Attack ----------------------------------------------------------------

## Attacks finishing in (t0, t1], fired in a fixed order (finish time, team,
## index) against the same moment. Returns the hits to apply.
func _attack_phase(t0: float, t1: float, events: Array[CombatEvent]) -> Array:
	var shots: Array = []
	for r in _alive_runs():
		for k in _finishing(r, t0, t1):
			var e: Dictionary = r["acts"][k]
			if (e["action"] as PlanAction).is_attack():
				shots.append([float(e["end"]), int(r["team"]), int(r["index"]), r, k])
	shots.sort_custom(func(a: Array, b: Array) -> bool:
		if absf(float(a[0]) - float(b[0])) > 1e-9:
			return float(a[0]) < float(b[0])
		if int(a[1]) != int(b[1]):
			return int(a[1]) < int(b[1])
		return int(a[2]) < int(b[2]))
	var pending: Array = []
	for s in shots:
		var r: Dictionary = s[3]
		r["act_done"][s[4]] = true
		var a: PlanAction = r["acts"][s[4]]["action"]
		_resolve_attack(r["unit"], a, t1, events, pending)
	return pending


func _resolve_attack(attacker: UnitState, a: PlanAction, t: float, events: Array[CombatEvent], pending: Array) -> void:
	var card := a.card
	if attacker.stealth_active:
		attacker.stealth_active = false
		events.append(CombatEvent.new(t, CombatEvent.Phase.ATTACK, "%s reveals itself attacking" % attacker.display_name(), attacker))
	var enemies: Array = _ms.teams[1 - attacker.team]
	var target: UnitState = enemies[a.target_unit] if a.target_unit >= 0 and a.target_unit < enemies.size() else null
	if target == null or target.is_bailed:
		events.append(CombatEvent.new(t, CombatEvent.Phase.ATTACK, "%s's %s finds no target" % [attacker.display_name(), card.card_name], attacker))
		return
	if not _can_hit(attacker, card, target):
		# Says nothing about where the target is (the target isn't attached,
		# so the other side doesn't see this either).
		events.append(CombatEvent.new(t, CombatEvent.Phase.ATTACK, "%s has no shot at %s with %s" % [attacker.display_name(), target.display_name(), card.card_name], attacker))
		return
	_face(attacker, target.pos)
	if not always_hit and _ms.rng.randf() > hit_chance(attacker, target, card):
		events.append(CombatEvent.new(t, CombatEvent.Phase.ATTACK, "%s misses %s" % [attacker.display_name(), target.display_name()], attacker, target))
		return
	if card.effect == "weight":
		pending.append({ "target": target, "damage": 0, "effect": "weight" })
		events.append(CombatEvent.new(t, CombatEvent.Phase.ATTACK, "%s tags %s with Lead Bullet" % [attacker.display_name(), target.display_name()], attacker, target))
		return
	var raw := float(attacker.unit_data.attack_rating + card.power)
	var mitigation := _mitigation(target, attacker.pos, card)
	var damage := maxi(0, roundi(raw - mitigation))
	pending.append({ "target": target, "damage": damage, "effect": "" })
	events.append(CombatEvent.new(t, CombatEvent.Phase.ATTACK, "%s hits %s with %s for %d (mitigated %.1f)" % [attacker.display_name(), target.display_name(), card.card_name, damage, mitigation], attacker, target, damage))


## Whether `attacker` can land `card` on `target` right now: in reach, the
## team sees the target, and a clear line (curved shots go around).
func _can_hit(attacker: UnitState, card: TriggerCard, target: UnitState) -> bool:
	var dist := attacker.pos.distance_to(target.pos)
	if card.card_type == TriggerCard.CardType.MELEE:
		return dist <= MELEE_RANGE and target.level == attacker.level
	if dist > card.attack_range:
		return false
	if not Visibility.spotted(_ms, attacker.team, target):
		return false
	return card.curved or Visibility.has_los(_ms, attacker.pos, attacker.level, target.pos, target.level)


## Hit chance (0..1) of `card` from `attacker` on `target` right now.
func hit_chance(attacker: UnitState, target: UnitState, card: TriggerCard) -> float:
	var melee := card.card_type == TriggerCard.CardType.MELEE
	var base := (BASE_MELEE_HIT if melee else BASE_RANGED_HIT) + card.accuracy_bonus
	if not melee and attacker.moving:
		base -= MOVING_SHOOTER_PENALTY
	if target.weight_time > 0.0:
		return clampf(base, 0.05, 0.98)  # weighed down: can't dodge
	var evasion := target.unit_data.mobility_rating * EVASION_PER_MOBILITY
	if _ms.on_team_wire(target.pos, target.level, target.team):
		evasion += WIRE_EVADE_BONUS
	if not melee and target.moving and not card.homing:
		evasion += MOVING_TARGET_EVADE
	return clampf(base - evasion, 0.05, 0.98)


func _mitigation(target: UnitState, from: Vector2, card: TriggerCard) -> float:
	var defense := float(target.unit_data.defense_rating)
	if _ms.on_team_wire(target.pos, target.level, target.team):
		defense *= 1.0 + WIRE_DEF_BONUS
	if target.full_guard:
		var guard := defense * FULL_GUARD_DEF_MULT
		return guard * 0.5 if card.piercing else guard
	if card.piercing or card.flexible or not target.shield_active:
		return 0.0
	return defense if in_shield_arc(target, from) else 0.0


## Whether a hit coming from `from` meets `target`'s shield (its front half).
static func in_shield_arc(target: UnitState, from: Vector2) -> bool:
	var to := from - target.pos
	if to.length() < 0.0001:
		return true
	return rad_to_deg(absf(target.forward().angle_to(to))) <= SHIELD_HALF_ARC_DEG


# --- 5. Resolution ------------------------------------------------------------

func _resolution_phase(pending: Array, t: float, events: Array[CombatEvent]) -> void:
	for p in pending:
		var target: UnitState = p["target"]
		if target.is_bailed:
			continue
		if str(p.get("effect", "")) == "weight":
			target.weight_time = WEIGHT_SECONDS
			events.append(CombatEvent.new(t, CombatEvent.Phase.RESOLUTION, "%s is weighed down — can't move or dodge for %.0f s" % [target.display_name(), WEIGHT_SECONDS], target, target))
			continue
		var damage: int = p["damage"]
		target.trion_hp = maxi(0, target.trion_hp - damage)
		if target.trion_hp <= 0:
			target.is_bailed = true
			target.moving = false
			target.shield_active = false
			target.full_guard = false
			events.append(CombatEvent.new(t, CombatEvent.Phase.RESOLUTION, "%s bails out after %d damage (Trion 0)" % [target.display_name(), damage], target, target, damage))
		else:
			events.append(CombatEvent.new(t, CombatEvent.Phase.RESOLUTION, "%s takes %d damage (Trion %d/%d)" % [target.display_name(), damage, target.trion_hp, target.unit_data.base_trion_hp], target, target, damage))
