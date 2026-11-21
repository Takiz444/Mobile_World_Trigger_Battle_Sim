class_name UnitState
extends RefCounted
## Runtime state of one character during a match.
##
## Position is continuous: `pos` is a point on the ground plane (world X, Z in
## metres) and `level` says whether the character is on the street (0),
## inside a building on a floor, or on its roof (see CityGeometry). `facing`
## is an angle in radians in that plane: Vector2.from_angle(facing) points
## where the character looks.

var unit_data: UnitData
var team: int
var pos: Vector2 = Vector2.ZERO
var level: int = 0
var facing: float = 0.0
var trion_hp: int
var is_bailed: bool = false
var stealth_active: bool = false   # Bagworm
## Seconds left weighed down by Lead Bullet (no moving, no dodging).
var weight_time: float = 0.0

# Client-side fog of war (never read by the engine): how the local player
# currently perceives this unit, and its radar ghost position.
var fog: int = Visibility.State.SIGHT
var ping_pos: Vector2 = Vector2.ZERO

# Moment-to-moment state, maintained by the engine while a turn resolves.
var shield_active: bool = false
var full_guard: bool = false
var moving: bool = false
## Look: keep facing this point (even while moving) until the turn ends.
var watching: bool = false
var watch_point: Vector2 = Vector2.ZERO


func _init(data: UnitData, p_team: int, p_pos: Vector2 = Vector2.ZERO, p_facing: float = 0.0) -> void:
	unit_data = data
	team = p_team
	pos = p_pos
	facing = wrapf(p_facing, -PI, PI)
	trion_hp = data.base_trion_hp


func display_name() -> String:
	return "T%d.%s" % [team, unit_data.unit_name]


## Unit vector this character faces (ground plane).
func forward() -> Vector2:
	return Vector2.from_angle(facing)
