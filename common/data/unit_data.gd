class_name UnitData
extends Resource
## Persistent definition of a single squad unit (stats + Trigger Holder loadout).
## Configured in the Hangar screen and validated against a Trion budget.

const MAX_MAIN_SLOTS: int = 4
const MAX_SUB_SLOTS: int = 4

@export var unit_name: String = ""
@export var base_trion_hp: int = 0
@export var base_at_pool: int = 8
@export var mobility_rating: int = 0
@export var attack_rating: int = 0
@export var defense_rating: int = 0
## Max Trion loadout budget (section 6.1 of the GDD).
@export var max_trion_capacity: int = 100
@export var main_trigger_slots: Array[TriggerCard] = []   # Max 4
@export var sub_trigger_slots: Array[TriggerCard] = []    # Max 4


func get_total_trion_cost() -> int:
	var total := 0
	for card in main_trigger_slots:
		if card != null:
			total += card.trion_equip_cost
	for card in sub_trigger_slots:
		if card != null:
			total += card.trion_equip_cost
	return total


func is_within_budget() -> bool:
	return get_total_trion_cost() <= max_trion_capacity


## Checks whether `card` can be added to a Main/Sub slot without violating the
## slot limit or the Trion budget.
func can_equip(card: TriggerCard, slot_is_sub: bool) -> bool:
	if card == null:
		return false
	if get_total_trion_cost() + card.trion_equip_cost > max_trion_capacity:
		return false
	var slots: Array[TriggerCard] = sub_trigger_slots if slot_is_sub else main_trigger_slots
	var limit := MAX_SUB_SLOTS if slot_is_sub else MAX_MAIN_SLOTS
	return slots.size() < limit


## Pads both slot arrays to their max sizes (null = empty slot).
func ensure_slot_arrays() -> void:
	main_trigger_slots.resize(MAX_MAIN_SLOTS)
	sub_trigger_slots.resize(MAX_SUB_SLOTS)


func get_slot(slot_is_sub: bool, index: int) -> TriggerCard:
	var slots := sub_trigger_slots if slot_is_sub else main_trigger_slots
	if index < 0 or index >= slots.size():
		return null
	return slots[index]


func set_slot(card: TriggerCard, slot_is_sub: bool, index: int) -> void:
	var slots := sub_trigger_slots if slot_is_sub else main_trigger_slots
	if index < 0 or index >= slots.size():
		return
	slots[index] = card


func clear_slot(slot_is_sub: bool, index: int) -> void:
	set_slot(null, slot_is_sub, index)


## Whether `card` can occupy this slot (replacing any existing card) within the
## Trion budget and sub-slot dual-compatibility rules.
func can_assign_slot(card: TriggerCard, slot_is_sub: bool, index: int) -> bool:
	if card == null:
		return false
	if slot_is_sub and not card.is_dual_slot_compatible:
		return false
	var slots := sub_trigger_slots if slot_is_sub else main_trigger_slots
	if index < 0 or index >= slots.size():
		return false
	var total := get_total_trion_cost()
	var existing: TriggerCard = slots[index]
	if existing != null:
		total -= existing.trion_equip_cost
	total += card.trion_equip_cost
	return total <= max_trion_capacity
