class_name TickEngine
extends RefCounted
## Deterministic 6-tick resolution engine (GDD section 8.2).
##
## Sub-phase priority per tick:
##   1. State & Priority  — Bagworm (stealth) toggles
##   2. Traps & Movement  — Spider wire deploys, hex position shifts
##   3. Defense           — Shield / Full Guard / Raygust positioning
##   4. Attack & Projectile — melee strikes, ranged trajectories, combo assists
##   5. Resolution        — hit/evasion rolls, Trion deduction, bail-outs
##
## Trigger traits (TriggerCard): range, homing, curved, piercing, flexible,
## guard, jump, and Lead Bullet's weight effect. GDD 5.3 combos: Melee Assist
## and Crossfire Assist. Wire Mobility Penchant: units on their own team's
## Spider wires gain defense, evasion, and a 2-hex wire dash.
##
## All randomness flows through MatchState.rng (seeded) for replayable results.

const BASE_RANGED_HIT := 0.9
const BASE_MELEE_HIT := 0.95
const EVASION_PER_MOBILITY := 0.02
const STEALTH_REVEAL_RANGE := 3
const FULL_GUARD_DEF_MULT := 1.5
const WIRE_DEF_BONUS := 0.2
const WIRE_EVADE_BONUS := 0.1
const WEIGHT_TICKS := 6
const JUMP_RANGE := 2
const WIRE_DASH_RANGE := 2

## Test hook: when true, skip hit rolls so every valid attack lands.
var always_hit := false

# Crossfire Assist spends a unit's unspent AT; tracked per turn.
var _assist_spent: Dictionary = {}   # UnitState -> AT spent on assists


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
	var out := { "range_ok": false, "blocked": false, "half_cover": false, "hit_chance": 0.0, "power": 0, "piercing": false }
	if card == null or target == null:
		return out

	var dist := HexCoord.distance(attacker_hex, target.hex)
	out["power"] = attacker.unit_data.attack_rating + card.power
	out["piercing"] = card.piercing

	if card.card_type == TriggerCard.CardType.MELEE:
		out["range_ok"] = dist == 1 and target.floor == attacker_floor
	else:
		out["range_ok"] = dist <= card.attack_range
		if out["range_ok"] and not card.curved:
			out["blocked"] = not Visibility.has_los(ms, attacker_hex, attacker_floor, target.hex, target.floor)
		out["half_cover"] = _ignores_half_cover(card) == false and _has_half_cover(ms, attacker_hex, target.hex)
	out["hit_chance"] = _hit_chance(ms, target, card)
	return out


# --- Tick Pipeline ----------------------------------------------------------

func _resolve_tick(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	if tick == 0:
		_assist_spent.clear()
	_state_phase(ms, plans, tick, events)
	_movement_phase(ms, plans, tick, events)
	_defense_phase(ms, plans, tick, events)
	var pending := _attack_phase(ms, plans, tick, events)
	_resolution_phase(ms, pending, tick, events)
	for u in ms.all_units():
		if u.weight_ticks > 0:
			u.weight_ticks -= 1


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

## Bagworm is a toggle maintained per turn (GDD 5.2): stealth drops at the
## start of each turn, and a Bagworm card switches it ON from that tick until
## the turn ends or the unit attacks.
func _state_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		if tick == 0:
			u.stealth_active = false
		var has_bagworm := _card_is(ta.main_card, TriggerCard.CardType.STEALTH) or _card_is(ta.sub_card, TriggerCard.CardType.STEALTH)
		if has_bagworm and not u.stealth_active:
			u.stealth_active = true
			events.append(CombatEvent.new(tick, CombatEvent.Phase.STATE, "%s activates Bagworm (stealth)" % u.display_name(), u))


# --- 2. Traps & Movement ----------------------------------------------------

func _movement_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	# Spider wire deployments (traps) resolve first.
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		for slot in [TickAction.MAIN, TickAction.SUB]:
			if _is_spider(ta.slot_card(slot)) and ta.slot_has_target(slot):
				_deploy_wire(ms, u, ta.slot_target(slot), tick, events)

	# Then position shifts (movement), resolved simultaneously.
	var intents: Array = []  # [UnitState, target cell Vector3i(q, r, floor), card]
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		var slot := move_slot(ta)
		if slot == -1 or not ta.slot_has_target(slot):
			continue
		var card := ta.slot_card(slot)
		var to_hex := ta.slot_target(slot)
		var to_floor := ta.slot_target_floor(slot)
		if u.weight_ticks > 0:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s is weighed down (Lead Bullet) and cannot move" % u.display_name(), u))
		elif to_hex == u.hex and to_floor == u.floor:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s holds position" % u.display_name(), u))
		elif not is_valid_move(ms, u.hex, u.floor, to_hex, to_floor, card, u.team):
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s move skipped (%s f%d unreachable)" % [u.display_name(), str(to_hex), to_floor], u))
		else:
			intents.append([u, _cell(to_hex, to_floor), card])
	_resolve_moves(ms, intents, tick, events)


## Wires belong to the deploying team (Wire Mobility Penchant applies to it).
func _deploy_wire(ms: MatchState, u: UnitState, target: Vector2i, tick: int, events: Array[CombatEvent]) -> void:
	ms.wires[target] = u.team
	events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s deploys Spider wire at %s" % [u.display_name(), str(target)], u))


## Which slot carries this tick's movement card (Main first), or -1.
static func move_slot(ta: TickAction) -> int:
	if is_move_card(ta.main_card):
		return TickAction.MAIN
	if is_move_card(ta.sub_card):
		return TickAction.SUB
	return -1


## A board position including elevation: (q, r, floor).
static func _cell(hex: Vector2i, floor: int) -> Vector3i:
	return Vector3i(hex.x, hex.y, floor)


## Applies all legal moves at once so neither team gets priority. Positions
## are (hex, floor) cells, so floors of one building are separate spaces.
##   - two or more units entering the same cell all bounce,
##   - two units swapping cells both bounce (no passing through each other),
##   - a unit entering a cell whose occupant stays put is blocked (cascading),
##   - a wire dash is blocked by a unit standing on the wire it runs along.
## Rotations of 3+ units vacating each other's cells are allowed.
func _resolve_moves(ms: MatchState, intents: Array, tick: int, events: Array[CombatEvent]) -> void:
	var target_count := {}
	for it in intents:
		target_count[it[1]] = int(target_count.get(it[1], 0)) + 1

	var pending: Array = []
	for it in intents:
		var u: UnitState = it[0]
		var target: Vector3i = it[1]
		var card: TriggerCard = it[2]
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
		var to_hex := Vector2i(target.x, target.y)
		if not (card != null and card.jump) and HexCoord.distance(u.hex, to_hex) == 2 \
				and _wire_path(ms, u.hex, to_hex, u.team, true) == NO_HEX:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s wire dash blocked" % u.display_name(), u))
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
		var card: TriggerCard = it[2]
		var hex := Vector2i(target.x, target.y)
		var path := HexCoord.line(u.hex, hex)
		var dir := HexCoord.direction_to(u.hex, path[1]) if path.size() > 1 else -1
		var how := "moves"
		if card != null and card.jump:
			how = "jumps (Grasshopper)"
		elif HexCoord.distance(u.hex, hex) == 2:
			how = "dashes along wire"
		u.hex = hex
		u.floor = target.z
		if dir != -1:
			u.facing = dir
		var where := "ground" if target.z == 0 else "floor %d" % target.z
		events.append(CombatEvent.new(tick, CombatEvent.Phase.MOVEMENT, "%s %s to %s (%s)" % [u.display_name(), how, str(hex), where], u))


const NO_HEX := Vector2i(-2147483648, -2147483648)


## Middle hex of a 2-hex wire dash from `a` to `b`: a hex adjacent to both
## that carries `team`'s wire (and, when `need_free`, holds no unit), or
## NO_HEX when there is none. Deterministic (first match wins).
static func _wire_path(ms: MatchState, a: Vector2i, b: Vector2i, team: int, need_free: bool = false) -> Vector2i:
	for n in HexCoord.neighbors(a):
		if HexCoord.distance(n, b) != 1:
			continue
		if int(ms.wires.get(n, -1)) != team or not ms.floor_legal(n, 0):
			continue
		if need_free and ms.get_unit_at(n, 0) != null:
			continue
		return n
	return NO_HEX


## Whether (from_hex, from_floor) -> (to_hex, to_floor) is a legal single
## move action for `card` (Move or Grasshopper) by a unit of `team`:
##   - one hex horizontally (same floor), or one floor vertically,
##   - entering/exiting a building (ground <-> floor 1),
##   - Wire Mobility Penchant: a 2-hex ground dash from one of the team's
##     wires along another of its wires,
##   - Grasshopper jump: up to 2 hexes onto open ground or onto a rooftop
##     (any building's top floor), over obstacles.
## Occupancy is checked by the caller.
static func is_valid_move(ms: MatchState, from_hex: Vector2i, from_floor: int, to_hex: Vector2i, to_floor: int, card: TriggerCard = null, team: int = -1) -> bool:
	if to_floor < 0 or not ms.has_tile(to_hex):
		return false
	var d_hex := HexCoord.distance(from_hex, to_hex)
	var d_floor := absi(to_floor - from_floor)
	if card != null and card.jump and d_hex <= JUMP_RANGE and (d_hex > 0 or to_floor != from_floor):
		var roof := ms.building_floors(to_hex)
		if (to_floor == 0 and ms.floor_legal(to_hex, 0)) or (roof > 0 and to_floor == roof):
			return true
	if d_hex == 0:
		# Vertical move within the same building (up or down one floor).
		return d_floor == 1 and ms.floor_legal(to_hex, to_floor)
	if d_hex == 1:
		if d_floor == 0:
			# Horizontal move on the same floor (ground or equal-height roofs).
			return ms.floor_legal(to_hex, to_floor)
		if d_floor == 1:
			# Enter a building (ground -> floor 1) or exit it onto open ground.
			var enter := from_floor == 0 and to_floor == 1 and ms.building_floors(to_hex) >= 1
			var leave := from_floor == 1 and to_floor == 0 and ms.building_floors(from_hex) >= 1 and ms.floor_legal(to_hex, 0)
			return enter or leave
	if d_hex == WIRE_DASH_RANGE and team != -1 and from_floor == 0 and to_floor == 0:
		if int(ms.wires.get(from_hex, -1)) == team and ms.floor_legal(to_hex, 0):
			return _wire_path(ms, from_hex, to_hex, team) != NO_HEX
	return false


# --- 3. Defense -------------------------------------------------------------

func _defense_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> void:
	for row in _iter_active(ms, plans, tick):
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		var main_shield := _card_is(ta.main_card, TriggerCard.CardType.SHIELD)
		var sub_shield := _card_is(ta.sub_card, TriggerCard.CardType.SHIELD)
		var blade_guard := (ta.main_card != null and ta.main_card.guard) or (ta.sub_card != null and ta.sub_card.guard)
		u.shield_active = main_shield or sub_shield or blade_guard
		u.full_guard = main_shield and sub_shield
		if u.full_guard:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.DEFENSE, "%s assumes Full Guard" % u.display_name(), u))


# --- 4. Attack & Projectile -------------------------------------------------

func _attack_phase(ms: MatchState, plans: Array, tick: int, events: Array[CombatEvent]) -> Array:
	var pending: Array = []  # [{ "target": UnitState, "damage": int, "effect": String }]

	var attacker_rows: Array = []
	for row in _iter_active(ms, plans, tick):
		var ta: TickAction = row[3]
		if _is_offensive(ta.main_card) or _is_offensive(ta.sub_card):
			attacker_rows.append(row)

	attacker_rows.sort_custom(_compare_attackers)

	var strikes: Array = []  # executed primary attacks: [attacker, card, target]
	var attacking := {}      # UnitState -> true (acted offensively this tick)
	for row in attacker_rows:
		var u: UnitState = row[2]
		var ta: TickAction = row[3]
		for slot in [TickAction.MAIN, TickAction.SUB]:
			var card := ta.slot_card(slot)
			if _is_offensive(card) and ta.slot_has_target(slot):
				attacking[u] = true
				var target := _resolve_attack(ms, u, card, ta.slot_target(slot), tick, events, pending)
				if target != null:
					strikes.append([u, card, target])

	_combo_assists(ms, plans, strikes, attacking, tick, events, pending)
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


## GDD 5.3 combos, triggered by executed primary attacks this tick:
##   Melee Assist — a melee strike on a target adjacent to a friendly unit
##     with a melee trigger: that ally follows up for 0 AT.
##   Crossfire Assist — a ranged attack on a target inside an ally's firing
##     arc (vision cone) and range: the ally follows up for 50% AT, paid from
##     its unspent AT this turn.
## Each ally assists at most once per tick, and not while attacking itself.
func _combo_assists(ms: MatchState, plans: Array, strikes: Array, attacking: Dictionary, tick: int, events: Array[CombatEvent], pending: Array) -> void:
	var assisted := {}
	for s in strikes:
		var striker: UnitState = s[0]
		var card: TriggerCard = s[1]
		var target: UnitState = s[2]
		if target.is_bailed:
			continue
		var team_units: Array = ms.teams[striker.team]
		for i in team_units.size():
			var ally: UnitState = team_units[i]
			if ally == striker or ally.is_bailed or attacking.has(ally) or assisted.has(ally):
				continue
			if card.card_type == TriggerCard.CardType.MELEE:
				var blade := _best_card(ally, TriggerCard.CardType.MELEE)
				if blade == null or HexCoord.distance(ally.hex, target.hex) != 1 or ally.floor != target.floor:
					continue
				assisted[ally] = true
				events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s joins in — Melee Assist" % ally.display_name(), ally, target))
				_resolve_attack(ms, ally, blade, target.hex, tick, events, pending)
			else:
				var gun := _best_card(ally, TriggerCard.CardType.RANGED)
				if gun == null or HexCoord.distance(ally.hex, target.hex) > gun.attack_range:
					continue
				if not Visibility.in_cone(ally, target.hex):
					continue
				if not gun.curved and not Visibility.has_los(ms, ally.hex, ally.floor, target.hex, target.floor):
					continue
				var cost := ceili(gun.action_at_cost * 0.5)
				var plan: TurnPlan = plans[ally.team]
				var spare := plan.get_at_remaining(i) - int(_assist_spent.get(ally, 0))
				if spare < cost:
					continue
				_assist_spent[ally] = int(_assist_spent.get(ally, 0)) + cost
				assisted[ally] = true
				events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s opens crossfire (%d AT) — Crossfire Assist" % [ally.display_name(), cost], ally, target))
				_resolve_attack(ms, ally, gun, target.hex, tick, events, pending)


## Highest-power equipped trigger of `type` (damage dealers only).
func _best_card(u: UnitState, type: int) -> TriggerCard:
	var best: TriggerCard = null
	for slots in [u.unit_data.main_trigger_slots, u.unit_data.sub_trigger_slots]:
		for c in slots:
			var card: TriggerCard = c
			if card != null and card.card_type == type and card.power > 0:
				if best == null or card.power > best.power:
					best = card
	return best


## Resolves one attack. Returns the target when the attack was executed
## (in range and unobstructed, hit or miss), else null.
func _resolve_attack(ms: MatchState, attacker: UnitState, card: TriggerCard, target_hex: Vector2i, tick: int, events: Array[CombatEvent], pending: Array) -> UnitState:
	if attacker.stealth_active:
		attacker.stealth_active = false
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s reveals itself attacking" % attacker.display_name(), attacker))

	var target := ms.get_unit_at_any_floor(target_hex)
	if target == null:
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s attacks %s but no target present" % [attacker.display_name(), str(target_hex)], attacker))
		return null
	if target.team == attacker.team:
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s skips friendly fire on %s" % [attacker.display_name(), target.display_name()], attacker, target))
		return null

	var dist := HexCoord.distance(attacker.hex, target.hex)

	# Stealth concealment: cannot be targeted beyond the reveal range.
	if target.stealth_active and dist > STEALTH_REVEAL_RANGE:
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s cannot find %s (stealth)" % [attacker.display_name(), target.display_name()], attacker, target))
		return null

	# Range check.
	if card.card_type == TriggerCard.CardType.MELEE:
		if dist != 1 or target.floor != attacker.floor:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s melee out of range on %s" % [attacker.display_name(), target.display_name()], attacker, target))
			return null
	else:
		if dist > card.attack_range:
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s %s out of range on %s" % [attacker.display_name(), card.card_name, target.display_name()], attacker, target))
			return null
		if not card.curved and not Visibility.has_los(ms, attacker.hex, attacker.floor, target.hex, target.floor):
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s shot blocked (no line of sight)" % attacker.display_name(), attacker, target))
			return null

	# Hit / evasion roll.
	if not always_hit:
		var roll := ms.rng.randf()
		if roll > _hit_chance(ms, target, card):
			events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s misses %s" % [attacker.display_name(), target.display_name()], attacker, target))
			return target

	if card.effect == "weight":
		pending.append({ "target": target, "damage": 0, "effect": "weight" })
		events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s tags %s with Lead Bullet" % [attacker.display_name(), target.display_name()], attacker, target))
		return target

	# Damage + mitigation (applied later in the Resolution phase).
	var raw := float(attacker.unit_data.attack_rating + card.power)
	if card.card_type == TriggerCard.CardType.RANGED and not _ignores_half_cover(card) and _has_half_cover(ms, attacker.hex, target.hex):
		raw *= 0.5

	var mitigation := _mitigation(ms, target, attacker.hex, card)
	var damage := maxi(0, roundi(raw - mitigation))
	pending.append({ "target": target, "damage": damage, "effect": "" })
	events.append(CombatEvent.new(tick, CombatEvent.Phase.ATTACK, "%s hits %s with %s for %d (mitigated %.1f)" % [attacker.display_name(), target.display_name(), card.card_name, damage, mitigation], attacker, target, damage))
	return target


func _hit_chance(ms: MatchState, target: UnitState, card: TriggerCard) -> float:
	var base := BASE_MELEE_HIT if card.card_type == TriggerCard.CardType.MELEE else BASE_RANGED_HIT
	base += card.accuracy_bonus
	if target.weight_ticks > 0:
		return clampf(base, 0.05, 0.98)  # weighed down: can't dodge
	var evasion := target.unit_data.mobility_rating * EVASION_PER_MOBILITY
	if on_friendly_wire(ms, target):
		evasion += WIRE_EVADE_BONUS
	return clampf(base - evasion, 0.05, 0.98)


func _mitigation(ms: MatchState, target: UnitState, attacker_hex: Vector2i, card: TriggerCard) -> float:
	var defense := float(target.unit_data.defense_rating)
	if on_friendly_wire(ms, target):
		defense *= 1.0 + WIRE_DEF_BONUS
	if target.full_guard:
		var guard := defense * FULL_GUARD_DEF_MULT
		return guard * 0.5 if card.piercing else guard
	if card.piercing or card.flexible:
		return 0.0  # pierces / slips around ordinary shields
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
		if str(p.get("effect", "")) == "weight":
			# +1 because the counter ticks down at the end of this tick.
			target.weight_ticks = WEIGHT_TICKS + 1
			events.append(CombatEvent.new(tick, CombatEvent.Phase.RESOLUTION, "%s is weighed down — cannot move or dodge for %d ticks" % [target.display_name(), WEIGHT_TICKS], target, target))
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
	return card != null and (card.card_type == TriggerCard.CardType.MOVE or card.jump)


func _is_spider(card: TriggerCard) -> bool:
	return card != null and card.card_name == "Spider"


## Wire Mobility Penchant: only the deploying team benefits from its wires.
static func on_friendly_wire(ms: MatchState, u: UnitState) -> bool:
	return u.floor == 0 and int(ms.wires.get(u.hex, -1)) == u.team


func _ignores_half_cover(card: TriggerCard) -> bool:
	return card.homing or card.curved


func _has_half_cover(ms: MatchState, a: Vector2i, b: Vector2i) -> bool:
	for hex in HexCoord.line(a, b):
		if hex == a or hex == b:
			continue
		if int(ms.cover.get(hex, 0)) == 1:
			return true
	return false
