class_name TickEngine
extends RefCounted
## Deterministic 6-tick resolution engine (GDD section 8.2).
##
## Sub-phase priority per tick:
##   1. State & Priority  — Bagworm (stealth) toggles
##   2. Traps & Movement  — Spider wire deploys, hex position shifts
##   3. Defense           — Shield / Full Guard positioning
##   4. Attack & Projectile — melee strikes, ranged trajectories
##   5. Resolution        — hit/evasion rolls, Trion deduction, bail-outs
##
## All randomness flows through MatchState.rng (seeded) for replayable results.

const BASE_RANGED_HIT := 0.9
const BASE_MELEE_HIT := 0.95
const EVASION_PER_MOBILITY := 0.02
const STEALTH_REVEAL_RANGE := 3
const FULL_GUARD_DEF_MULT := 1.5
const WIRE_DEF_BONUS := 0.2
const WIRE_EVADE_BONUS := 0.1
const DEFAULT_RANGED_RANGE := 5

## Test hook: when true, skip hit rolls so every valid attack lands.
var always_hit := false


func resolve(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan) -> Array[CombatEvent]:
	var events: Array[CombatEvent] = []
	for tick in TurnPlan.TICKS_PER_TURN:
		events.append_array(resolve_tick(ms, plan0, plan1, tick))
	return events


## Resolves a single tick (used by the replay controller to step through turns).
func resolve_tick(ms: MatchState, plan0: TurnPlan, plan1: TurnPlan, tick: int) -> Array[CombatEvent]:
	var events: Array[CombatEvent] = []
	_resolve_tick(ms, [plan0, plan1], tick, events)
	return events


## Non-mutating preview of an attack's outcome for the planning UI.
## `attacker_hex` lets callers pass a projected position (movement happens
## before attacks within a tick). Returns hit chance (0..1), base power, and
## range/cover flags.
func preview_attack(ms: MatchState, attacker: UnitState, attacker_hex: Vector2i, card: TriggerCard, target: UnitState, attacker_floor: int = 0) -> Dictionary:
	var out := { "range_ok": false, "blocked": false, "half_cover": false, "hit_chance": 0.0, "power": 0 }
	if card == null or target == null:
		return out

	var dist := HexCoord.distance(attacker_hex, target.hex)
	out["power"] = attacker.unit_data.attack_rating + card.power

	if card.card_type == TriggerCard.CardType.MELEE:
		out["range_ok"] = dist == 1 and target.floor == attacker_floor
	else:
		out["range_ok"] = dist <= DEFAULT_RANGED_RANGE
		if out["range_ok"] and card.card_name != "Viper":
			out["blocked"] = _line_blocked_by_full_cover(ms, attacker_hex, target.hex)
		out["half_cover"] = _has_half_cover(ms, attacker_hex, target.hex)

	var base := BASE_MELEE_HIT if card.card_type == TriggerCard.CardType.MELEE else BASE_RANGED_HIT
	var evasion := target.unit_data.mobility_rating * EVASION_PER_MOBILITY
	if _on_wire(ms, target.hex):
		evasion += WIRE_EVADE_BONUS
	out["hit_chance"] = clampf(base - evasion, 0.05, 0.98)
	return out


# --- Tick Pipeline ----------------------------------------------------------

func _resolve_tick(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	_state_phase(ms, plans, tick, events)
	_movement_phase(ms, plans, tick, events)
	_defense_phase(ms, plans, tick, events)
	var pending := _attack_phase(ms, plans, tick, events)
	_resolution_phase(ms, pending, tick, events)


## Returns rows [team, unit_index, UnitState, TickAction] for non-bailed units.
func _iter_active(ms: MatchState, plans: Array, tick: int) -> Array:
	var rows: Array = []
	for team in ms.teams.size():
		for i in ms.teams[team].size():
			var u: UnitState = ms.teams[team][i]
			if u.is_bailed:
				continue
			var ta: TickAction = plans[team].get_tick(i, tick)
			rows.append([team, i, u, ta])
	return rows


# --- 1. State & Priority ----------------------------------------------------

func _state_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		var has_bagworm := _card_is(ta.main_card, TriggerCard.CardType.STEALTH) or _card_is(ta.sub_card, TriggerCard.CardType.STEALTH)
		u.stealth_active = has_bagworm
		if has_bagworm:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.STATE, "%s activates Bagworm (stealth)" % u.display_name(), u))


# --- 2. Traps & Movement ----------------------------------------------------

func _movement_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	# Spider wire deployments (traps) resolve first.
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		if _is_spider(ta.main_card) and ta.has_target:
			_deploy_wire(ms, u, ta.target_hex, tick, events)
		if _is_spider(ta.sub_card) and ta.has_target:
			_deploy_wire(ms, u, ta.target_hex, tick, events)

	# Then position shifts (movement), resolved simultaneously.
	var intents: Array = []  # [UnitState, target cell Vector3i(q, r, floor)]
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		if not ta.has_target or not (is_move_card(ta.main_card) or is_move_card(ta.sub_card)):
			continue
		if ta.target_hex == u.hex and ta.target_floor == u.floor:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s holds position" % u.display_name(), u))
		elif not is_valid_move(ms, u.hex, u.floor, ta.target_hex, ta.target_floor):
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s move skipped (%s f%d unreachable)" % [u.display_name(), str(ta.target_hex), ta.target_floor], u))
		else:
			intents.append([u, _cell(ta.target_hex, ta.target_floor)])
	_resolve_moves(ms, intents, tick, events)


func _deploy_wire(ms: MatchState, u: UnitState, target: Vector2i, tick: int, events: Array[CombatEvent]) -> void:
	ms.wires[target] = true
	events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s deploys Spider wire at %s" % [u.display_name(), str(target)], u))


## A board position including elevation: (q, r, floor).
static func _cell(hex: Vector2i, floor: int) -> Vector3i:
	return Vector3i(hex.x, hex.y, floor)


## Applies all legal moves at once so neither team gets priority. Positions
## are (hex, floor) cells, so floors of one building are separate spaces.
##   - two or more units entering the same cell all bounce,
##   - two units swapping cells both bounce (no passing through each other),
##   - a unit entering a cell whose occupant stays put is blocked (cascading).
## Rotations of 3+ units vacating each other's cells are allowed.
func _resolve_moves(ms: MatchState, intents: Array, tick: int, events: Array[CombatEvent]) -> void:
	var target_count := {}
	for it in intents:
		target_count[it[1]] = int(target_count.get(it[1], 0)) + 1

	var pending: Array = []
	for it in intents:
		var u: UnitState = it[0]
		var target: Vector3i = it[1]
		if int(target_count[target]) > 1:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s move bounced (contested %s f%d)" % [u.display_name(), str(Vector2i(target.x, target.y)), target.z], u))
			continue
		var swapped := false
		for other in intents:
			var ou: UnitState = other[0]
			if ou != u and other[1] == _cell(u.hex, u.floor) and _cell(ou.hex, ou.floor) == target:
				swapped = true
				break
		if swapped:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s move bounced (collision)" % u.display_name(), u))
			continue
		pending.append(it)

	# Drop moves into cells whose occupant is not itself successfully leaving.
	var changed := true
	while changed:
		changed = false
		var movers := {}
		for it in pending:
			movers[it[0]] = true
		for i in range(pending.size() - 1, -1, -1):
			var u: UnitState = pending[i][0]
			var target: Vector3i = pending[i][1]
			var occupant := ms.get_unit_at(Vector2i(target.x, target.y), target.z)
			if occupant != null and not movers.has(occupant):
				events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s move blocked (hex occupied)" % u.display_name(), u))
				pending.remove_at(i)
				changed = true

	for it in pending:
		var u: UnitState = it[0]
		var target: Vector3i = it[1]
		var hex := Vector2i(target.x, target.y)
		var dir := HexCoord.direction_to(u.hex, hex)
		u.hex = hex
		u.floor = target.z
		if dir != -1:
			u.facing = dir
		var where := "ground" if target.z == 0 else "floor %d" % target.z
		events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s moves to %s (%s)" % [u.display_name(), str(hex), where], u))


## Whether (from_hex, from_floor) -> (to_hex, to_floor) is a legal single
## move action: one hex horizontally (same floor), one floor vertically (same
## building), or entering/exiting a building (ground <-> floor 1). Occupancy
## is checked by the caller.
static func is_valid_move(ms: MatchState, from_hex: Vector2i, from_floor: int, to_hex: Vector2i, to_floor: int) -> bool:
	if to_floor < 0:
		return false
	var d_hex := HexCoord.distance(from_hex, to_hex)
	var d_floor := absi(to_floor - from_floor)
	if d_hex == 0:
		# Vertical move within the same building (up or down one floor).
		return d_floor == 1 and ms.floor_legal(to_hex, to_floor)
	if d_hex == 1:
		if d_floor == 0:
			# Horizontal move on the same floor (ground or equal-height roofs).
			return ms.floor_legal(to_hex, to_floor)
		if d_floor == 1:
			# Enter a building (ground -> floor 1) or exit it onto open ground
			# (floor 1 -> ground).
			return (from_floor == 0 and to_floor == 1 and ms.building_floors(to_hex) >= 1) 				or (from_floor == 1 and to_floor == 0 and ms.building_floors(from_hex) >= 1 and ms.floor_legal(to_hex, 0))
	return false


# --- 3. Defense -------------------------------------------------------------

func _defense_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		var main_shield := _card_is(ta.main_card, TriggerCard.CardType.SHIELD)
		var sub_shield := _card_is(ta.sub_card, TriggerCard.CardType.SHIELD)
		u.shield_active = main_shield or sub_shield
		u.full_guard = main_shield and sub_shield
		if u.full_guard:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.DEFENSE, "%s assumes Full Guard" % u.display_name(), u))


# --- 4. Attack & Projectile -------------------------------------------------

func _attack_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> Array:
	var pending: Array = []  # [{ "target": UnitState, "damage": int }]

	var attacker_rows: Array = []
	for row in _iter_active(ms, plans, tick):
		var ta: TickAction = row[3]
		if _is_offensive(ta.main_card) or _is_offensive(ta.sub_card):
			attacker_rows.append(row)

	attacker_rows.sort_custom(_compare_attackers)

	for row in attacker_rows:
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		if _is_offensive(ta.main_card) and ta.has_target:
			_resolve_attack(ms, u, ta.main_card, ta.target_hex, tick, events, pending)
		if _is_offensive(ta.sub_card) and ta.has_target:
			_resolve_attack(ms, u, ta.sub_card, ta.target_hex, tick, events, pending)

	return pending


## Higher mobility acts first; ties break by team then unit index.
func _compare_attackers(a: Array, b: Array) -> bool:
	var ua: UnitState = a[2]
	var ub: UnitState = b[2]
	if ua.unit_data.mobility_rating != ub.unit_data.mobility_rating:
		return ua.unit_data.mobility_rating > ub.unit_data.mobility_rating
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	return int(a[1]) < int(b[1])


func _resolve_attack(ms: MatchState, attacker: UnitState, card: TriggerCard, target_hex: Vector2i, tick: int, events: Array[CombatEvent], pending: Array) -> void:
	if attacker.stealth_active:
		attacker.stealth_active = false
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s reveals itself attacking" % attacker.display_name(), attacker))

	var target := ms.get_unit_at_any_floor(target_hex)
	if target == null:
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s attacks %s but no target present" % [attacker.display_name(), str(target_hex)], attacker))
		return
	if target.team == attacker.team:
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s skips friendly fire on %s" % [attacker.display_name(), target.display_name()], attacker, target))
		return

	var dist := HexCoord.distance(attacker.hex, target.hex)

	# Stealth concealment: cannot be targeted beyond the reveal range.
	if target.stealth_active and dist > STEALTH_REVEAL_RANGE:
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s cannot find %s (stealth)" % [attacker.display_name(), target.display_name()], attacker, target))
		return

	# Range check.
	if card.card_type == TriggerCard.CardType.MELEE:
		if dist != 1 or target.floor != attacker.floor:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s melee out of range on %s" % [attacker.display_name(), target.display_name()], attacker, target))
			return
	else:
		if dist > DEFAULT_RANGED_RANGE:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s ranged out of range on %s" % [attacker.display_name(), target.display_name()], attacker, target))
			return
		if card.card_name != "Viper" and _line_blocked_by_full_cover(ms, attacker.hex, target.hex):
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s shot blocked by full cover" % attacker.display_name(), attacker, target))
			return

	# Hit / evasion roll.
	if not always_hit:
		var hit_chance := _hit_chance(target, card, ms)
		var roll := ms.rng.randf()
		if roll > hit_chance:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s misses %s" % [attacker.display_name(), target.display_name()], attacker, target))
			return

	# Damage + mitigation (applied later in the Resolution phase).
	var raw := float(attacker.unit_data.attack_rating + card.power)
	if card.card_type == TriggerCard.CardType.RANGED and _has_half_cover(ms, attacker.hex, target.hex):
		raw *= 0.5

	var mitigation := _mitigation(ms, target, attacker.hex)
	var damage := maxi(0, roundi(raw - mitigation))
	pending.append({ "target": target, "damage": damage })
	events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s hits %s for %d (mitigated %.1f)" % [attacker.display_name(), target.display_name(), damage, mitigation], attacker, target, damage))


func _hit_chance(target: UnitState, card: TriggerCard, ms: MatchState) -> float:
	var base := BASE_MELEE_HIT if card.card_type == TriggerCard.CardType.MELEE else BASE_RANGED_HIT
	var evasion := target.unit_data.mobility_rating * EVASION_PER_MOBILITY
	if _on_wire(ms, target.hex):
		evasion += WIRE_EVADE_BONUS
	return clampf(base - evasion, 0.05, 0.98)


func _mitigation(ms: MatchState, target: UnitState, attacker_hex: Vector2i) -> float:
	var defense := float(target.unit_data.defense_rating)
	if _on_wire(ms, target.hex):
		defense *= 1.0 + WIRE_DEF_BONUS
	if target.full_guard:
		return defense * FULL_GUARD_DEF_MULT
	var dir := attack_direction(target.hex, attacker_hex)
	if dir == -1 or not _in_shielded_arcs(target.facing, dir):
		return 0.0  # flanked — bypass defense
	if target.shield_active:
		return defense
	return 0.0


## Edge of `target_hex` an attack from `attacker_hex` enters through: the
## direction of the first hex on the line from the target toward the attacker.
## Works at any range (not just adjacent). Returns -1 if the hexes coincide.
static func attack_direction(target_hex: Vector2i, attacker_hex: Vector2i) -> int:
	if target_hex == attacker_hex:
		return -1
	var path := HexCoord.line(target_hex, attacker_hex)
	return HexCoord.direction_to(target_hex, path[1])


## Shield covers the three front edges: facing-1, facing, facing+1.
func _in_shielded_arcs(facing: int, attack_dir: int) -> bool:
	var rel := posmod(attack_dir - facing, 6)
	return rel == 0 or rel == 1 or rel == 5


# --- 5. Resolution ----------------------------------------------------------

func _resolution_phase(ms: MatchState, pending: Array, tick: int, events: Array[CombatEvent]) -> void:
	for p in pending:
		var target: UnitState = p["target"]
		var damage: int = p["damage"]
		if target.is_bailed:
			continue
		target.trion_hp = maxi(0, target.trion_hp - damage)
		if target.trion_hp <= 0:
			target.is_bailed = true
			events.append(CombatEvent.new(tick, CombatEvent.Phase.RESOLUTION, "%s bails out after %d damage (Trion 0)" % [target.display_name(), damage], target, target, damage))
		else:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.RESOLUTION, "%s takes %d damage (Trion %d/%d)" % [target.display_name(), damage, target.trion_hp, target.unit_data.base_trion_hp], target, target, damage))


# --- Card Classification ----------------------------------------------------

func _card_is(card: TriggerCard, type: int) -> bool:
	return card != null and card.card_type == type


func _is_offensive(card: TriggerCard) -> bool:
	return card != null and (card.card_type == TriggerCard.CardType.MELEE or card.card_type == TriggerCard.CardType.RANGED)


static func is_move_card(card: TriggerCard) -> bool:
	return card != null and (card.card_type == TriggerCard.CardType.MOVE or card.card_name == "Grasshopper")


func _is_spider(card: TriggerCard) -> bool:
	return card != null and card.card_name == "Spider"


func _on_wire(ms: MatchState, hex: Vector2i) -> bool:
	return ms.wires.has(hex)


func _line_blocked_by_full_cover(ms: MatchState, a: Vector2i, b: Vector2i) -> bool:
	for hex in HexCoord.line(a, b):
		if hex == a or hex == b:
			continue
		if int(ms.cover.get(hex, 0)) >= 2:
			return true
	return false


func _has_half_cover(ms: MatchState, a: Vector2i, b: Vector2i) -> bool:
	for hex in HexCoord.line(a, b):
		if hex == a or hex == b:
			continue
		if int(ms.cover.get(hex, 0)) == 1:
			return true
	return false
