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
			var target: Variant = tdata.get("target")
			if target != null:
				plan.set_target(u, t, Vector2i(int(target[0]), int(target[1])), int(tdata.get("target_floor", 0)))
	return plan


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
