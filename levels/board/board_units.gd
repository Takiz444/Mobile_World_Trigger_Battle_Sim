class_name BoardUnits
extends Node3D
## Visualizes UnitState markers on the hex board: team-colored boxes, a facing
## "nose", and a floating Trion HP label. Bailed units are hidden.
##
## Provides tween helpers so the replay controller can animate movement,
## facing changes, damage flashes, and bail-outs instead of teleporting.

var _hex_size: float = 1.0
var _markers: Dictionary = {}        # UnitState -> Node3D
var _hp_labels: Dictionary = {}      # UnitState -> Label3D
var _nose_nodes: Dictionary = {}     # UnitState -> MeshInstance3D
var _body_materials: Dictionary = {} # UnitState -> StandardMaterial3D
var _body_colors: Dictionary = {}    # UnitState -> Color
var _move_tweens: Dictionary = {}    # UnitState -> Tween
var _face_tweens: Dictionary = {}    # UnitState -> Tween


## Clears existing markers and spawns one per unit.
func setup(units: Array[UnitState], hex_size: float) -> void:
	_hex_size = hex_size
	for c in get_children():
		c.queue_free()
	_markers.clear()
	_hp_labels.clear()
	_nose_nodes.clear()
	_body_materials.clear()
	_body_colors.clear()
	_move_tweens.clear()
	_face_tweens.clear()
	for u in units:
		_spawn_marker(u)


## Updates HP labels and visibility without moving markers.
func update_labels() -> void:
	for u in _markers:
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		if not u.is_bailed:
			_markers[u].visible = true


## Hard-syncs every marker to the unit's current hex/facing/HP. Used at turn
## boundaries. Kills any in-flight tweens first.
func refresh() -> void:
	for u in _markers:
		_kill_tween(_move_tweens, u)
		_kill_tween(_face_tweens, u)
		var root: Node3D = _markers[u]
		root.scale = Vector3.ONE
		root.position = HexCoord.axial_to_world(u.hex, _hex_size)
		root.visible = not u.is_bailed
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		var nose: MeshInstance3D = _nose_nodes[u]
		nose.position = _nose_offset(u.facing)


# --- Tween Helpers ----------------------------------------------------------

## Tweens a marker from its current position to `world`.
func tween_to(u: UnitState, world: Vector3, duration: float = 0.35) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	var tw := root.create_tween()
	tw.tween_property(root, "position", world, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_move_tweens[u] = tw


## Tweens the facing "nose" toward a new direction.
func tween_facing(u: UnitState, facing: int, duration: float = 0.35) -> void:
	var nose: MeshInstance3D = _nose_nodes.get(u)
	if nose == null:
		return
	_kill_tween(_face_tweens, u)
	var tw := nose.create_tween()
	tw.tween_property(nose, "position", _nose_offset(facing), duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_face_tweens[u] = tw


## Quick red flash on a unit that took damage.
func flash_hit(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	var mat: StandardMaterial3D = _body_materials.get(u)
	if root == null or mat == null:
		return
	var base: Color = _body_colors.get(u, Color(1, 1, 1))
	var tw := root.create_tween()
	tw.tween_property(mat, "albedo_color", Color(1.0, 0.18, 0.18), 0.1)
	tw.tween_property(mat, "albedo_color", base, 0.28)


## Shrinks a bailed unit out and hides it.
func play_bail(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	_kill_tween(_face_tweens, u)
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3(0.01, 0.01, 0.01), 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: root.visible = false)


# --- Construction -----------------------------------------------------------

func _spawn_marker(u: UnitState) -> void:
	var root := Node3D.new()
	root.name = "Unit_" + u.display_name()
	root.position = HexCoord.axial_to_world(u.hex, _hex_size)

	var team_color := Color(0.2, 0.5, 1.0) if u.team == 0 else Color(1.0, 0.35, 0.3)
	var body := MeshInstance3D.new()
	body.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.7, 0.7)
	body.mesh = box
	body.material_override = _make_material(team_color)
	root.add_child(body)

	# Facing indicator ("nose") in the unit's facing direction.
	var nose := MeshInstance3D.new()
	nose.name = "Nose"
	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	nose.mesh = sphere
	nose.material_override = _make_material(Color(0.9, 0.9, 0.95))
	nose.position = _nose_offset(u.facing)
	root.add_child(nose)

	var label := Label3D.new()
	label.text = str(u.trion_hp)
	label.position = Vector3(0, 1.0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.02
	root.add_child(label)

	add_child(root)
	_markers[u] = root
	_hp_labels[u] = label
	_nose_nodes[u] = nose
	_body_materials[u] = body.material_override
	_body_colors[u] = team_color


func _nose_offset(facing: int) -> Vector3:
	var fwd := _facing_vector(facing)
	return Vector3(fwd.x * 0.55, 0.0, fwd.z * 0.55)


func _kill_tween(dict: Dictionary, key: Variant) -> void:
	var tw: Tween = dict.get(key)
	if tw != null:
		tw.kill()
	dict.erase(key)


func _facing_vector(facing: int) -> Vector3:
	var dir_hex := HexCoord.AXIAL_DIRECTIONS[posmod(facing, 6)]
	var a := HexCoord.axial_to_world(Vector2i.ZERO, 1.0)
	var b := HexCoord.axial_to_world(dir_hex, 1.0)
	return (b - a).normalized()


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.45
	return mat
