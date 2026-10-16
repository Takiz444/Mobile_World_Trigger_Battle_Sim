class_name UnitState
extends RefCounted
## Runtime combat state for a single unit during tick resolution.

var unit_data: UnitData
var team: int
var hex: Vector2i
var facing: int            # 0..5 direction index
var trion_hp: int
var is_bailed: bool = false
var stealth_active: bool = false   # Bagworm

# Per-tick defensive state, reset by the engine each tick.
var shield_active: bool = false
var full_guard: bool = false


func _init(data: UnitData, p_team: int, p_hex: Vector2i, p_facing: int = 0) -> void:
	unit_data = data
	team = p_team
	hex = p_hex
	facing = posmod(p_facing, 6)
	trion_hp = data.base_trion_hp


func display_name() -> String:
	return "T%d.%s" % [team, unit_data.unit_name]
