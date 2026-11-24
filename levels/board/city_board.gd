class_name CityBoard
extends Node3D
## The battlefield in 3D: a continuous street surface (asphalt, sidewalks,
## avenue markings, lamps) and the city's buildings, with free picking (no
## tiles). Tapping the board picks a point on the street or on a roof.
##
## Planning overlays: range circles, planned routes, target markers, and the
## Spider wires on the ground.

signal point_hovered(point: Vector2, level: int)
## A tap on the street (level 0) or a roof (level = its floors); building is
## the index of the tapped building segment, or -1 on the street.
signal point_selected(point: Vector2, level: int, building: int)

@export var hex_size: float = 1.0

const TAP_SLOP_PX := 12.0
## Physics layer of the roof pick bodies.
const PICK_LAYER := 1

var _tiles: Dictionary = {}        # map hexes of the play area (street dressing)
var _bounds := Rect2()
var _city: CityBuildings
var _ground: MeshInstance3D
var _decor: Node3D
var _roofs: Node3D
var _overlay: Node3D               # range circles, routes, markers
var _wires: Node3D
var _press_pos := Vector2.ZERO
var _pressed := false
## Screen position of the tap being reported by point_selected (INF otherwise),
## so listeners can also hit-test what is drawn there (e.g. a character's body).
var last_tap_screen := Vector2.INF
## The point point_selected reports for a tap that misses the board.
const OFF_BOARD := Vector2(100000, 100000)
var _hover := Vector2.INF


func _ready() -> void:
	_overlay = Node3D.new()
	_overlay.name = "Overlays"
	add_child(_overlay)
	_wires = Node3D.new()
	_wires.name = "Wires"
	add_child(_wires)


## A click/tap selects on release, and only if the pointer barely moved,
## so a one-finger camera pan on touch screens doesn't pick a point.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := pick(event.position)
		if not hit.is_empty() and (hit["point"] as Vector2).distance_to(_hover) > 0.05:
			_hover = hit["point"]
			last_tap_screen = event.position
			point_hovered.emit(hit["point"], int(hit["level"]))
			last_tap_screen = Vector2.INF
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_press_pos = event.position
		elif _pressed:
			_pressed = false
			if event.position.distance_to(_press_pos) > TAP_SLOP_PX:
				return
			# Off the board still reports (as OFF_BOARD): a figure standing
			# at the edge can be drawn over the sky.
			var hit := pick(event.position)
			if hit.is_empty():
				hit = { "point": OFF_BOARD, "level": 0, "building": -1 }
			last_tap_screen = event.position
			point_selected.emit(hit["point"], int(hit["level"]), int(hit["building"]))
			last_tap_screen = Vector2.INF


## What lies under screen position `screen`: {point, level, building} — a
## roof if one is in the way, else the street — or {} off the board.
func pick(screen: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	var origin := cam.project_ray_origin(screen)
	var normal := cam.project_ray_normal(screen)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + normal * 10000.0)
	query.collision_mask = PICK_LAYER
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and (hit["collider"] as Object).has_meta(&"floors"):
		var p: Vector3 = hit["position"]
		var col: Object = hit["collider"]
		return { "point": Vector2(p.x, p.z), "level": int(col.get_meta(&"floors")), "building": int(col.get_meta(&"index")) }
	# The street plane.
	if absf(normal.y) < 1e-6:
		return {}
	var t := (HexCoord.GROUND_Y - origin.y) / normal.y
	if t < 0.0:
		return {}
	var g := origin + normal * t
	var p2 := Vector2(g.x, g.z)
	if _bounds.has_area() and not _bounds.has_point(p2):
		return {}
	return { "point": p2, "level": 0, "building": -1 }


# --- Map ------------------------------------------------------------------------

## The play area: its map hexes (for the street dressing) and world bounds.
func set_map(tiles: Dictionary, bounds: Rect2) -> void:
	_tiles = tiles.duplicate()
	_bounds = bounds


func get_bounds() -> AABB:
	return AABB(Vector3(_bounds.position.x, 0.0, _bounds.position.y), Vector3(_bounds.size.x, 0.0, _bounds.size.y))


func get_rect() -> Rect2:
	return _bounds


## World position of a ground point at `level` (the surface a character stands on).
func world_at(p: Vector2, level: int = 0) -> Vector3:
	return Vector3(p.x, HexCoord.GROUND_Y + level * HexCoord.FLOOR_HEIGHT, p.y)


## Map hex center (used by the street dressing).
func hex_to_world(hex: Vector2i) -> Vector3:
	var p := HexCoord.axial_to_world(hex, hex_size)
	p.y = HexCoord.GROUND_Y
	return p


## Builds the city: buildings (CityBuildings), the dressed street, and a
## roof-level pick body per building segment.
func set_buildings(buildings: Dictionary) -> void:
	if _city == null:
		_city = CityBuildings.new()
		_city.name = "City"
		add_child(_city)
	_city.build(buildings, hex_size)
	_decorate_streets(buildings)
	if _roofs != null:
		_roofs.queue_free()
	_roofs = Node3D.new()
	_roofs.name = "RoofPicks"
	add_child(_roofs)
	for i in _city.rects.size():
		var r: Dictionary = _city.rects[i]
		var b := BuildingRects.bounds(r, hex_size)
		var body := StaticBody3D.new()
		body.collision_layer = PICK_LAYER
		body.collision_mask = 0
		body.set_meta(&"floors", int(r["floors"]))
		body.set_meta(&"index", i)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(b.size.x, 0.05, b.size.y)
		shape.shape = box
		body.add_child(shape)
		body.position = Vector3(b.get_center().x, HexCoord.GROUND_Y + int(r["floors"]) * HexCoord.FLOOR_HEIGHT, b.get_center().y)
		_roofs.add_child(body)


# --- Overlays -------------------------------------------------------------------

func clear_overlays() -> void:
	for c in _overlay.get_children():
		c.queue_free()


## A soft ring on the ground (range of an action, reach of a move).
func add_range(center: Vector2, level: int, radius: float, color: Color) -> void:
	if radius <= 0.01:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = _ring_mesh(radius, 0.06 * hex_size, color)
	mi.position = world_at(center, level) + Vector3(0, 0.03, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _vertex_material()
	_overlay.add_child(mi)


## A planned route: a ribbon through `points` (world positions).
func add_path(points: Array, color: Color, width: float = 0.09) -> void:
	if points.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, points.size()):
		var a: Vector3 = points[i - 1] + Vector3(0, 0.05, 0)
		var b: Vector3 = points[i] + Vector3(0, 0.05, 0)
		var along := b - a
		if along.length() < 0.001:
			continue
		var side := along.cross(Vector3.UP).normalized() * width * 0.5 * hex_size
		st.set_color(color)
		st.add_vertex(a - side)
		st.add_vertex(a + side)
		st.add_vertex(b + side)
		st.add_vertex(a - side)
		st.add_vertex(b + side)
		st.add_vertex(b - side)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _vertex_material()
	_overlay.add_child(mi)


## A target marker: a small filled disc with a ring.
func add_marker(p: Vector2, level: int, color: Color, size: float = 0.35) -> void:
	add_range(p, level, size, color)
	var mi := MeshInstance3D.new()
	mi.mesh = _disc_mesh(size * 0.45, Color(color, color.a * 0.6))
	mi.position = world_at(p, level) + Vector3(0, 0.035, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _vertex_material()
	_overlay.add_child(mi)


## Spider wires on the street: a glowing disc per wire, in its team colour.
func set_wires(wires: Array) -> void:
	for c in _wires.get_children():
		c.queue_free()
	for w in wires:
		var color := BoardUnits.team_color(int(w["team"]))
		var mi := MeshInstance3D.new()
		mi.mesh = _disc_mesh(MatchState.WIRE_RADIUS, Color(color, 0.16))
		mi.position = world_at(w["pos"], 0) + Vector3(0, 0.02, 0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = _vertex_material()
		_wires.add_child(mi)
		var ring := MeshInstance3D.new()
		ring.mesh = _ring_mesh(MatchState.WIRE_RADIUS, 0.05, Color(color, 0.7))
		ring.position = mi.position + Vector3(0, 0.005, 0)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.material_override = _vertex_material()
		_wires.add_child(ring)


func _vertex_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	return mat


## A flat ring that fades out on both edges (no hard lines).
func _ring_mesh(radius: float, width: float, color: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(32, int(radius * 24.0))
	var clear := Color(color, 0.0)
	var r0 := maxf(0.0, radius - width)
	var r1 := radius + width
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		for band in [[r0, clear, radius, color], [radius, color, r1, clear]]:
			var ra: float = band[0]
			var ca: Color = band[1]
			var rb: float = band[2]
			var cb: Color = band[3]
			st.set_color(ca)
			st.add_vertex(d0 * ra)
			st.set_color(cb)
			st.add_vertex(d0 * rb)
			st.add_vertex(d1 * rb)
			st.set_color(ca)
			st.add_vertex(d0 * ra)
			st.set_color(cb)
			st.add_vertex(d1 * rb)
			st.set_color(ca)
			st.add_vertex(d1 * ra)
	return st.commit()


func _disc_mesh(radius: float, color: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(24, int(radius * 20.0))
	var edge := Color(color, 0.0)
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		st.set_color(color)
		st.add_vertex(Vector3.ZERO)
		st.set_color(edge)
		st.add_vertex(Vector3(cos(a0), 0, sin(a0)) * radius)
		st.add_vertex(Vector3(cos(a1), 0, sin(a1)) * radius)
	return st.commit()


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
	var margin := 1.5 * hex_size
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
	mat.shader = GfxLite.shader("res://levels/board/street.gdshader")
	mat.set_shader_parameter("sidewalk_mask", mask)
	mat.set_shader_parameter("mask_origin", Vector2(x0, z0))
	mat.set_shader_parameter("mask_size", Vector2(w, h) / MASK_PPU)
	mat.set_shader_parameter("map_rect", Vector4(box.position.x, box.position.z, box.end.x, box.end.z))
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
	GfxLite.lit(pole_mat)
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = Color(1.0, 0.86, 0.6)
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.8, 0.5)
	bulb_mat.emission_energy_multiplier = 3.0
	GfxLite.glow(bulb_mat, Color(1.0, 0.8, 0.5), 3.0)
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
		light.light_energy = 1.0
		light.omni_range = 2.8 * hex_size
		light.omni_attenuation = 1.6
		_decor.add_child(light)


