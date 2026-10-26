class_name TickAction
extends RefCounted
## A single unit's planned action bundle for one tick (1..3) on the timeline.
##
## main_card and sub_card together model the Dual-Slot system (section 5.3):
## concurrent Main + Sub actions incur a Mental Load penalty, and a double
## Shield assignment represents Full Guard.

var tick_index: int = 0          # 1..3
var main_card: TriggerCard
var sub_card: TriggerCard
# Main-slot target.
var target_hex: Vector2i         # Axial (q, r) destination / target
var target_floor: int = 0        # destination floor (movement only)
var has_target: bool = false
# Sub-slot target (each slot aims independently, e.g. move + shoot elsewhere).
var sub_target_hex: Vector2i
var sub_target_floor: int = 0
var sub_has_target: bool = false

## Optional per-slot facing override (0..5 hex edge). Replaces the old free
## "Look" card: a slot may pick a direction to face without spending AT.
const NO_FACING := -1
var main_facing: int = NO_FACING
var sub_facing: int = NO_FACING

const MAIN := 0
const SUB := 1


func slot_card(slot: int) -> TriggerCard:
	return sub_card if slot == SUB else main_card


func slot_has_target(slot: int) -> bool:
	return sub_has_target if slot == SUB else has_target


func slot_target(slot: int) -> Vector2i:
	return sub_target_hex if slot == SUB else target_hex


func slot_target_floor(slot: int) -> int:
	return sub_target_floor if slot == SUB else target_floor


func set_slot_target(slot: int, hex: Vector2i, floor: int = 0) -> void:
	if slot == SUB:
		sub_target_hex = hex
		sub_target_floor = floor
		sub_has_target = true
	else:
		target_hex = hex
		target_floor = floor
		has_target = true


func slot_facing(slot: int) -> int:
	return sub_facing if slot == SUB else main_facing


func slot_has_facing(slot: int) -> bool:
	return slot_facing(slot) != NO_FACING


func set_slot_facing(slot: int, facing: int) -> void:
	if slot == SUB:
		sub_facing = posmod(facing, 6)
	else:
		main_facing = posmod(facing, 6)


func clear_slot_facing(slot: int) -> void:
	if slot == SUB:
		sub_facing = NO_FACING
	else:
		main_facing = NO_FACING


## Both slots used by real actions (free actions like Look add no Mental Load).
func is_dual_slot_active() -> bool:
	return main_card != null and sub_card != null and not main_card.free_action and not sub_card.free_action


func is_full_guard() -> bool:
	return main_card != null and sub_card != null \
		and main_card.card_type == TriggerCard.CardType.SHIELD \
		and sub_card.card_type == TriggerCard.CardType.SHIELD
