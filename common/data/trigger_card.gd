class_name TriggerCard
extends Resource
## One Trigger (weapon / utility) or basic action card.
##
## Deck-building uses the Trion equip cost (GDD section 6). In battle every
## action takes time instead of Action Tokens: `action_time` seconds of the
## character's 6-second turn (shorter with Stamina, see Talents). Move and
## Jump take as long as the route; Shield and Wait last as long as the player
## chooses.

enum CardType { MOVE, MELEE, RANGED, SHIELD, UTILITY, STEALTH }

@export var card_name: String = ""
## Deck-building Trion budget cost (loadout weight).
@export var trion_equip_cost: int = 0
## Seconds the action takes, before Stamina (0 = depends on route / hold).
@export var action_time: float = 1.0
## Base combat damage contributed by this card (added to attack_rating).
@export var power: int = 0
## Whether this card may be equipped in a Sub (off-hand) slot.
@export var is_dual_slot_compatible: bool = false
@export var card_icon: Texture2D

## Classification for lanes and trigger rules.
@export var card_type: CardType = CardType.UTILITY

# --- Trigger traits -----------------------------------------------------------
## Attack reach in metres (melee strikes at MELEE_RANGE).
@export var attack_range: float = 1.8
## Homing bullets (Hound).
@export var homing: bool = false
## Curved trajectories (Viper): shoot around buildings at a target the team sees.
@export var curved: bool = false
## Piercing (Ibis, Lead Bullet): ignores Shields; Full Guard only halves it.
@export var piercing: bool = false
## Demolishing (Ibis): a shot blocked by buildings blasts through them and
## brings each one down entirely (towers and other sealed solids still block).
@export var demolish: bool = false
## Flexible blade (Scorpion): strikes around shields (only Full Guard holds).
@export var flexible: bool = false
## Blade-shield (Raygust): a front shield is up while swinging.
@export var guard: bool = false
## Jump (Grasshopper): a fast leap onto the street or a roof.
@export var jump: bool = false
## Bonus hit chance (unused: attacks never miss).
@export var accuracy_bonus: float = 0.0
## Special on-hit effect: "weight" (Lead Bullet) roots the target.
@export var effect: String = ""
## Basic action every character has (Move, Look, Wait).
@export var free_action: bool = false


## Human-readable summary for tooltips.
func describe() -> String:
	var dual := " (sub)" if is_dual_slot_compatible else ""
	var timing := "%.1f s" % action_time if action_time > 0.0 else "time varies"
	var text := "%s%s\n%s · %s" % [card_name, dual, _type_name(card_type), timing]
	if power > 0:
		text += " · Power %d" % power
	if card_type == CardType.RANGED:
		text += " · Range %.0f m" % attack_range
	if trion_equip_cost > 0:
		text += " · Trion %d" % trion_equip_cost
	var traits := trait_text()
	if traits != "":
		text += "\n" + traits
	return text


## One-line description of this trigger's special behaviour.
func trait_text() -> String:
	var parts: Array[String] = []
	if homing:
		parts.append("homing bullets")
	if curved:
		parts.append("curved: shoots around buildings at targets your team sees")
	if piercing:
		parts.append("pierces shields")
	if demolish:
		parts.append("blasts through buildings and brings them down")
	if flexible:
		parts.append("strikes around shields")
	if guard:
		parts.append("front shield up while swinging")
	if jump:
		parts.append("jump up to %.1f m, onto rooftops" % CityGeometry.JUMP_RANGE)
	if effect == "weight":
		parts.append("weighs the target down: no moving for %.0f s" % TurnEngine.WEIGHT_SECONDS)
	match card_name:
		"Shield":
			parts.append("hold as long as you like; standing still = Full Guard all round")
		"Bagworm":
			parts.append("hidden from radar until you attack (this turn)")
		"Spider":
			parts.append("string a wire up to %.0f m away: your team gets +defense on it" % TurnEngine.SPIDER_RANGE)
		"Look":
			parts.append("keep watching a point, even while moving")
		"Wait":
			parts.append("pause this lane")
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
