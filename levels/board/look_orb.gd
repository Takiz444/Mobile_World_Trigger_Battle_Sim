class_name LookOrb
extends Node3D
## A small semi-transparent sphere the player drags to choose where a unit
## looks for the selected tick.
##
## It orbits the selected unit's hex — resting on the edge matching the
## current facing — and follows the pointer while dragged. The match
## controller commits the facing on release. Purely a planning aid: it has no
## collision body, so board tile picking ignores it (hit-testing is done in
## screen space instead).

## How far out the orb orbits, as a fraction of hex_size.
const ORBIT_FRACTION := 0.72
## Pointer-to-orb screen distance (px) that counts as grabbing it.
const HIT_RADIUS_PX := 30.0
const HOVER_RADIUS_PX := 46.0

var hex_size := 1.0

var _orb: MeshInstance3D
var _ring: MeshInstance3D
var _material: StandardMaterial3D
var _ring_material: StandardMaterial3D
var _dragging := false
var _hovered := false
var _t := 0.0
var _y_off := 0.0


func setup(p_hex_size: float) -> void:
	hex_size = p_hex_size
	_y_off = hex_size * 0.45

	_material = _make_material(Color(0.62, 0.95, 1.0, 0.5), 1.4)
	_orb = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = hex_size * 0.2
	sphere.height = hex_size * 0.4
	sphere.radial_segments = 18
	sphere.rings = 10
	_orb.mesh = sphere
	_orb.material_override = _material
	_orb.position = Vector3(0.0, _y_off, 0.0)
	add_child(_orb)

	# A faint halo ring on the ground showing the orbit the orb travels on.
	_ring_material = _make_material(Color(0.5, 0.9, 1.0, 0.16), 0.5)
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	var r := hex_size * ORBIT_FRACTION
	torus.inner_radius = r - hex_size * 0.03
	torus.outer_radius = r + hex_size * 0.03
	torus.rings = 28
	torus.ring_segments = 6
	_ring.mesh = torus
	_ring.material_override = _ring_material
	_ring.rotation_degrees.x = 90.0
	_ring.position = Vector3(0.0, 0.03, 0.0)
	add_child(_ring)

	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	# Gentle breathing glow + a slowly turning orbit ring.
	var base_alpha := 0.62 if (_dragging or _hovered) else 0.45
	_material.albedo_color.a = base_alpha + 0.12 * (0.5 + 0.5 * sin(_t * 3.4))
	_ring.rotation.y = _t * 0.35
	if _dragging:
		return  # drag_to() owns the orb position while dragging
	_orb.position.y = _y_off + sin(_t * 2.2) * hex_size * 0.04


## Places the orb on the orbit ring around `center` along `facing`.
func show_at(center: Vector3, facing: int) -> void:
	position = center
	var fwd := _dir_vector(facing)
	_orb.global_position = center + Vector3(0.0, _y_off, 0.0) + fwd * (hex_size * ORBIT_FRACTION)
	visible = true


func hide_orb() -> void:
	visible = false
	_dragging = false
	_hovered = false


## Screen-space hit test against the orb (works for orthogonal cameras too).
func hit_test(screen_pos: Vector2, camera: Camera3D) -> bool:
	if not visible or camera == null:
		return false
	var p := camera.unproject_position(_orb.global_position)
	return p.distance_to(screen_pos) <= HIT_RADIUS_PX


## Highlights the orb when the pointer is near it (called on hover).
func set_hovered(screen_pos: Vector2, camera: Camera3D) -> void:
	if not visible or camera == null:
		_hovered = false
		return
	var p := camera.unproject_position(_orb.global_position)
	_hovered = p.distance_to(screen_pos) <= HOVER_RADIUS_PX


func begin_drag() -> void:
	_dragging = true
	_hovered = true


## Follows the pointer while being dragged.
func drag_to(world: Vector3) -> void:
	if not visible:
		return
	_orb.global_position = Vector3(world.x, world.y + _y_off, world.z)


func end_drag() -> void:
	_dragging = false


func is_dragging() -> bool:
	return _dragging


func orb_world_position() -> Vector3:
	return _orb.global_position


# --- Helpers ----------------------------------------------------------------

func _dir_vector(facing: int) -> Vector3:
	var v := HexCoord.axial_to_world(HexCoord.AXIAL_DIRECTIONS[posmod(facing, 6)], hex_size)
	v.y = 0.0
	return v.normalized()


func _make_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = energy
	return mat
