class_name TurnPlan
extends RefCounted
## Planning-phase data model for one turn (GDD section 5).
##
## Holds per-unit 6-tick timelines and owns the Action Token economy:
## Dual-Slot Mental Load (+1 AT), Full Guard (flat 4 AT), and the
## Kogetsu/Scorpion melee Penchant (+2 base AT pool).

const TICKS_PER_TURN := 6
const MAIN_SLOT := 0
const SUB_SLOT := 1
const MENTAL_LOAD_COST := 1
const FULL_GUARD_COST := 4
const MELEE_PENCHANT_POOL := 10

var units: Array[UnitData] = []
var _ticks: Array = []  # _ticks[unit][tick] -> TickAction


func _init(unit_list: Array[UnitData] = []) -> void:
	setup(unit_list)


func setup(unit_list: Array[UnitData]) -> void:
	units = unit_list.duplicate()
	_ticks.clear()
	for _u in units:
		var row: Array = []
		for t in TICKS_PER_TURN:
			var ta := TickAction.new()
			ta.tick_index = t + 1
			row.append(ta)
		_ticks.append(row)


# --- Access -----------------------------------------------------------------

func get_tick(unit: int, tick: int) -> TickAction:
	return _ticks[unit][tick]


func get_card(unit: int, tick: int, slot: int) -> TriggerCard:
	var ta: TickAction = _ticks[unit][tick]
	return ta.sub_card if slot == SUB_SLOT else ta.main_card


## Sets the target/destination hex (and optional floor) for one slot of a
## tick (movement destinations and attack targets). Main and Sub aim
## independently.
func set_target(unit: int, tick: int, target_hex: Vector2i, target_floor: int = 0, slot: int = MAIN_SLOT) -> void:
	var ta := _ticks[unit][tick] as TickAction
	ta.set_slot_target(slot, target_hex, target_floor)


# --- Assignment -------------------------------------------------------------

## Validates a card placement against slot restrictions and the AT budget.
## Simulates the change so replacing an existing card is accounted for.
func can_assign(unit: int, tick: int, slot: int, card: TriggerCard) -> bool:
	if card == null:
		return false
	if slot == SUB_SLOT and not card.is_dual_slot_compatible:
		return false
	if card.card_type == TriggerCard.CardType.MOVE and slot == SUB_SLOT:
		return false

	var ta: TickAction = _ticks[unit][tick]
	var prev := ta.sub_card if slot == SUB_SLOT else ta.main_card
	if slot == SUB_SLOT:
		ta.sub_card = card
	else:
		ta.main_card = card
	var ok := get_at_spent(unit) <= get_at_pool(unit)
	if slot == SUB_SLOT:
		ta.sub_card = prev
	else:
		ta.main_card = prev
	return ok


func assign(unit: int, tick: int, slot: int, card: TriggerCard) -> bool:
	if not can_assign(unit, tick, slot, card):
		return false
	var ta: TickAction = _ticks[unit][tick]
	if slot == SUB_SLOT:
		ta.sub_card = card
	else:
		ta.main_card = card
	return true


func clear(unit: int, tick: int, slot: int) -> bool:
	var ta: TickAction = _ticks[unit][tick]
	if slot == SUB_SLOT:
		if ta.sub_card == null:
			return false
		ta.sub_card = null
	else:
		if ta.main_card == null:
			return false
		ta.main_card = null
	return true


# --- AT Economy -------------------------------------------------------------

func get_at_pool(unit: int) -> int:
	var u := units[unit]
	var pool := u.base_at_pool
	for card in u.main_trigger_slots:
		if card != null and card.card_type == TriggerCard.CardType.MELEE:
			pool = max(pool, MELEE_PENCHANT_POOL)
	return pool


## Bagworm is a maintained toggle (GDD 5.2: 1 AT maintenance per turn): only
## the first Bagworm placement of the turn is charged.
func get_at_spent(unit: int) -> int:
	var total := 0
	var bagworm_paid := false
	var row: Array = _ticks[unit]
	for ta in row:
		var tick_action := ta as TickAction
		total += _tick_cost(tick_action)
		for card in [tick_action.main_card, tick_action.sub_card]:
			if card != null and card.card_type == TriggerCard.CardType.STEALTH and not tick_action.is_full_guard():
				if bagworm_paid:
					total -= card.action_at_cost
				bagworm_paid = true
	return total


func get_at_remaining(unit: int) -> int:
	return get_at_pool(unit) - get_at_spent(unit)


static func _tick_cost(ta: TickAction) -> int:
	if ta.is_full_guard():
		return FULL_GUARD_COST
	var cost := 0
	if ta.main_card != null:
		cost += ta.main_card.action_at_cost
	if ta.sub_card != null:
		cost += ta.sub_card.action_at_cost
	if ta.is_dual_slot_active():
		cost += MENTAL_LOAD_COST
	return cost


# --- Validation -------------------------------------------------------------

func is_unit_valid(unit: int) -> bool:
	return get_at_spent(unit) <= get_at_pool(unit)


func is_all_valid() -> bool:
	for i in units.size():
		if not is_unit_valid(i):
			return false
	return true


# --- Action Card Deck -------------------------------------------------------

## The unit's in-battle hand: Move (always) + one card per equipped Trigger,
## deduplicated by name.
func get_available_actions(unit: int) -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	var seen := {}
	for basic in [TriggerLibrary.get_move_card(), TriggerLibrary.get_look_card()]:
		result.append(basic)
		seen[basic.card_name] = true

	var u := units[unit]
	for card in u.main_trigger_slots:
		if card != null and not seen.has(card.card_name):
			seen[card.card_name] = true
			result.append(card)
	for card in u.sub_trigger_slots:
		if card != null and not seen.has(card.card_name):
			seen[card.card_name] = true
			result.append(card)
	return result
