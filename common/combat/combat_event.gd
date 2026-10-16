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


func _init(p_tick: int, p_phase: int, p_message: String, p_actor: UnitState = null, p_target: UnitState = null, p_damage: int = 0) -> void:
	tick = p_tick
	phase = p_phase
	message = p_message
	actor = p_actor
	target = p_target
	damage = p_damage


func summary() -> String:
	return "[T%d] %s" % [tick + 1, message]
