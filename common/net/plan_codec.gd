class_name PlanCodec
extends RefCounted
## JSON serialization for squads, turn plans, and match results. Card identity
## travels as card names so both client and server can resolve them against the
## shared TriggerLibrary catalog.


# --- Squads ---------------------------------------------------------------

static func encode_squad(units: Array[UnitData]) -> Array:
	var out: Array = []
	for u in units:
		out.append(encode_unit(u))
	return out


static func encode_unit(u: UnitData) -> Dictionary:
	return {
		"name": u.unit_name,
		"trion_hp": u.base_trion_hp,
		"mobility": u.mobility_rating,
		"attack": u.attack_rating,
		"defense": u.defense_rating,
		"trion_capacity": u.max_trion_capacity,
		"talents": { "stamina": u.talent_stamina, "hp": u.talent_hp, "atk": u.talent_atk },
		"main": _names(u.main_trigger_slots),
		"sub": _names(u.sub_trigger_slots),
	}


static func decode_squad(arr: Array) -> Array[UnitData]:
	var out: Array[UnitData] = []
	for entry in arr:
		out.append(decode_unit(entry as Dictionary))
	return out


static func decode_unit(d: Dictionary) -> UnitData:
	var u := UnitData.new()
	u.unit_name = str(d.get("name", "Unit"))
	# Stats come only from talents (validate_squad has checked them).
	var talents: Variant = d.get("talents", {})
	if talents is Dictionary:
		u.talent_stamina = clampi(_whole(talents.get("stamina", 0)), 0, Talents.MAX_PER_STAT)
		u.talent_hp = clampi(_whole(talents.get("hp", 0)), 0, Talents.MAX_PER_STAT)
		u.talent_atk = clampi(_whole(talents.get("atk", 0)), 0, Talents.MAX_PER_STAT)
	Talents.apply(u)
	u.main_trigger_slots = _cards(d.get("main", []))
	u.sub_trigger_slots = _cards(d.get("sub", []))
	u.ensure_slot_arrays()
	return u


static func _names(slots: Array) -> Array:
	var out: Array = []
	for i in slots.size():
		var c: TriggerCard = slots[i]
		out.append(c.card_name if c != null else null)
	return out


static func _cards(names: Array) -> Array[TriggerCard]:
	var out: Array[TriggerCard] = []
	for n in names:
		out.append(TriggerLibrary.get_card(str(n)) if n != null else null)
	return out


# --- Plans ----------------------------------------------------------------
# {"units": [{"move": [action...], "act": [action...]}, ...]}
# action: {"card": name, "to": [x, z], "level": n, "unit": i, "hold": seconds}
# ("to"/"level" for points, "unit" for attack targets, "hold" for Shield/Wait)

static func encode_plan(plan: TurnPlan) -> Dictionary:
	var units: Array = []
	for u in plan.units.size():
		var row := {}
		for lane_id in [TurnPlan.MOVE_LANE, TurnPlan.ACT_LANE]:
			var out: Array = []
			for a in plan.lane(u, lane_id):
				out.append(encode_action(a))
			row["move" if lane_id == TurnPlan.MOVE_LANE else "act"] = out
		units.append(row)
	return { "units": units }


static func encode_action(a: PlanAction) -> Dictionary:
	var d := { "card": a.card.card_name }
	if a.has_point:
		d["to"] = [a.point.x, a.point.y]
		d["level"] = a.level
	if a.target_unit >= 0:
		d["unit"] = a.target_unit
	if a.uses_hold():
		d["hold"] = snappedf(a.hold, 0.01)
	return d


## Lenient decode (server's own stored plans): unknown entries are dropped.
static func decode_plan(d: Dictionary, units: Array[UnitData]) -> TurnPlan:
	var plan := TurnPlan.new(units)
	var rows: Variant = d.get("units", [])
	if not (rows is Array):
		return plan
	for u in mini(units.size(), (rows as Array).size()):
		var row: Variant = rows[u]
		if not (row is Dictionary):
			continue
		for lane_id in [TurnPlan.MOVE_LANE, TurnPlan.ACT_LANE]:
			var list: Variant = row.get("move" if lane_id == TurnPlan.MOVE_LANE else "act", [])
			if not (list is Array):
				continue
			for item in list:
				if item is Dictionary:
					var a := _decode_action(item)
					if a != null:
						plan.add(u, a, lane_id)
	return plan


static func _decode_action(d: Dictionary) -> PlanAction:
	var name: Variant = d.get("card")
	if not (name is String):
		return null
	var card := TriggerLibrary.get_card(name)
	if card == null:
		return null
	var a := PlanAction.new(card)
	var to: Variant = d.get("to")
	if to is Array and (to as Array).size() == 2 and _is_number(to[0]) and _is_number(to[1]):
		a.set_point(Vector2(float(to[0]), float(to[1])), _whole(d.get("level", 0)))
	if _is_number(d.get("unit")):
		a.target_unit = int(d["unit"])
	if _is_number(d.get("hold")):
		a.hold = float(d["hold"])
	return a


# --- Server-side Validation -----------------------------------------------
# The server never trusts client payloads: squads must use standard stats and
# a legal loadout, and plans may only use cards the unit actually equips.
# Each validator returns "" when valid, otherwise a human-readable error.

const SQUAD_SIZE := 3
## Largest coordinate / floor accepted in a plan target. The map is 32x32;
## anything outside it is ignored by the engine, this only bounds the numbers.
const MAX_TARGET_COORD := 256
const MAX_TARGET_FLOOR := 16


static func validate_squad(arr: Array) -> String:
	if arr.size() != SQUAD_SIZE:
		return "squad must have exactly %d units" % SQUAD_SIZE
	var points := 0
	for i in arr.size():
		if not (arr[i] is Dictionary):
			return "unit %d: malformed" % i
		var err := _validate_unit(arr[i])
		if err != "":
			return "unit %d: %s" % [i, err]
		var t: Variant = arr[i].get("talents", {})
		for stat in Talents.STATS:
			points += _whole(t.get(stat, 0)) if t is Dictionary else 0
	if points > Talents.POINTS:
		return "squad spends %d talent points (max %d)" % [points, Talents.POINTS]
	return ""


## A JSON number as an int (non-numbers become 0; callers validate first).
static func _whole(v: Variant) -> int:
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT and is_finite(v) and absf(v) < 1.0e9:
		return int(v)
	return 0


static func _validate_unit(d: Dictionary) -> String:
	var talents: Variant = d.get("talents", {})
	if not (talents is Dictionary):
		return "malformed talents"
	for stat in Talents.STATS:
		var v: Variant = talents.get(stat, 0)
		if not _in_range(v, 0, Talents.MAX_PER_STAT):
			return "%s talent must be 0-%d" % [stat, Talents.MAX_PER_STAT]
	# Names are shown to the opponent: text only, short, no markup.
	if d.has("name"):
		if not (d["name"] is String) or not NameRules.is_clean(d["name"], NameRules.UNIT_NAME_MAX):
			return "name must be 1-%d plain characters" % NameRules.UNIT_NAME_MAX
		if not NameRules.is_allowed(d["name"]):
			return "name is not allowed"
	# Stats a client sends must be exactly what its talents give.
	var derived := UnitData.new()
	derived.talent_stamina = int(talents.get("stamina", 0))
	derived.talent_hp = int(talents.get("hp", 0))
	derived.talent_atk = int(talents.get("atk", 0))
	Talents.apply(derived)
	var expected := {
		"trion_hp": derived.base_trion_hp,
		"mobility": derived.mobility_rating,
		"attack": derived.attack_rating,
		"defense": derived.defense_rating,
		"trion_capacity": derived.max_trion_capacity,
	}
	for key in expected:
		if d.has(key) and (not _is_number(d[key]) or int(d[key]) != int(expected[key])):
			return "non-standard %s" % key
	var main: Variant = d.get("main", [])
	var sub: Variant = d.get("sub", [])
	if not (main is Array) or not (sub is Array):
		return "malformed trigger slots"
	if main.size() > UnitData.MAX_MAIN_SLOTS or sub.size() > UnitData.MAX_SUB_SLOTS:
		return "too many trigger slots"
	for slot_list in [main, sub]:
		for n in slot_list:
			if n != null and not (n is String):
				return "malformed trigger name"
	if _count_cards(main) > UnitData.MAX_MAIN_SLOTS or _count_cards(sub) > UnitData.MAX_SUB_SLOTS:
		return "too many triggers"
	var total := 0
	var slots: Array = [main, sub]
	for s in slots.size():
		for n in slots[s]:
			if n == null:
				continue
			var card := TriggerLibrary.get_card(str(n))
			if card == null or card.card_type == TriggerCard.CardType.MOVE or card.free_action:
				return "unknown trigger '%s'" % str(n)
			if s == 1 and not card.is_dual_slot_compatible:
				return "%s cannot be equipped in a sub slot" % card.card_name
			total += card.trion_equip_cost
	if total > TriggerLibrary.STANDARD_TRION_CAPACITY:
		return "loadout exceeds Trion budget (%d/%d)" % [total, TriggerLibrary.STANDARD_TRION_CAPACITY]
	return ""


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## A finite whole number within [lo, hi].
static func _in_range(v: Variant, lo: int, hi: int) -> bool:
	if typeof(v) == TYPE_INT:
		return v >= lo and v <= hi
	if typeof(v) == TYPE_FLOAT:
		return is_finite(v) and v >= lo and v <= hi and v == floorf(v)
	return false


static func _count_cards(names: Array) -> int:
	var n := 0
	for c in names:
		if c != null:
			n += 1
	return n


## Strict plan decode for the server. Returns {"plan": TurnPlan, "error": ""}.
## Checks every value a client could tamper with: only cards the character
## has (plus Move / Look / Wait), each in its own lane, sane numbers, targets
## on the map and in range, attack targets that exist, and both lanes inside
## the turn (timed against `ms` from where `states` stand right now).
static func decode_plan_checked(d: Dictionary, units: Array[UnitData], ms: MatchState = null, states: Array = []) -> Dictionary:
	var plan := TurnPlan.new(units)
	var rows: Variant = d.get("units", [])
	if not (rows is Array) or rows.size() != units.size():
		return _bad("plan must have one row per unit")
	var bounds := ms.bounds() if ms != null else Rect2(-MAX_TARGET_COORD, -MAX_TARGET_COORD, 2 * MAX_TARGET_COORD, 2 * MAX_TARGET_COORD)
	var enemies := PlanCodec.SQUAD_SIZE
	for u in units.size():
		var allowed := {}
		for card in plan.get_available_actions(u):
			allowed[card.card_name] = true
		var row: Variant = rows[u]
		if not (row is Dictionary):
			return _bad("unit %d: malformed" % u)
		for lane_id in [TurnPlan.MOVE_LANE, TurnPlan.ACT_LANE]:
			var key := "move" if lane_id == TurnPlan.MOVE_LANE else "act"
			var list: Variant = row.get(key, [])
			if not (list is Array) or (list as Array).size() > TurnPlan.MAX_ACTIONS:
				return _bad("unit %d: malformed %s lane" % [u, key])
			for i in (list as Array).size():
				var item: Variant = list[i]
				var where := "unit %d %s %d" % [u, key, i]
				if not (item is Dictionary):
					return _bad("%s: malformed" % where)
				var name: Variant = item.get("card")
				if not (name is String) or not allowed.has(name):
					return _bad("%s: '%s' not equipped" % [where, str(name)])
				var card := TriggerLibrary.get_card(name)
				if not TurnPlan.fits_lane(card, lane_id):
					return _bad("%s: %s doesn't go in this lane" % [where, card.card_name])
				var a := PlanAction.new(card)
				if item.has("to"):
					var to: Variant = item["to"]
					if not (to is Array) or to.size() != 2 or not _finite_number(to[0]) or not _finite_number(to[1]):
						return _bad("%s: malformed target" % where)
					var pt := Vector2(float(to[0]), float(to[1]))
					if not bounds.grow(1.0).has_point(pt):
						return _bad("%s: target off the map" % where)
					var lvl: Variant = item.get("level", 0)
					if not _in_range(lvl, 0, MAX_TARGET_FLOOR):
						return _bad("%s: malformed level" % where)
					a.set_point(pt, int(lvl))
				if item.has("unit"):
					if not _in_range(item["unit"], 0, enemies - 1):
						return _bad("%s: malformed target unit" % where)
					a.target_unit = int(item["unit"])
				# Attacks aim at an enemy (or auto-target); only a demolishing
				# trigger (Ibis) may aim at a spot instead, and not at both.
				if a.is_attack() and a.has_point and (not card.demolish or a.target_unit >= 0):
					return _bad("%s: %s can't aim at a spot" % [where, card.card_name])
				if a.uses_hold():
					var hold: Variant = item.get("hold", a.hold)
					if not _finite_number(hold) or float(hold) < TurnPlan.MIN_HOLD - 0.001 or float(hold) > TurnPlan.TURN_SECONDS + 0.001:
						return _bad("%s: malformed hold time" % where)
					a.hold = float(hold)
				if a.needs_target():
					return _bad("%s: %s has no target" % [where, card.card_name])
				plan.add(u, a, lane_id)
		if ms != null and u < states.size():
			var us: UnitState = states[u]
			if not us.is_bailed:
				var err := plan.unit_error(ms, us, u)
				if err != "":
					return _bad("unit %d: %s" % [u, err])
	return { "plan": plan, "error": "" }


static func _bad(msg: String) -> Dictionary:
	return { "plan": null, "error": msg }


static func _finite_number(v: Variant) -> bool:
	return (typeof(v) == TYPE_INT) or (typeof(v) == TYPE_FLOAT and is_finite(v) and absf(v) < 1.0e6)


# --- Match State Snapshots ------------------------------------------------
# Sent with every server result so clients can verify their local replay and
# resync (including the RNG) after a desync or a reconnect.

static func encode_state(ms: MatchState) -> Dictionary:
	var units: Array = []
	for u in ms.all_units():
		units.append({
			"pos": [u.pos.x, u.pos.y],
			"level": u.level,
			"facing": u.facing,
			"hp": u.trion_hp,
			"bailed": u.is_bailed,
			"stealth": u.stealth_active,
			"weight": u.weight_time,
		})
	var wires: Array = []
	for w in ms.wires:
		wires.append([(w["pos"] as Vector2).x, (w["pos"] as Vector2).y, int(w["team"])])
	# RNG state is a 64-bit int; send it as a string so JSON doubles can't round it.
	return { "units": units, "wires": wires, "destroyed": ms.destroyed_list(), "rng_state": str(ms.rng.state) }


static func apply_state(ms: MatchState, d: Dictionary) -> void:
	var units := ms.all_units()
	var rows: Array = d.get("units", [])
	for i in mini(units.size(), rows.size()):
		var u: UnitState = units[i]
		var row: Dictionary = rows[i]
		var pos: Array = row.get("pos", [u.pos.x, u.pos.y])
		u.pos = Vector2(float(pos[0]), float(pos[1]))
		u.level = int(row.get("level", u.level))
		u.facing = float(row.get("facing", u.facing))
		u.trion_hp = int(row.get("hp", u.trion_hp))
		u.is_bailed = bool(row.get("bailed", u.is_bailed))
		u.stealth_active = bool(row.get("stealth", u.stealth_active))
		u.weight_time = float(row.get("weight", 0.0))
	ms.wires.clear()
	for w in d.get("wires", []):
		if w is Array and w.size() >= 3:
			ms.wires.append({ "pos": Vector2(float(w[0]), float(w[1])), "team": int(w[2]) })
	ms.set_destroyed(d.get("destroyed", []))
	if d.has("rng_state"):
		ms.rng.state = str(d["rng_state"]).to_int()


## True when `ms` matches snapshot `d` (used to detect client/server desync).
## Round-trips the local state through JSON so int/float typing matches `d`.
static func state_matches(ms: MatchState, d: Dictionary) -> bool:
	var local: Variant = JSON.parse_string(JSON.stringify(encode_state(ms)))
	return JSON.stringify(local) == JSON.stringify(d)


# --- Results --------------------------------------------------------------

static func encode_events(events: Array[CombatEvent]) -> Array:
	var out: Array = []
	for ev in events:
		out.append({
			"time": snappedf(ev.time, 0.01),
			"phase": ev.phase,
			"message": ev.message,
			"actor": ev.actor.display_name() if ev.actor != null else null,
			"target": ev.target.display_name() if ev.target != null else null,
			"damage": ev.damage,
		})
	return out
