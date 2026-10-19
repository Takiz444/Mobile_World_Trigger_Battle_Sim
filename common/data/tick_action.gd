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
var target_hex: Vector2i         # Axial (q, r) destination / target
var target_floor: int = 0        # destination floor (movement only)
var has_target: bool = false


func is_dual_slot_active() -> bool:
	return main_card != null and sub_card != null


func is_full_guard() -> bool:
	return main_card != null and sub_card != null \
		and main_card.card_type == TriggerCard.CardType.SHIELD \
		and sub_card.card_type == TriggerCard.CardType.SHIELD
