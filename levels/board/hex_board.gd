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
## Raw pointer stream used by draggable 3D UI (the look orb). `pointer_down`
## carries the mouse pick Dictionary ({hex, position} or empty). While
## `drag_capture` is true the board suppresses tile selection so the drag owns
## the gesture.
signal pointer_down(pick: Dictionary)
signal pointer_drag(hex: Vector2i, world: Vector3)
signal pointer_up(hex: Vector2i)

var drag_capture := false

@export var board_radius: int = 5
@export var hex_size: float = 1.0
@export var tile_height: float = HexCoord.GROUND_Y * 2.0

@export var hover_color: Color = Color(0.25, 0.85, 1.0)
@export var selected_color: Color = Color(0.88, 0.95, 1.0)
## Base attack area / trajectory (design-doc yellow).
@export var highlight_color: Color = Color(1.0, 0.82, 0.18)
## Optional picks: move destinations, trap spots, shield spots (doc orange).
@export var effect_color: Color = Color(1.0, 0.69, 0.25)
## The acting unit's own hex (doc blue).
@export var origin_color: Color = Color(0.12, 0.5, 0.98)
@export var wire_color: Color = Color(1.0, 0.6, 0.2)

var _mesh: ArrayMesh
var _shape: ConvexPolygonShape3D
var _base_material: ShaderMaterial    # hex overlay: faint grid line only
var _fog_material: ShaderMaterial     # hex overlay: grid line + fog tint
var _decor: Node3D                    # street lamps
var _ground: MeshInstance3D           # continuous street surface
var _hover_material: StandardMaterial3D
var _selected_material: StandardMaterial3D
var _highlight_material: StandardMaterial3D
var _effect_material: StandardMaterial3D
var _origin_material: StandardMaterial3D
var _wire_material: StandardMaterial3D

var _tiles: Dictionary = {}        # Vector2i -> StaticBody3D
var _tile_meshes: Dictionary = {}  # Vector2i -> MeshInstance3D
var _cover_props: Dictionary = {}  # Vector2i -> MeshInstance3D
var _city: CityBuildings             # rectangular building segments (visual)
var _roof_bodies: Dictionary = {}    # Vector2i -> StaticBody3D (roof picking)
var _roof_caps: Dictionary = {}      # Vector2i -> MeshInstance3D (roof highlight)
var _fog_enabled := false
var _visible_hexes: Dictionary = {} # Vector2i -> true (inside friendly sight)

var _hovered: Vector2i = INVALID_HEX
var _has_hover := false
var _selected: Vector2i = INVALID_HEX
var _has_selection := false
var _highlighted: Dictionary = {}  # Vector2i -> true (range / valid destinations)
var _effect_hexes: Dictionary = {} # Vector2i -> true (action effect area)
var _origin_hex: Vector2i = INVALID_HEX
var _has_origin := false
var _wire_hexes: Dictionary = {}   # Vector2i -> true


func _ready() -> void:
	# Tiles are thin overlays on the continuous street; the pick collider
	# keeps the full tile thickness.
	_mesh = HexMesh.build(hex_size * 0.995, 0.01)
	_shape = HexMesh.build_convex_shape(hex_size, tile_height)
	_base_material = _make_overlay_material(0.0)
	_fog_material = _make_overlay_material(1.0)
	_hover_material = _make_material(hover_color)
	_selected_material = _make_material(selected_color)
	_highlight_material = _make_material(highlight_color)
	_effect_material = _make_material(effect_color)
	_origin_material = _make_material(origin_color)
	_wire_material = _make_material(wire_color)
	_build_board()


## A click/tap selects on release, and only if the pointer barely moved —
## so a one-finger camera pan on touch screens doesn't pick a hex.
const TAP_SLOP_PX := 12.0

var _press_pos := Vector2.ZERO
var _pressed := false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover()
		if _pressed and drag_capture:
			var drag_pick := _mouse_pick()
			var drag_hex: Vector2i = drag_pick["hex"] if not drag_pick.is_empty() else INVALID_HEX
			pointer_drag.emit(drag_hex, drag_pick.get("position", Vector3.ZERO))
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_press_pos = event.position
			pointer_down.emit(_mouse_pick())
		elif _pressed:
			_pressed = false
			if drag_capture:
				# The drag (look orb) owns this gesture: commit and stop.
				drag_capture = false
				var up_pick := _mouse_pick()
				var up_hex: Vector2i = up_pick["hex"] if not up_pick.is_empty() else INVALID_HEX
				pointer_up.emit(up_hex)
				return
			if event.position.distance_to(_press_pos) > TAP_SLOP_PX:
				return
			var hex := _mouse_to_hex()
			if _tiles.has(hex):
				select_hex(hex)
				tile_selected.emit(hex)


# --- Board Construction -----------------------------------------------------

func _build_board() -> void:
	for hex in HexCoord.spiral(Vector2i.ZERO, board_radius):
		_spawn_tile(hex)


## Replaces the board with the given tile set (the match map).
func set_map(tiles: Dictionary) -> void:
	for body in _tiles.values():
		body.queue_free()
	_tiles.clear()
	_tile_meshes.clear()
	_highlighted.clear()
	_effect_hexes.clear()
	_has_hover = false
	_has_selection = false
	_has_origin = false
	for hex in tiles.keys():
		_spawn_tile(hex)


## World-space bounds of the board (for camera clamping).
func get_bounds() -> AABB:
	var box := AABB()
	var first := true
	for hex in _tiles.keys():
		var p := hex_to_world(hex)
		if first:
			box = AABB(p, Vector3.ZERO)
			first = false
		else:
			box = box.expand(p)
	return box


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
	mesh_inst.position.y = HexCoord.GROUND_Y + 0.006
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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


## World position of `hex` elevated to `floor` (0 = standing on the tile).
func hex_to_world_at(hex: Vector2i, floor: int = 0) -> Vector3:
	var p := HexCoord.axial_to_world(hex, hex_size)
	p.y = HexCoord.GROUND_Y + floor * HexCoord.FLOOR_HEIGHT
	return p


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
	highlight_origin(INVALID_HEX)


## Marks the acting unit's own hex (design-doc blue). Pass INVALID_HEX to
## clear it.
func highlight_origin(hex: Vector2i) -> void:
	var old := _origin_hex if _has_origin else INVALID_HEX
	var has := _tiles.has(hex)
	_has_origin = has
	_origin_hex = hex if has else INVALID_HEX
	if old != INVALID_HEX:
		_apply(old)
	if has:
		_apply(hex)


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


## Builds the city: clean rectangular buildings (CityBuildings) plus, per
## building hex, a roof-level pick collider (so clicking a rooftop selects
## that hex, not the street behind it) and a thin roof cap that shows
## hover/selection/range highlights on top of the building.
func set_buildings(buildings: Dictionary) -> void:
	if _city == null:
		_city = CityBuildings.new()
		_city.name = "City"
		add_child(_city)
	_city.build(buildings, hex_size)
	_decorate_streets(buildings)
	for n in _roof_bodies.values():
		n.queue_free()
	_roof_bodies.clear()
	_roof_caps.clear()
	var rect_of := {}
	for r in _city.rects:
		for h in r["hexes"]:
			rect_of[h] = r
	for hex in buildings.keys():
		var roof_y := HexCoord.GROUND_Y + int(buildings[hex]) * HexCoord.FLOOR_HEIGHT
		var p := HexCoord.axial_to_world(hex, hex_size)
		# The hex clipped to its building's footprint: the unit still occupies
		# the whole hex, but the roof cap / pick area stops at the wall.
		var poly := _roof_polygon(hex, p, rect_of.get(hex, {}))
		var body := StaticBody3D.new()
		body.name = "Roof_%d_%d" % [hex.x, hex.y]
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta(&"hex_q", hex.x)
		body.set_meta(&"hex_r", hex.y)
		body.position = Vector3(p.x, roof_y - HexCoord.GROUND_Y, p.z)
		var col := CollisionShape3D.new()
		col.shape = HexMesh.build_polygon_shape(poly, tile_height)
		body.add_child(col)
		var cap := MeshInstance3D.new()
		cap.mesh = HexMesh.build_polygon_prism(_inset(poly, 0.06 * hex_size), 0.04)
		cap.position.y = HexCoord.GROUND_Y + 0.03
		cap.visible = false
		body.add_child(cap)
		add_child(body)
		_roof_bodies[hex] = body
		_roof_caps[hex] = cap
		_apply(hex)


# --- Street Decoration --------------------------------------------------------

## Dresses the streets: one continuous street surface (asphalt, straight
## sidewalks and curbs around every building, avenue markings, manholes) and
## street lamps. Purely visual (no collision, no sight blocking).
func _decorate_streets(buildings: Dictionary) -> void:
	_build_ground(buildings)
	_spawn_lamps(buildings)


## Mask resolution for baked sidewalks (pixels per world unit).
const MASK_PPU := 10.0
const SIDEWALK_WIDTH := 0.42
const CURB_WIDTH := 0.07


func _build_ground(buildings: Dictionary) -> void:
	if _ground != null:
		_ground.queue_free()
	var box := get_bounds()
	var margin := 2.5 * hex_size
	var x0 := box.position.x - margin
	var z0 := box.position.z - margin
	var size := Vector2(box.size.x + 2.0 * margin, box.size.z + 2.0 * margin)

	# Bake sidewalks: every building rectangle grown by the sidewalk width
	# (R) and, underneath, by sidewalk + curb (G). Native fill_rect, so fast.
	var w := int(ceil(size.x * MASK_PPU))
	var h := int(ceil(size.y * MASK_PPU))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 1))
	for pass_i in 2:
		var grow := (SIDEWALK_WIDTH + CURB_WIDTH) if pass_i == 0 else SIDEWALK_WIDTH
		var col := Color(0, 1, 0, 1) if pass_i == 0 else Color(1, 1, 0, 1)
		for r in _city.rects:
			var b := BuildingRects.bounds(r, hex_size).grow(grow * hex_size)
			var px := Rect2i(
				int(floor((b.position.x - x0) * MASK_PPU)), int(floor((b.position.y - z0) * MASK_PPU)),
				int(ceil(b.size.x * MASK_PPU)), int(ceil(b.size.y * MASK_PPU)))
			img.fill_rect(px.intersection(Rect2i(0, 0, w, h)), col)
	var mask := ImageTexture.create_from_image(img)

	var mat := ShaderMaterial.new()
	mat.shader = load("res://levels/board/street.gdshader")
	mat.set_shader_parameter("sidewalk_mask", mask)
	mat.set_shader_parameter("mask_origin", Vector2(x0, z0))
	mat.set_shader_parameter("mask_size", Vector2(w, h) / MASK_PPU)
	var edge := hex_size
	mat.set_shader_parameter("map_rect", Vector4(box.position.x - 0.75 * edge, box.position.z - 0.87 * edge,
		box.end.x + 0.75 * edge, box.end.z + 0.87 * edge))
	_set_avenues(mat, buildings)

	var plane := PlaneMesh.new()
	plane.size = size
	_ground = MeshInstance3D.new()
	_ground.name = "StreetSurface"
	_ground.mesh = plane
	_ground.material_override = mat
	_ground.position = Vector3(x0 + size.x * 0.5, HexCoord.GROUND_Y, z0 + size.y * 0.5)
	add_child(_ground)


## Avenues: rows / columns of the map that are (almost) entirely street get
## continuous center lines and zebra crossings where they meet.
func _set_avenues(mat: ShaderMaterial, buildings: Dictionary) -> void:
	var road_rows := {}
	var road_cols := {}
	var row_count := {}
	var col_count := {}
	for hex in _tiles.keys():
		var row := BuildingRects.offset_row(hex)
		row_count[row] = int(row_count.get(row, 0)) + 1
		col_count[hex.x] = int(col_count.get(hex.x, 0)) + 1
		if buildings.has(hex):
			continue
		if not road_rows.has(row):
			road_rows[row] = []
		road_rows[row].append(hex)
		road_cols[hex.x] = int(road_cols.get(hex.x, 0)) + 1
	var rows: Array = []
	for row in road_rows:
		if road_rows[row].size() >= int(row_count[row]) and road_rows[row].size() >= 8:
			rows.append(row)
	var cols: Array = []
	for col in road_cols:
		if int(road_cols[col]) >= int(col_count[col]) * 0.85 and int(road_cols[col]) >= 8:
			cols.append(col)
	if not rows.is_empty():
		var zs: Array = []
		for row in rows:
			for hex in road_rows[row]:
				zs.append(hex_to_world(hex).z)
		# Span between the facing building walls (sidewalk edges), not hex tips.
		var z0: float = zs.min() - hex_size * 0.433
		var z1: float = zs.max() + hex_size * 0.433
		mat.set_shader_parameter("avenue_z", (z0 + z1) * 0.5)
		mat.set_shader_parameter("avenue_z_span", Vector2(z0, z1))
	if not cols.is_empty():
		var x0: float = 1.5 * hex_size * float(cols.min()) - 0.75 * hex_size
		var x1: float = 1.5 * hex_size * float(cols.max()) + 0.75 * hex_size
		mat.set_shader_parameter("avenue_x", (x0 + x1) * 0.5)
		mat.set_shader_parameter("avenue_x_span", Vector2(x0, x1))


## Street lamps on some sidewalk hexes, standing on the sidewalk right against
## the nearest building wall (off the hex center, so units and paths stay
## clear), each with a warm light that pools on the street.
func _spawn_lamps(buildings: Dictionary) -> void:
	if _decor != null:
		_decor.queue_free()
	_decor = Node3D.new()
	_decor.name = "StreetDecor"
	add_child(_decor)
	var rect_of := {}
	for r in _city.rects:
		for h in r["hexes"]:
			rect_of[h] = r
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.18, 0.19, 0.22)
	pole_mat.metallic = 0.6
	pole_mat.roughness = 0.4
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = Color(1.0, 0.86, 0.6)
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.8, 0.5)
	bulb_mat.emission_energy_multiplier = 3.0
	for hex in _tiles.keys():
		if buildings.has(hex) or (absi(hex.x * 73856093 ^ hex.y * 19349663) % 4) != 0:
			continue
		var rect: Dictionary = {}
		for n in HexCoord.neighbors(hex):
			if rect_of.has(n):
				rect = rect_of[n]
				break
		if rect.is_empty():
			continue
		# Nearest point on the building wall, then step out onto the sidewalk.
		var c3 := hex_to_world(hex)
		var c := Vector2(c3.x, c3.z)
		var b := BuildingRects.bounds(rect, hex_size)
		var wall := Vector2(clampf(c.x, b.position.x, b.end.x), clampf(c.y, b.position.y, b.end.y))
		var out2 := (c - wall).normalized()
		if out2 == Vector2.ZERO:
			continue
		var out := Vector3(out2.x, 0, out2.y)
		var base := Vector3(wall.x, HexCoord.GROUND_Y, wall.y) + out * 0.2 * hex_size
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.022
		cyl.bottom_radius = 0.032
		cyl.height = 1.15
		pole.mesh = cyl
		pole.material_override = pole_mat
		pole.position = base + Vector3(0, 0.575, 0)
		_decor.add_child(pole)
		var arm := MeshInstance3D.new()
		var arm_box := BoxMesh.new()
		arm_box.size = Vector3(0.03, 0.03, 0.3)
		arm.mesh = arm_box
		arm.material_override = pole_mat
		arm.position = base + Vector3(0, 1.13, 0) + out * 0.14
		arm.basis = Basis.looking_at(out, Vector3.UP)
		_decor.add_child(arm)
		var bulb := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.06
		sph.height = 0.1
		bulb.mesh = sph
		bulb.material_override = bulb_mat
		bulb.position = base + Vector3(0, 1.1, 0) + out * 0.28
		_decor.add_child(bulb)
		var light := OmniLight3D.new()
		light.position = bulb.position
		light.light_color = Color(1.0, 0.78, 0.5)
		light.light_energy = 1.2
		light.omni_range = 2.6 * hex_size
		light.omni_attenuation = 1.4
		_decor.add_child(light)


func _make_overlay_material(fog_amount: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://levels/board/hex_overlay.gdshader")
	mat.set_shader_parameter("fog_amount", fog_amount)
	mat.set_shader_parameter("hex_size", hex_size)
	return mat


## Hex outline (local to the hex center) intersected with its building's
## rectangle. Falls back to the full hex if there's no rectangle.
func _roof_polygon(hex: Vector2i, center: Vector3, rect: Dictionary) -> PackedVector2Array:
	var hex_poly := HexMesh.ring_polygon(hex_size)
	if rect.is_empty():
		return hex_poly
	var b := BuildingRects.bounds(rect, hex_size)
	var c := Vector2(center.x, center.z)
	var rect_poly := PackedVector2Array([
		b.position - c, Vector2(b.end.x, b.position.y) - c, b.end - c, Vector2(b.position.x, b.end.y) - c,
	])
	var clipped := Geometry2D.intersect_polygons(hex_poly, rect_poly)
	return clipped[0] if not clipped.is_empty() else hex_poly


## Shrinks a convex polygon slightly so roof caps don't z-fight the parapet.
func _inset(poly: PackedVector2Array, amount: float) -> PackedVector2Array:
	var grown := Geometry2D.offset_polygon(poly, -amount)
	return grown[0] if not grown.is_empty() else poly


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
	if _has_origin and hex == _origin_hex:
		return _origin_material
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
	if _fog_enabled and not _visible_hexes.has(hex):
		return _fog_material
	return _base_material


## Fog of war overlay: tiles outside `seen` (hexes some friendly unit can
## see) are darkened.
func set_fog(seen: Dictionary) -> void:
	_fog_enabled = true
	_visible_hexes = seen.duplicate()
	for hex in _tiles.keys():
		_apply(hex)


func _set_tile_material(hex: Vector2i, mat: Material) -> void:
	var cap: MeshInstance3D = _roof_caps.get(hex)
	var highlighted := mat != _base_material and mat != _fog_material
	var mi: MeshInstance3D = _tile_meshes.get(hex)
	if mi != null:
		# Building hexes highlight on the roof cap, not the street tile below.
		mi.material_override = _base_material if (cap != null and highlighted) else mat
	if cap != null:
		cap.material_override = mat
		cap.visible = highlighted


## Highlight overlay: translucent so the street shows through.
func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color, 0.62)
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
	var pick := _mouse_pick()
	return pick.get("hex", INVALID_HEX) if not pick.is_empty() else INVALID_HEX


## Raw mouse raycast against the board. Returns
## { "hex": Vector2i, "position": Vector3 } or an empty Dictionary when the
## pointer is not over a tile.
func _mouse_pick() -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	var mouse_pos := get_viewport().get_mouse_position()
	var origin := cam.project_ray_origin(mouse_pos)
	var normal := cam.project_ray_normal(mouse_pos)

	var query := PhysicsRayQueryParameters3D.create(origin, origin + normal * 10000.0)
	query.collision_mask = 1
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return {}

	var collider: Object = result["collider"]
	if collider == null or not collider.has_meta(&"hex_q"):
		return {}
	return {
		"hex": Vector2i(int(collider.get_meta(&"hex_q")), int(collider.get_meta(&"hex_r"))),
		"position": result["position"],
	}
