class_name CombatEvent
extends RefCounted
## One entry in the deterministic resolution log (for replay and the log).
## `time` is seconds into the turn (0..TurnEngine.TURN_SECONDS).

enum Phase { STATE, MOVEMENT, DEFENSE, ATTACK, RESOLUTION }

var time: float
var phase: int
var actor: UnitState
var target: UnitState
var message: String
var damage: int = 0


func _init(p_time: float, p_phase: int, p_message: String, p_actor: UnitState = null, p_target: UnitState = null, p_damage: int = 0) -> void:
	time = p_time
	phase = p_phase
	message = p_message
	actor = p_actor
	target = p_target
	damage = p_damage


func summary() -> String:
	return "[%.1fs] %s" % [time, message]
