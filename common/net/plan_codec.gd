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
		"at_pool": u.base_at_pool,
		"mobility": u.mobility_rating,
		"attack": u.attack_rating,
		"defense": u.defense_rating,
		"trion_capacity": u.max_trion_capacity,
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
	u.base_trion_hp = int(d.get("trion_hp", 100))
	u.base_at_pool = int(d.get("at_pool", 8))
	u.mobility_rating = int(d.get("mobility", 5))
	u.attack_rating = int(d.get("attack", 5))
	u.defense_rating = int(d.get("defense", 5))
	u.max_trion_capacity = int(d.get("trion_capacity", 100))
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

static func encode_plan(plan: TurnPlan) -> Dictionary:
	var units: Array = []
	for u in plan.units.size():
		var ticks: Array = []
		for t in TurnPlan.TICKS_PER_TURN:
			var ta := plan.get_tick(u, t)
			ticks.append({
				"main": ta.main_card.card_name if ta.main_card != null else null,
				"sub": ta.sub_card.card_name if ta.sub_card != null else null,
				"target": [ta.target_hex.x, ta.target_hex.y] if ta.has_target else null,
				"target_floor": ta.target_floor,
				"sub_target": [ta.sub_target_hex.x, ta.sub_target_hex.y] if ta.sub_has_target else null,
				"sub_target_floor": ta.sub_target_floor,
			})
		units.append(ticks)
	return { "units": units }


static func decode_plan(d: Dictionary, units: Array[UnitData]) -> TurnPlan:
	var plan := TurnPlan.new(units)
	var rows: Array = d.get("units", [])
	for u in units.size():
		if u >= rows.size():
			continue
		var row: Array = rows[u]
		for t in TurnPlan.TICKS_PER_TURN:
			if t >= row.size():
				continue
			var tdata: Dictionary = row[t]
			var main_name: Variant = tdata.get("main")
			var sub_name: Variant = tdata.get("sub")
			if main_name != null:
				plan.assign(u, t, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card(str(main_name)))
			if sub_name != null:
				plan.assign(u, t, TurnPlan.SUB_SLOT, TriggerLibrary.get_card(str(sub_name)))
			for slot in [TurnPlan.MAIN_SLOT, TurnPlan.SUB_SLOT]:
				var prefix := "sub_" if slot == TurnPlan.SUB_SLOT else ""
				var target: Variant = tdata.get(prefix + "target")
				if target != null:
					plan.set_target(u, t, Vector2i(int(target[0]), int(target[1])), int(tdata.get(prefix + "target_floor", 0)), slot)
	return plan


# --- Server-side Validation -----------------------------------------------
# The server never trusts client payloads: squads must use standard stats and
# a legal loadout, and plans may only use cards the unit actually equips.
# Each validator returns "" when valid, otherwise a human-readable error.

const SQUAD_SIZE := 4


static func validate_squad(arr: Array) -> String:
	if arr.size() != SQUAD_SIZE:
		return "squad must have exactly %d units" % SQUAD_SIZE
	for i in arr.size():
		if not (arr[i] is Dictionary):
			return "unit %d: malformed" % i
		var err := _validate_unit(arr[i])
		if err != "":
			return "unit %d: %s" % [i, err]
	return ""


static func _validate_unit(d: Dictionary) -> String:
	var expected := {
		"trion_hp": TriggerLibrary.STANDARD_TRION_HP,
		"at_pool": TriggerLibrary.STANDARD_AT_POOL,
		"mobility": TriggerLibrary.STANDARD_RATING,
		"attack": TriggerLibrary.STANDARD_RATING,
		"defense": TriggerLibrary.STANDARD_RATING,
		"trion_capacity": TriggerLibrary.STANDARD_TRION_CAPACITY,
	}
	for key in expected:
		if d.has(key) and (not _is_number(d[key]) or int(d[key]) != int(expected[key])):
			return "non-standard %s" % key
	var main: Variant = d.get("main", [])
	var sub: Variant = d.get("sub", [])
	if not (main is Array) or not (sub is Array):
		return "malformed trigger slots"
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


static func _count_cards(names: Array) -> int:
	var n := 0
	for c in names:
		if c != null:
			n += 1
	return n


## Strict plan decode for the server. Returns {"plan": TurnPlan, "error": ""}.
## Rejects unknown cards, cards the unit has not equipped, slot-rule or AT
## overruns, and malformed targets (unlike decode_plan, which drops them).
static func decode_plan_checked(d: Dictionary, units: Array[UnitData]) -> Dictionary:
	var plan := TurnPlan.new(units)
	var rows: Variant = d.get("units", [])
	if not (rows is Array) or rows.size() != units.size():
		return { "plan": null, "error": "plan must have one row per unit" }
	for u in units.size():
		var allowed := {}
		for card in plan.get_available_actions(u):
			allowed[card.card_name] = true
		var row: Variant = rows[u]
		if not (row is Array) or row.size() > TurnPlan.TICKS_PER_TURN:
			return { "plan": null, "error": "unit %d: malformed timeline" % u }
		for t in row.size():
			if not (row[t] is Dictionary):
				return { "plan": null, "error": "unit %d tick %d: malformed" % [u, t] }
			var tdata: Dictionary = row[t]
			for slot in [TurnPlan.MAIN_SLOT, TurnPlan.SUB_SLOT]:
				var card_name: Variant = tdata.get("main" if slot == TurnPlan.MAIN_SLOT else "sub")
				if card_name == null:
					continue
				if not allowed.has(str(card_name)):
					return { "plan": null, "error": "unit %d tick %d: '%s' not equipped" % [u, t, str(card_name)] }
				if not plan.assign(u, t, slot, TriggerLibrary.get_card(str(card_name))):
					return { "plan": null, "error": "unit %d tick %d: '%s' breaks slot or AT rules" % [u, t, str(card_name)] }
			for slot in [TurnPlan.MAIN_SLOT, TurnPlan.SUB_SLOT]:
				var prefix := "sub_" if slot == TurnPlan.SUB_SLOT else ""
				var target: Variant = tdata.get(prefix + "target")
				if target == null:
					continue
				if not (target is Array) or target.size() != 2 or not _is_number(target[0]) or not _is_number(target[1]):
					return { "plan": null, "error": "unit %d tick %d: malformed target" % [u, t] }
				var target_floor: Variant = tdata.get(prefix + "target_floor", 0)
				if not _is_number(target_floor) or int(target_floor) < 0:
					return { "plan": null, "error": "unit %d tick %d: malformed target floor" % [u, t] }
				plan.set_target(u, t, Vector2i(int(target[0]), int(target[1])), int(target_floor), slot)
	return { "plan": plan, "error": "" }


# --- Match State Snapshots ------------------------------------------------
# Sent with every server result so clients can verify their local replay and
# resync (including the RNG) after a desync or a reconnect.

static func encode_state(ms: MatchState) -> Dictionary:
	var units: Array = []
	for u in ms.all_units():
		units.append({
			"hex": [u.hex.x, u.hex.y],
			"floor": u.floor,
			"facing": u.facing,
			"hp": u.trion_hp,
			"bailed": u.is_bailed,
			"stealth": u.stealth_active,
			"weight": u.weight_ticks,
		})
	var wires: Array = []
	for hex in ms.wires:
		wires.append([hex.x, hex.y, int(ms.wires[hex])])
	# RNG state is a 64-bit int; send it as a string so JSON doubles can't round it.
	return { "units": units, "wires": wires, "rng_state": str(ms.rng.state) }


static func apply_state(ms: MatchState, d: Dictionary) -> void:
	var units := ms.all_units()
	var rows: Array = d.get("units", [])
	for i in mini(units.size(), rows.size()):
		var u: UnitState = units[i]
		var row: Dictionary = rows[i]
		var hex: Array = row.get("hex", [u.hex.x, u.hex.y])
		u.hex = Vector2i(int(hex[0]), int(hex[1]))
		u.floor = int(row.get("floor", u.floor))
		u.facing = int(row.get("facing", u.facing))
		u.trion_hp = int(row.get("hp", u.trion_hp))
		u.is_bailed = bool(row.get("bailed", u.is_bailed))
		u.stealth_active = bool(row.get("stealth", u.stealth_active))
		u.weight_ticks = int(row.get("weight", 0))
	ms.wires.clear()
	for w in d.get("wires", []):
		ms.wires[Vector2i(int(w[0]), int(w[1]))] = int(w[2]) if w.size() > 2 else -1
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
			"tick": ev.tick,
			"phase": ev.phase,
			"message": ev.message,
			"actor": ev.actor.display_name() if ev.actor != null else null,
			"target": ev.target.display_name() if ev.target != null else null,
			"damage": ev.damage,
		})
	return out
