class_name TickAction
extends RefCounted
## A single unit's planned action bundle for one tick (1..6) on the timeline.
##
## main_card and sub_card together model the Dual-Slot system (section 5.3):
## concurrent Main + Sub actions incur a Mental Load penalty, and a double
## Shield assignment represents Full Guard.

var tick_index: int = 0          # 1..6
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


## Both slots used by real actions (free actions like Look add no Mental Load).
func is_dual_slot_active() -> bool:
	return main_card != null and sub_card != null and not main_card.free_action and not sub_card.free_action


func is_full_guard() -> bool:
	return main_card != null and sub_card != null \
		and main_card.card_type == TriggerCard.CardType.SHIELD \
		and sub_card.card_type == TriggerCard.CardType.SHIELD
