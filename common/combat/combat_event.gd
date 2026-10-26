class_name CombatEvent
extends RefCounted
## One entry in the deterministic resolution log (for replay visualization).

enum Phase { STATE, MOVEMENT, DEFENSE, ATTACK, RESOLUTION }

var tick: int
var phase: int
var actor: UnitState
var target: UnitState
var message: String
var damage: int = 0

## Optional attack metadata used only for visuals (slash / bullet-path FX).
## `card_type` is a TriggerCard.CardType (or -1); `has_line` marks a real
## attack so from_hex/to_hex describe the trajectory. `curved` tells the FX
## whether the shot bends through hexes (Viper/Hound) or flies straight.
var card_type: int = -1
var from_hex: Vector2i
var to_hex: Vector2i
var curved := false
var has_line := false


func _init(p_tick: int, p_phase: int, p_message: String, p_actor: UnitState = null, p_target: UnitState = null, p_damage: int = 0) -> void:
	tick = p_tick
	phase = p_phase
	message = p_message
	actor = p_actor
	target = p_target
	damage = p_damage


func summary() -> String:
	return "[T%d] %s" % [tick + 1, message]


## Tags this event with the attack's card type and trajectory (for FX).
func with_attack(p_card_type: int, p_from: Vector2i, p_to: Vector2i, p_curved: bool = false) -> CombatEvent:
	card_type = p_card_type
	from_hex = p_from
	to_hex = p_to
	curved = p_curved
	has_line = true
	return self
