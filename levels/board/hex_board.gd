class_name HexBoard
extends Node3D
## Procedural hex-grid board for the 3D "hologram tabletop" diorama.
##
## Spawns a StaticBody3D per hex (shared prism mesh + convex collision shape),
## handles mouse hover/selection via raycasting, exposes hex <-> world helpers,
## and visualizes cover props, spider wires, and valid-target highlights.

## Hex sentinel used to represent "no tile" (outside the valid board range).
const INVALID_HEX := Vector2i(-2147483648, -2147483648)

signal tile_hovered(hex: Vector2i)
signal tile_selected(hex: Vector2i)

@export var board_radius: int = 5
@export var hex_size: float = 1.0
@export var tile_height: float = 0.35

@export var tile_color: Color = Color(0.12, 0.42, 0.8, 0.85)
@export var hover_color: Color = Color(0.25, 0.85, 1.0, 0.95)
@export var selected_color: Color = Color(1.0, 0.82, 0.2, 1.0)
@export var highlight_color: Color = Color(0.3, 1.0, 0.5, 0.95)
@export var effect_color: Color = Color(1.0, 0.5, 0.15, 0.95)
@export var wire_color: Color = Color(1.0, 0.6, 0.2, 0.95)

var _mesh: ArrayMesh
var _shape: ConvexPolygonShape3D
var _base_material: StandardMaterial3D
var _hover_material: StandardMaterial3D
var _selected_material: StandardMaterial3D
var _highlight_material: StandardMaterial3D
var _effect_material: StandardMaterial3D
var _wire_material: StandardMaterial3D

var _tiles: Dictionary = {}        # Vector2i -> StaticBody3D
var _tile_meshes: Dictionary = {}  # Vector2i -> MeshInstance3D
var _cover_props: Dictionary = {}  # Vector2i -> MeshInstance3D

var _hovered: Vector2i = INVALID_HEX
var _has_hover := false
var _selected: Vector2i = INVALID_HEX
var _has_selection := false
var _highlighted: Dictionary = {}  # Vector2i -> true (range / valid destinations)
var _effect_hexes: Dictionary = {} # Vector2i -> true (action effect area)
var _wire_hexes: Dictionary = {}   # Vector2i -> true


func _ready() -> void:
	_mesh = HexMesh.build(hex_size, tile_height)
	_shape = HexMesh.build_convex_shape(hex_size, tile_height)
	_base_material = _make_material(tile_color)
	_hover_material = _make_material(hover_color)
	_selected_material = _make_material(selected_color)
	_highlight_material = _make_material(highlight_color)
	_effect_material = _make_material(effect_color)
	_wire_material = _make_material(wire_color)
	_build_board()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var hex := _mouse_to_hex()
			if _tiles.has(hex):
				select_hex(hex)
				tile_selected.emit(hex)


# --- Board Construction -----------------------------------------------------

func _build_board() -> void:
	for hex in HexCoord.spiral(Vector2i.ZERO, board_radius):
		_spawn_tile(hex)


func _spawn_tile(hex: Vector2i) -> void:
	var body := StaticBody3D.new()
	body.name = "HexTile_%d_%d" % [hex.x, hex.y]
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta(&"hex_q", hex.x)
	body.set_meta(&"hex_r", hex.y)
	body.position = HexCoord.axial_to_world(hex, hex_size)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	mesh_inst.mesh = _mesh
	mesh_inst.material_override = _base_material
	body.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	col.name = "Collision"
	col.shape = _shape
	body.add_child(col)

	add_child(body)
	_tiles[hex] = body
	_tile_meshes[hex] = mesh_inst


# --- Public API -------------------------------------------------------------

func hex_to_world(hex: Vector2i) -> Vector3:
	return HexCoord.axial_to_world(hex, hex_size)


func world_to_hex(pos: Vector3) -> Vector2i:
	return HexCoord.world_to_axial(pos, hex_size)


func get_tile(hex: Vector2i) -> StaticBody3D:
	return _tiles.get(hex)


func has_tile(hex: Vector2i) -> bool:
	return _tiles.has(hex)


func select_hex(hex: Vector2i) -> void:
	if not _tiles.has(hex):
		return
	if _has_selection:
		var old := _selected
		_has_selection = false
		_apply(old)
	_has_selection = true
	_selected = hex
	_apply(hex)


func clear_selection() -> void:
	if _has_selection:
		var old := _selected
		_has_selection = false
		_apply(old)


## Highlights a set of hexes (e.g. valid move destinations). Clears the
## previous range-highlight set first.
func highlight_hexes(hexes: Array) -> void:
	var old_hexes: Array = _highlighted.keys()
	_highlighted.clear()
	for h in hexes:
		if _tiles.has(h):
			_highlighted[h] = true

	var affected := {}
	for h in old_hexes:
		affected[h] = true
	for h in hexes:
		affected[h] = true
	for h in affected.keys():
		_apply(h)


## Highlights the tiles an action affects (attack targets, trap area, self
## effects). Rendered in a distinct color layered above the range highlight.
func highlight_effects(hexes: Array) -> void:
	var old_hexes: Array = _effect_hexes.keys()
	_effect_hexes.clear()
	for h in hexes:
		if _tiles.has(h):
			_effect_hexes[h] = true

	var affected := {}
	for h in old_hexes:
		affected[h] = true
	for h in hexes:
		affected[h] = true
	for h in affected.keys():
		_apply(h)


func clear_highlights() -> void:
	highlight_hexes([])
	highlight_effects([])


## Sets the hexes carrying spider wires (visual tint only; the engine tracks
## the authoritative set).
func set_wires(wires: Dictionary) -> void:
	var old: Array = _wire_hexes.keys()
	_wire_hexes = wires.duplicate()
	var affected := {}
	for h in old:
		affected[h] = true
	for h in _wire_hexes.keys():
		affected[h] = true
	for h in affected.keys():
		_apply(h)


## Spawns/refreshes 3D cover props. level 1 = half cover (low crate),
## level 2 = full cover (tall pillar).
func set_cover(cover: Dictionary) -> void:
	for prop in _cover_props.values():
		prop.queue_free()
	_cover_props.clear()
	for hex in cover.keys():
		_cover_props[hex] = _spawn_cover_prop(hex, int(cover[hex]))


func _spawn_cover_prop(hex: Vector2i, level: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Cover_%d_%d" % [hex.x, hex.y]
	var h := 0.4 if level == 1 else 1.1
	var box := BoxMesh.new()
	box.size = Vector3(0.55, h, 0.55)
	mi.mesh = box
	mi.material_override = _make_prop_material(level)
	var pos := HexCoord.axial_to_world(hex, hex_size)
	pos.y = tile_height * 0.5 + h * 0.5
	mi.position = pos
	add_child(mi)
	return mi


# --- Hover / Selection / Highlight Visuals ---------------------------------

func _update_hover() -> void:
	var hex := _mouse_to_hex()
	var valid := _tiles.has(hex)
	if valid == _has_hover and hex == _hovered:
		return
	var old := _hovered if _has_hover else INVALID_HEX
	_has_hover = valid
	_hovered = hex
	if old != INVALID_HEX:
		_apply(old)
	if valid:
		_apply(hex)
	tile_hovered.emit(hex if valid else INVALID_HEX)


func _apply(hex: Vector2i) -> void:
	if not _tiles.has(hex):
		return
	_set_tile_material(hex, _resolve_material(hex))


func _resolve_material(hex: Vector2i) -> Material:
	if _has_selection and hex == _selected:
		return _selected_material
	if _has_hover and hex == _hovered:
		return _hover_material
	if _highlighted.has(hex):
		return _highlight_material
	if _effect_hexes.has(hex):
		return _effect_material
	if _wire_hexes.has(hex):
		return _wire_material
	return _base_material


func _set_tile_material(hex: Vector2i, mat: Material) -> void:
	var mi: MeshInstance3D = _tile_meshes.get(hex)
	if mi != null:
		mi.material_override = mat


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.55
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.25
	return mat


func _make_prop_material(level: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.5, 0.42) if level == 1 else Color(0.32, 0.3, 0.26)
	mat.metallic = 0.0
	mat.roughness = 0.8
	return mat


# --- Mouse Picking ----------------------------------------------------------

func _mouse_to_hex() -> Vector2i:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return INVALID_HEX
	var mouse_pos := get_viewport().get_mouse_position()
	var origin := cam.project_ray_origin(mouse_pos)
	var normal := cam.project_ray_normal(mouse_pos)

	var query := PhysicsRayQueryParameters3D.create(origin, origin + normal * 10000.0)
	query.collision_mask = 1
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return INVALID_HEX

	var collider: Object = result["collider"]
	if collider == null or not collider.has_meta(&"hex_q"):
		return INVALID_HEX
	return Vector2i(int(collider.get_meta(&"hex_q")), int(collider.get_meta(&"hex_r")))
