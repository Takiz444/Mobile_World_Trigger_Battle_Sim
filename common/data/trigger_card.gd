class_name TriggerCard
extends Resource
## Defines a single Trigger (weapon / utility) card.
##
## Used both for deck-building (Trion equip cost, section 6 of the GDD) and
## in-battle action generation (AT placement cost, section 5.2).

## Broad classification used by Penchant and Combo assist rules (section 5.3).
enum CardType { MOVE, MELEE, RANGED, SHIELD, UTILITY, STEALTH }

@export var card_name: String = ""
## Deck-building Trion budget cost (loadout weight).
@export var trion_equip_cost: int = 0
## Timeline placement cost in Action Tokens.
@export var action_at_cost: int = 0
## Base combat damage contributed by this card (added to attack_rating).
@export var power: int = 0
## Whether this card may be slotted on the Sub (off-hand) slot.
@export var is_dual_slot_compatible: bool = false
@export var card_icon: Texture2D

## Classification for synergy / penchant resolution.
@export var card_type: CardType = CardType.UTILITY


## Human-readable summary for tooltips.
func describe() -> String:
	var dual := " (sub)" if is_dual_slot_compatible else ""
	return "%s%s\n%s\nAT %d · Power %d · Trion %d" % [
		card_name, dual, _type_name(card_type),
		action_at_cost, power, trion_equip_cost,
	]


static func _type_name(t: int) -> String:
	match t:
		CardType.MOVE:
			return "Move"
		CardType.MELEE:
			return "Melee"
		CardType.RANGED:
			return "Ranged"
		CardType.SHIELD:
			return "Shield"
		CardType.UTILITY:
			return "Utility"
		CardType.STEALTH:
			return "Stealth"
	return "?"
