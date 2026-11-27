class_name TurnPlan
extends RefCounted
## One turn's plan for a squad: every character gets TURN_SECONDS of time and
## two lanes that run side by side:
##   Movement lane   Move, Jump (Grasshopper), Wait   (where it goes)
##   Action lane     attacks, Shield, Look, Bagworm, Spider, Wait (what it does)
## Each lane is a sequence: an action starts when the one before it ends, and
## the whole lane must fit in the turn. Stamina (UnitData.tempo) makes every
## action shorter and movement faster, so a fitter character does more.
##
## Move durations depend on the map (the route around buildings), so the
## Movement lane is timed against a MatchState (move_schedule); the Action
## lane needs only the character (act_schedule).

const TURN_SECONDS := 6.0
const MOVE_LANE := 0
const ACT_LANE := 1
const MAX_ACTIONS := 16
const MIN_HOLD := 0.25
const DEFAULT_WAIT := 1.0
const DEFAULT_SHIELD_HOLD := 1.5
## Walking speed in metres per second at tempo 1.
const BASE_SPEED := 2.5
## Melee Penchant: a blade in a Main slot makes the character this much faster on foot.
const MELEE_SPEED_BONUS := 0.1
## Slack for float rounding when checking that a lane fits the turn.
const TIME_EPSILON := 0.005

var units: Array[UnitData] = []
var _lanes: Array = []   # [unit] -> [Array[PlanAction] (move), Array[PlanAction] (act)]


func _init(unit_list: Array[UnitData] = []) -> void:
	units = unit_list.duplicate()
	for _u in units:
		var move: Array[PlanAction] = []
		var act: Array[PlanAction] = []
		_lanes.append([move, act])


# --- Editing --------------------------------------------------------------------

func lane(unit: int, lane_id: int) -> Array[PlanAction]:
	return _lanes[unit][lane_id]


## Appends `a` to its lane (or `lane_id`). False when the lane is full.
func add(unit: int, a: PlanAction, lane_id: int = -1) -> bool:
	if lane_id == -1:
		lane_id = lane_for(a.card)
	var l := lane(unit, lane_id)
	if l.size() >= MAX_ACTIONS:
		return false
	l.append(a)
	return true


func remove(unit: int, lane_id: int, index: int) -> bool:
	var l := lane(unit, lane_id)
	if index < 0 or index >= l.size():
		return false
	l.remove_at(index)
	return true


func clear_unit(unit: int) -> void:
	lane(unit, MOVE_LANE).clear()
	lane(unit, ACT_LANE).clear()


## The lane a card goes in by default (Wait can go in either).
static func lane_for(card: TriggerCard) -> int:
	return MOVE_LANE if is_move_card(card) else ACT_LANE


static func is_move_card(card: TriggerCard) -> bool:
	return card != null and (card.card_type == TriggerCard.CardType.MOVE or card.jump)


## Whether `card` may go in `lane_id` (Wait fits both).
static func fits_lane(card: TriggerCard, lane_id: int) -> bool:
	if card == null:
		return false
	if card.card_name == "Wait":
		return true
	return lane_for(card) == lane_id


## The character's actions: Move, Look, Wait, plus one per equipped trigger.
func get_available_actions(unit: int) -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	var seen := {}
	for basic in [TriggerLibrary.get_move_card(), TriggerLibrary.get_look_card(), TriggerLibrary.get_wait_card()]:
		result.append(basic)
		seen[basic.card_name] = true
	var u := units[unit]
	for slots in [u.main_trigger_slots, u.sub_trigger_slots]:
		for card in slots:
			if card != null and not seen.has(card.card_name):
				seen[card.card_name] = true
				result.append(card)
	return result


# --- Timing ---------------------------------------------------------------------

## Walking speed of a character in metres per second.
static func speed(data: UnitData) -> float:
	var s := BASE_SPEED * data.tempo
	for card in data.main_trigger_slots:
		if card != null and card.card_type == TriggerCard.CardType.MELEE:
			return s * (1.0 + MELEE_SPEED_BONUS)
	return s


## Seconds an Action-lane action (or a Wait) takes for this character.
static func action_time(data: UnitData, a: PlanAction) -> float:
	if a.uses_hold():
		return clampf(a.hold, MIN_HOLD, TURN_SECONDS)
	return a.card.action_time / data.tempo


## Action lane timing: [{action, start, end}].
func act_schedule(unit: int) -> Array:
	var out: Array = []
	var t := 0.0
	for a in lane(unit, ACT_LANE):
		var d := action_time(units[unit], a)
		out.append({ "action": a, "start": t, "end": t + d })
		t += d
	return out


func act_used(unit: int) -> float:
	var s := act_schedule(unit)
	return 0.0 if s.is_empty() else float(s.back()["end"])


## Movement lane timing from where `us` stands at the start of the turn:
## [{action, start, end, ok, segments, from_pos, from_level, to_pos, to_level}].
## A route that can't be walked has ok = false (and takes no time).
func move_schedule(ms: MatchState, us: UnitState, unit: int) -> Array:
	var geo := ms.geometry()
	var data := units[unit]
	var spd := speed(data)
	var out: Array = []
	var t := 0.0
	var p := us.pos
	var lvl := us.level
	for a in lane(unit, MOVE_LANE):
		var e := { "action": a, "start": t, "ok": true, "segments": [], "from_pos": p, "from_level": lvl,
			"to_pos": p, "to_level": lvl }
		var d := 0.0
		if a.card.card_name == "Wait":
			d = clampf(a.hold, MIN_HOLD, TURN_SECONDS)
		elif not a.has_point:
			e["ok"] = false
		else:
			var r := geo.jump_route(p, lvl, a.point, a.level) if a.card.jump else geo.route(p, lvl, a.point, a.level)
			if not bool(r["ok"]):
				e["ok"] = false
			else:
				e["segments"] = r["segments"]
				var cost := CityGeometry.route_cost(r["segments"])
				d = float(cost["walk"]) / spd + float(cost["fixed"]) / data.tempo
				p = a.point
				lvl = a.level
				e["to_pos"] = p
				e["to_level"] = lvl
		t += d
		e["end"] = t
		out.append(e)
	return out


func move_used(ms: MatchState, us: UnitState, unit: int) -> float:
	var s := move_schedule(ms, us, unit)
	return 0.0 if s.is_empty() else float(s.back()["end"])


## Where the plan puts a character at time `t` (ignoring other characters):
## {pos, level, moving_dir (Vector2, zero when still)}.
static func position_at(schedule: Array, us: UnitState, t: float, data: UnitData) -> Dictionary:
	var p := us.pos
	var lvl := us.level
	for e in schedule:
		if not bool(e["ok"]):
			continue
		if t <= float(e["start"]):
			break
		var local := t - float(e["start"])
		var segs: Array = e["segments"]
		if t >= float(e["end"]) or segs.is_empty():
			p = e["to_pos"]
			lvl = e["to_level"]
			continue
		for s in segs:
			var dur := segment_time(s, data)
			if local <= dur:
				var f := local / maxf(dur, 0.0001)
				var at: Vector2 = (s["from"] as Vector2).lerp(s["to"], f)
				var dir: Vector2 = (s["to"] as Vector2) - (s["from"] as Vector2)
				return { "pos": at, "level": CityGeometry.segment_level(s, f),
					"moving_dir": dir.normalized() if dir.length() > 0.001 else Vector2.ZERO }
			local -= dur
		p = e["to_pos"]
		lvl = e["to_level"]
	return { "pos": p, "level": lvl, "moving_dir": Vector2.ZERO }


static func segment_time(s: Dictionary, data: UnitData) -> float:
	if float(s["fixed"]) > 0.0:
		return float(s["fixed"]) / data.tempo
	return (s["from"] as Vector2).distance_to(s["to"]) / speed(data)


# --- Validation -----------------------------------------------------------------

## Problems with one character's plan ("" when it is fine): every action
## targeted, every route walkable, both lanes inside the turn.
func unit_error(ms: MatchState, us: UnitState, unit: int) -> String:
	for lane_id in [MOVE_LANE, ACT_LANE]:
		for a in lane(unit, lane_id):
			if a.needs_target():
				return "%s has no target" % a.card.card_name
	for e in move_schedule(ms, us, unit):
		if not bool(e["ok"]):
			return "%s can't reach that spot" % (e["action"] as PlanAction).card.card_name
	if move_used(ms, us, unit) > TURN_SECONDS + TIME_EPSILON:
		return "movement takes longer than %.0f s" % TURN_SECONDS
	if act_used(unit) > TURN_SECONDS + TIME_EPSILON:
		return "actions take longer than %.0f s" % TURN_SECONDS
	return ""


## The first thing that keeps a character's plan from being submitted:
## {lane, index, text} pointing at the block to fix, or {} when it's fine.
func unit_problem(ms: MatchState, us: UnitState, unit: int) -> Dictionary:
	for lane_id in [MOVE_LANE, ACT_LANE]:
		var l := lane(unit, lane_id)
		for k in l.size():
			if l[k].needs_target():
				return { "lane": lane_id, "index": k, "text": "%s has no target" % _label(l[k].card) }
	var sched := move_schedule(ms, us, unit)
	for k in sched.size():
		if not bool(sched[k]["ok"]):
			return { "lane": MOVE_LANE, "index": k, "text": "%s can't reach that spot" % _label(sched[k]["action"].card) }
	if not sched.is_empty() and float(sched.back()["end"]) > TURN_SECONDS + TIME_EPSILON:
		return { "lane": MOVE_LANE, "index": sched.size() - 1, "text": "movement runs past %.0f s" % TURN_SECONDS }
	if act_used(unit) > TURN_SECONDS + TIME_EPSILON:
		return { "lane": ACT_LANE, "index": lane(unit, ACT_LANE).size() - 1, "text": "actions run past %.0f s" % TURN_SECONDS }
	return {}


static func _label(card: TriggerCard) -> String:
	return "Jump" if card.jump else card.card_name


## Makes the plan submittable as it stands: drops actions that were never
## aimed or can't be walked, then trims each lane from the end until it fits
## the turn. What the player did finish still happens. Returns how many
## actions were dropped.
func sanitize(ms: MatchState, states: Array) -> int:
	var dropped := 0
	for i in units.size():
		var us: UnitState = states[i]
		for lane_id in [MOVE_LANE, ACT_LANE]:
			var l := lane(i, lane_id)
			for k in range(l.size() - 1, -1, -1):
				if l[k].needs_target():
					l.remove_at(k)
					dropped += 1
		# Removing a move changes where the next one starts: re-check until clean.
		var clean := false
		while not clean:
			clean = true
			var sched := move_schedule(ms, us, i)
			for k in sched.size():
				if not bool(sched[k]["ok"]):
					remove(i, MOVE_LANE, k)
					dropped += 1
					clean = false
					break
		while move_used(ms, us, i) > TURN_SECONDS + TIME_EPSILON:
			remove(i, MOVE_LANE, lane(i, MOVE_LANE).size() - 1)
			dropped += 1
		while act_used(i) > TURN_SECONDS + TIME_EPSILON:
			remove(i, ACT_LANE, lane(i, ACT_LANE).size() - 1)
			dropped += 1
	return dropped


func is_unit_valid(ms: MatchState, us: UnitState, unit: int) -> bool:
	return unit_error(ms, us, unit) == ""


## Every character's plan is valid (bailed-out characters are skipped).
func is_all_valid(ms: MatchState, states: Array) -> bool:
	for i in units.size():
		var us: UnitState = states[i]
		if not us.is_bailed and not is_unit_valid(ms, us, i):
			return false
	return true
