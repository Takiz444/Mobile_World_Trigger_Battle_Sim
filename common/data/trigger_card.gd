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

# --- Trigger traits (World Trigger behaviour) -------------------------------
## Max hex distance for attacks (melee is always adjacent).
@export var attack_range: int = 1
## Homing bullets (Hound): ignore half cover (pair with accuracy_bonus).
@export var homing: bool = false
## Curved trajectories (Viper): ignore line of sight and cover.
@export var curved: bool = false
## Piercing (Ibis, Lead Bullet): ignores Shields; Full Guard only halves it.
@export var piercing: bool = false
## Flexible blade (Scorpion): strikes around shields (only Full Guard holds).
@export var flexible: bool = false
## Blade-shield (Raygust): attacking also raises a front shield this tick.
@export var guard: bool = false
## Jump (Grasshopper): move up to 2 hexes, onto rooftops, over units.
@export var jump: bool = false
## Bonus hit chance (Egret precision, Hound homing).
@export var accuracy_bonus: float = 0.0
## Special on-hit effect: "weight" (Lead Bullet) roots the target.
@export var effect: String = ""
## Free action (Look): costs no AT and adds no dual-slot Mental Load.
@export var free_action: bool = false


## Human-readable summary for tooltips.
func describe() -> String:
	var dual := " (sub)" if is_dual_slot_compatible else ""
	var text := "%s%s\n%s\nAT %d · Power %d · Trion %d" % [
		card_name, dual, _type_name(card_type),
		action_at_cost, power, trion_equip_cost,
	]
	if card_type == CardType.RANGED:
		text += " · Range %d" % attack_range
	var traits := trait_text()
	if traits != "":
		text += "\n" + traits
	return text


## One-line description of this trigger's special behaviour.
func trait_text() -> String:
	var parts: Array[String] = []
	if homing:
		parts.append("homing: +hit, ignores half cover")
	if curved:
		parts.append("curved: shoots around buildings and cover")
	if piercing:
		parts.append("pierces shields")
	if flexible:
		parts.append("strikes around shields")
	if guard:
		parts.append("raises a front shield while attacking")
	if jump:
		parts.append("jump 2 hexes / onto rooftops")
	if effect == "weight":
		parts.append("weighs the target down: no moving or dodging for 6 ticks")
	return " · ".join(parts)


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
