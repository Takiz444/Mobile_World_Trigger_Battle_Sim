class_name BoardUnits
extends Node3D
## Visualizes UnitState markers on the hex board: team-colored emissive
## humanoid "Trion body" figures, a facing indicator, a selection ring, and
## name/HP labels. Bailed units are hidden. Units stand on the tile surface
## (HexCoord.GROUND_Y) and are raised by floor * HexCoord.FLOOR_HEIGHT inside or
## on top of buildings.
##
## Fog of war: each unit's `fog` state decides how it is drawn — exact
## (SIGHT), as a pulsing radar ping at `ping_hex` (RADAR), or not at all
## (HIDDEN). Provides tween helpers for the replay controller.


var _hex_size: float = 1.0
var _markers: Dictionary = {}        # UnitState -> Node3D
var _hp_labels: Dictionary = {}      # UnitState -> Label3D
var _figures: Dictionary = {}        # UnitState -> Node3D (rotates to facing)
var _body_materials: Dictionary = {} # UnitState -> Array[StandardMaterial3D]
var _base_colors: Dictionary = {}    # StandardMaterial3D -> Color (opaque)
var _rings: Dictionary = {}          # UnitState -> MeshInstance3D
var _move_tweens: Dictionary = {}    # UnitState -> Tween
var _face_tweens: Dictionary = {}    # UnitState -> Tween
var _ghost: Node3D = null            # translucent movement-destination preview
var _ghost_body: MeshInstance3D = null
var _pings: Dictionary = {}          # UnitState -> Node3D (radar ghost)
var _vision: Node3D = null           # selected character's vision cones
var _map_bounds := Rect2()           # board extent (XZ) — sight ends at the edge


## Clears existing markers and spawns one per unit.
func setup(units: Array[UnitState], hex_size: float) -> void:
	_hex_size = hex_size
	for c in get_children():
		c.queue_free()
	_markers.clear()
	_hp_labels.clear()
	_figures.clear()
	_body_materials.clear()
	_base_colors.clear()
	_rings.clear()
	_pings.clear()
	_vision = null
	_move_tweens.clear()
	_face_tweens.clear()
	_ghost = null
	_ghost_body = null
	for u in units:
		_spawn_marker(u)


## Updates HP labels, fog visibility, and stealth alpha without moving markers.
func update_labels() -> void:
	for u in _markers:
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		if not u.is_bailed:
			_markers[u].visible = u.fog == Visibility.State.SIGHT
		_apply_body_style(u)
	apply_fog()


## Shows/hides markers and radar pings from each unit's fog state.
func apply_fog() -> void:
	for u in _markers:
		var state: int = u.fog
		if not u.is_bailed:
			_markers[u].visible = state == Visibility.State.SIGHT
		var show_ping: bool = state == Visibility.State.RADAR and not u.is_bailed
		var ping: Node3D = _pings.get(u)
		if show_ping:
			if ping == null:
				ping = _build_ping(u)
				_pings[u] = ping
			var p := HexCoord.axial_to_world(u.ping_hex, _hex_size)
			p.y = HexCoord.GROUND_Y
			ping.position = p
			ping.visible = true
		elif ping != null:
			ping.visible = false


## Hard-syncs every marker to the unit's current hex/facing/HP. Kills tweens.
func refresh() -> void:
	for u in _markers:
		_kill_tween(_move_tweens, u)
		_kill_tween(_face_tweens, u)
		var root: Node3D = _markers[u]
		root.scale = Vector3.ONE
		root.position = _world_pos(u)
		root.visible = not u.is_bailed and u.fog == Visibility.State.SIGHT
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		(_figures[u] as Node3D).rotation.y = _facing_yaw(u.facing)


## Places one marker at its unit's position/facing immediately (no tween).
func snap(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	_kill_tween(_face_tweens, u)
	root.position = _world_pos(u)
	(_figures[u] as Node3D).rotation.y = _facing_yaw(u.facing)


## Shows the selection ring under `u` (or clears it when null).
func set_selected(u: UnitState) -> void:
	for key in _rings:
		var ring: MeshInstance3D = _rings[key]
		ring.visible = key == u


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


## Turns the figure toward a new facing (shortest way round).
func tween_facing(u: UnitState, facing: int, duration: float = 0.35) -> void:
	var fig: Node3D = _figures.get(u)
	if fig == null:
		return
	_kill_tween(_face_tweens, u)
	var target := fig.rotation.y + wrapf(_facing_yaw(facing) - fig.rotation.y, -PI, PI)
	var tw := fig.create_tween()
	tw.tween_property(fig, "rotation:y", target, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_face_tweens[u] = tw


## Quick red flash on a unit that took damage.
func flash_hit(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	var mats: Array = _body_materials.get(u, [])
	if root == null or mats.is_empty():
		return
	var tw := root.create_tween().set_parallel(true)
	for m in mats:
		var mat: StandardMaterial3D = m
		tw.tween_property(mat, "albedo_color", Color(1.0, 0.18, 0.18), 0.1)
	tw.chain()
	for m in mats:
		var mat: StandardMaterial3D = m
		tw.tween_property(mat, "albedo_color", _shade(u, mat), 0.28)
	tw.chain().tween_callback(_apply_body_style.bind(u))


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


# --- Ghost Preview ----------------------------------------------------------

## Shows a translucent "ghost" of `u` at `hex` (movement destination preview).
func show_ghost(u: UnitState, hex: Vector2i, floor: int = 0) -> void:
	if _ghost == null:
		_ghost = _build_ghost()
	var team_color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)
	var mat: StandardMaterial3D = _ghost_body.material_override
	mat.albedo_color = Color(team_color.r, team_color.g, team_color.b, 0.35)
	mat.emission = team_color
	var p := HexCoord.axial_to_world(hex, _hex_size)
	p.y = HexCoord.GROUND_Y + floor * HexCoord.FLOOR_HEIGHT
	_ghost.position = p
	_ghost.visible = true


# --- Vision Cones --------------------------------------------------------------

## Draws one character's vision at (hex, floor) facing `facing`, occluded by
## the city in 3D:
##   - vision cones (focus, peripheral, awareness) are built from physics
##     raycasts fired from the character's eye height against the building
##     solids (CityBuildings.COLLISION_LAYER): every ray stops at the first
##     wall, so the cone has the true shape of what the character can see.
##     Inside a building the character sees out only within WINDOW_REACH of
##     the outer wall (`own_rect` is the building it stands in, if any).
##   - shadow-casting lights at eye height (a narrow focus spotlight, a wide
##     peripheral one, and a soft awareness glow) — light ray casting: the
##     buildings throw real shadows, so the lit area is the visible area.
## Planning shows it at the unit's projected position and facing.
func show_vision(u: UnitState, hex: Vector2i, floor: int, facing: int, own_rect: Dictionary = {}) -> void:
	clear_vision()
	var team_color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)
	var saved := [u.hex, u.floor, u.facing]
	u.hex = hex
	u.floor = floor
	u.facing = facing
	var p := Visibility.profile(u)
	u.hex = saved[0]
	u.floor = saved[1]
	u.facing = saved[2]

	var step := HexCoord.SQRT3 * _hex_size  # center-to-center hex distance
	var fwd := _facing_vector(facing)
	var origin := HexCoord.axial_to_world(hex, _hex_size)
	origin.y = HexCoord.GROUND_Y + floor * HexCoord.FLOOR_HEIGHT
	var eye := origin + Vector3(0, Visibility.EYE_HEIGHT * HexCoord.FLOOR_HEIGHT, 0)
	var focus_r := (int(p["focus_range"]) + 0.5) * step
	var peri_r := (int(p["peripheral_range"]) + 0.5) * step
	var aware_r := (int(p["awareness"]) + 0.5) * step

	_vision = Node3D.new()
	_vision.name = "VisionCones"
	_vision.position = origin + Vector3(0, 0.04, 0)
	add_child(_vision)
	_vision.add_child(_occluded_fan(eye, fwd, float(p["peripheral_half"]), peri_r, own_rect, Color(team_color, 0.08)))
	_vision.add_child(_occluded_fan(eye, fwd, float(p["focus_half"]), focus_r, own_rect, Color(team_color, 0.14)))
	_vision.add_child(_occluded_fan(eye, fwd, 180.0, aware_r, own_rect, Color(1, 1, 1, 0.05)))

	# Light ray casting: real shadowed lights from the eye.
	# Beams start just in front of the figure so its own body doesn't shadow them.
	var tint := team_color.lerp(Color.WHITE, 0.55)
	var lens := eye - _vision.position + fwd * 0.45 * _hex_size
	_vision.add_child(_eye_light(lens, fwd, float(p["focus_half"]), focus_r, tint, 6.0))
	_vision.add_child(_eye_light(lens, fwd, float(p["peripheral_half"]), peri_r, tint, 2.5))
	var glow := OmniLight3D.new()
	glow.position = eye - _vision.position + Vector3(0, 1.0, 0)
	glow.omni_range = aware_r
	glow.light_color = tint
	glow.light_energy = 1.2
	glow.shadow_enabled = true
	_vision.add_child(glow)


## Board extent in XZ (vision rays stop at the edge of the map).
func set_map_bounds(bounds: Rect2) -> void:
	_map_bounds = bounds


func clear_vision() -> void:
	if _vision != null:
		_vision.queue_free()
		_vision = null


## Spotlight from the eye along `fwd` (tilted slightly down so the street
## catches the beam); buildings cast its shadows.
func _eye_light(local_eye: Vector3, fwd: Vector3, half_deg: float, radius: float, color: Color, energy: float) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.position = local_eye
	light.spot_range = radius
	light.spot_angle = clampf(half_deg, 1.0, 89.0)
	light.spot_attenuation = 0.6
	light.light_color = color
	light.light_energy = energy
	light.shadow_enabled = true
	var aim := (fwd + Vector3(0, -0.22, 0)).normalized()
	light.basis = Basis.looking_at(aim, Vector3.UP)
	return light


## Distance a sight ray from `eye` along horizontal `dir` travels before a
## wall stops it (physics raycast against the building solids). Inside a
## building, the ray may only leave through the outer wall within
## Visibility.WINDOW_REACH of the character.
func _ray_reach(space: PhysicsDirectSpaceState3D, eye: Vector3, dir: Vector3, radius: float, own_rect: Dictionary) -> float:
	var start := eye
	var limit := radius
	if _map_bounds.has_area():
		limit = minf(limit, _box_exit_2d(Vector2(eye.x, eye.z), Vector2(dir.x, dir.z), _map_bounds))
	if not own_rect.is_empty():
		var b := BuildingRects.bounds(own_rect, _hex_size)
		var exit := _box_exit_2d(Vector2(eye.x, eye.z), Vector2(dir.x, dir.z), b)
		if exit > Visibility.WINDOW_REACH * _hex_size:
			return exit  # vision stops at the inside of the wall
		start = eye + dir * exit  # leave through the window
	var q := PhysicsRayQueryParameters3D.create(start, eye + dir * limit, CityBuildings.COLLISION_LAYER)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return limit
	var hp: Vector3 = hit["position"]
	return Vector2(hp.x - eye.x, hp.z - eye.z).length()


## Distance from `p` (inside `b`) along `d` to where it exits the rectangle.
func _box_exit_2d(p: Vector2, d: Vector2, b: Rect2) -> float:
	var t := INF
	if d.x > 1e-6:
		t = minf(t, (b.end.x - p.x) / d.x)
	elif d.x < -1e-6:
		t = minf(t, (b.position.x - p.x) / d.x)
	if d.y > 1e-6:
		t = minf(t, (b.end.y - p.y) / d.y)
	elif d.y < -1e-6:
		t = minf(t, (b.position.y - p.y) / d.y)
	return maxf(0.0, t)


## A flat translucent fan whose edge is the raycast reach in each direction.
func _occluded_fan(eye: Vector3, fwd: Vector3, half_deg: float, radius: float, own_rect: Dictionary, color: Color) -> MeshInstance3D:
	var space := get_world_3d().direct_space_state
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := maxi(12, int(half_deg / 1.5))
	var prev := Vector3.ZERO
	for i in segments + 1:
		var a := deg_to_rad(-half_deg + 2.0 * half_deg * i / segments)
		var dir := fwd.rotated(Vector3.UP, a)
		var v := dir * _ray_reach(space, eye, dir, radius, own_rect)
		if i > 0:
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3.ZERO)
			st.add_vertex(prev)
			st.add_vertex(v)
		prev = v
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mi.material_override = mat
	return mi


func clear_ghost() -> void:
	if _ghost != null:
		_ghost.visible = false


func _build_ghost() -> Node3D:
	var root := Node3D.new()
	root.name = "GhostPreview"

	var ring := MeshInstance3D.new()
	ring.name = "GhostRing"
	var ring_cyl := CylinderMesh.new()
	ring_cyl.top_radius = 0.56
	ring_cyl.bottom_radius = 0.56
	ring_cyl.height = 0.06
	ring.mesh = ring_cyl
	ring.material_override = _make_emissive(Color(1.0, 0.9, 0.3), 1.2)
	ring.position = Vector3(0, 0.03, 0)
	root.add_child(ring)

	var body := MeshInstance3D.new()
	body.name = "GhostBody"
	var silhouette := CapsuleMesh.new()  # matches the agent figure's height
	silhouette.radius = 0.22
	silhouette.height = 1.4
	body.mesh = silhouette
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.35)
	mat.metallic = 0.0
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = Color(1, 1, 1)
	mat.emission_energy_multiplier = 1.1
	body.material_override = mat
	body.position = Vector3(0, 0.7, 0)
	root.add_child(body)
	_ghost_body = body

	add_child(root)
	root.visible = false
	return root


# --- Construction -----------------------------------------------------------

func _spawn_marker(u: UnitState) -> void:
	var root := Node3D.new()
	root.name = "Unit_" + u.display_name()
	root.position = _world_pos(u)

	var team_color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)

	# Selection ring (hidden until this unit is selected).
	var ring := MeshInstance3D.new()
	ring.name = "SelectionRing"
	var ring_cyl := CylinderMesh.new()
	ring_cyl.top_radius = 0.5
	ring_cyl.bottom_radius = 0.5
	ring_cyl.height = 0.04
	ring.mesh = ring_cyl
	ring.material_override = _make_emissive(Color(1.0, 0.9, 0.3), 2.5)
	ring.position = Vector3(0, 0.02, 0)
	ring.visible = false
	root.add_child(ring)

	# Team base ring: always-on team identity at the unit's feet.
	var base := MeshInstance3D.new()
	base.name = "TeamRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.3
	torus.outer_radius = 0.36
	base.mesh = torus
	base.material_override = _make_emissive(team_color, 1.6)
	base.position.y = 0.03
	root.add_child(base)

	var figure := _build_figure(u, team_color)
	figure.scale = Vector3.ONE * 1.15
	figure.rotation.y = _facing_yaw(u.facing)
	root.add_child(figure)

	# Name + HP labels (always face the camera). Depth-tested so they are
	# hidden behind solid geometry instead of floating on top of it.
	var name_label := Label3D.new()
	name_label.text = u.unit_data.unit_name
	name_label.position = Vector3(0, 2.35, 0)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.pixel_size = 0.016
	name_label.outline_size = 8
	name_label.modulate = team_color
	root.add_child(name_label)

	var label := Label3D.new()
	label.text = str(u.trion_hp)
	label.position = Vector3(0, 1.75, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.02
	label.outline_size = 8
	root.add_child(label)

	add_child(root)
	_markers[u] = root
	_hp_labels[u] = label
	_figures[u] = figure
	_rings[u] = ring


## A low-poly Border agent in a Trion combat suit, styled like the city:
## matte team-colored jacket, dark trousers and boots, skin-tone head with
## hair, a glowing team emblem, and a role weapon from the loadout (glowing
## blade for attackers, long rifle for snipers, floating Trion cube for
## shooters). Local +Z is "forward"; the node rotates to the unit's facing.
func _build_figure(u: UnitState, team_color: Color) -> Node3D:
	var fig := Node3D.new()
	fig.name = "Figure"
	var xray := _make_xray(team_color)
	var suit := _part_material(u, team_color.lerp(Color(0.85, 0.88, 0.92), 0.15), xray)
	var dark := _part_material(u, Color(0.16, 0.18, 0.22), xray)
	var boots := _part_material(u, Color(0.08, 0.08, 0.1), xray)
	var skin := _part_material(u, Color(0.93, 0.79, 0.67), xray)
	var hair := _part_material(u, Color(0.12, 0.1, 0.1) if u.team == 0 else Color(0.32, 0.2, 0.14), xray)
	var glow := _make_emissive(team_color.lightened(0.35), 2.2)

	for side in [-1.0, 1.0]:
		fig.add_child(_part(BoxMesh.new(), Vector3(0.12, 0.09, 0.2), Vector3(0.1 * side, 0.045, 0.03), boots))
		fig.add_child(_capsule(0.065, 0.5, Vector3(0.1 * side, 0.34, 0), dark))
		fig.add_child(_capsule(0.055, 0.46, Vector3(0.24 * side, 0.84, 0.01), suit, Vector3(0, 0, -0.12 * side)))
		fig.add_child(_part(SphereMesh.new(), Vector3(0.1, 0.1, 0.1), Vector3(0.27 * side, 0.58, 0.03), skin))
		# Shoulder trim (Trion suit seams).
		fig.add_child(_part(BoxMesh.new(), Vector3(0.12, 0.04, 0.2), Vector3(0.19 * side, 1.07, 0), glow))
	fig.add_child(_part(BoxMesh.new(), Vector3(0.3, 0.14, 0.18), Vector3(0, 0.62, 0), dark))
	var torso := _capsule(0.17, 0.56, Vector3(0, 0.88, 0), suit)
	torso.scale = Vector3(1.0, 1.0, 0.72)
	fig.add_child(torso)
	fig.add_child(_part(BoxMesh.new(), Vector3(0.36, 0.06, 0.24), Vector3(0, 0.66, 0), boots))  # belt
	fig.add_child(_part(BoxMesh.new(), Vector3(0.1, 0.1, 0.03), Vector3(0, 0.96, 0.125), glow))  # emblem
	fig.add_child(_part(SphereMesh.new(), Vector3(0.25, 0.27, 0.25), Vector3(0, 1.27, 0), skin))
	var hair_cap := _part(SphereMesh.new(), Vector3(0.27, 0.2, 0.28), Vector3(0, 1.34, -0.02), hair)
	fig.add_child(hair_cap)

	_add_weapon(fig, u, team_color)
	_body_materials[u] = [suit, dark, boots, skin, hair]
	return fig


## Role weapon from the loadout: melee blade, sniper rifle, or Trion cube.
func _add_weapon(fig: Node3D, u: UnitState, team_color: Color) -> void:
	var melee := false
	var sniper := false
	var shooter := false
	for c in u.unit_data.main_trigger_slots:
		var card: TriggerCard = c
		if card == null:
			continue
		if card.card_type == TriggerCard.CardType.MELEE:
			melee = true
		elif card.card_type == TriggerCard.CardType.RANGED:
			if card.attack_range >= 9:
				sniper = true
			else:
				shooter = true
	var metal := _make_material(Color(0.28, 0.3, 0.34))
	metal.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	if sniper:
		var rifle := _part(BoxMesh.new(), Vector3(0.06, 0.08, 0.95), Vector3(0.22, 0.8, 0.28), metal)
		rifle.rotation.x = -0.12
		fig.add_child(rifle)
		fig.add_child(_part(CylinderMesh.new(), Vector3(0.05, 0.16, 0.05), Vector3(0.22, 0.88, 0.2), metal, Vector3(PI / 2, 0, 0)))
	elif melee:
		var blade := _part(BoxMesh.new(), Vector3(0.035, 0.012, 0.72), Vector3(0.28, 0.6, 0.36), _make_emissive(Color(0.9, 0.97, 1.0), 2.0))
		blade.rotation.x = 0.45
		fig.add_child(blade)
		fig.add_child(_part(BoxMesh.new(), Vector3(0.05, 0.05, 0.16), Vector3(0.28, 0.58, 0.04), metal))
	if shooter and not sniper:
		var cube := _part(BoxMesh.new(), Vector3(0.15, 0.15, 0.15), Vector3(-0.34, 1.05, 0.2), _make_emissive(team_color.lightened(0.5), 2.4))
		fig.add_child(cube)
		var spin := cube.create_tween().set_loops()
		spin.tween_property(cube, "rotation:y", TAU, 2.4).from(0.0)


func _part_material(u: UnitState, color: Color, xray: Material) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.75
	mat.next_pass = xray
	_base_colors[mat] = color
	return mat


func _part(mesh: PrimitiveMesh, size: Vector3, pos: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	if mesh is BoxMesh:
		(mesh as BoxMesh).size = size
	elif mesh is SphereMesh:
		(mesh as SphereMesh).radius = size.x * 0.5
		(mesh as SphereMesh).height = size.y
	elif mesh is CylinderMesh:
		(mesh as CylinderMesh).top_radius = size.x * 0.5
		(mesh as CylinderMesh).bottom_radius = size.x * 0.5
		(mesh as CylinderMesh).height = size.y
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	return mi


func _capsule(radius: float, height: float, pos: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = height
	cap.radial_segments = 12
	cap.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = cap
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	return mi


## World position of a unit standing on the tile surface / its floor.
func _world_pos(u: UnitState) -> Vector3:
	var p := HexCoord.axial_to_world(u.hex, _hex_size)
	p.y = HexCoord.GROUND_Y + u.floor * HexCoord.FLOOR_HEIGHT
	return p


## Opaque body normally; translucent only while Bagworm is active (opaque
## bodies avoid sorting artifacts against tiles and buildings).
func _apply_body_style(u: UnitState) -> void:
	for m in _body_materials.get(u, []):
		var mat: StandardMaterial3D = m
		mat.albedo_color = _shade(u, mat)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if u.stealth_active else BaseMaterial3D.TRANSPARENCY_DISABLED


## Radar Signal marker: a pulsing team-colored ring with a "?" — presence
## only, no identity or HP (GDD 4.3).
func _build_ping(u: UnitState) -> Node3D:
	var color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)
	var root := Node3D.new()
	root.name = "RadarPing"

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.55
	ring.mesh = torus
	var mat := _make_emissive(color, 2.0)
	mat.albedo_color = Color(color.r, color.g, color.b, 0.75)
	ring.material_override = mat
	ring.position.y = 0.06
	root.add_child(ring)

	var q := Label3D.new()
	q.text = "?"
	q.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	q.pixel_size = 0.02
	q.outline_size = 8
	q.modulate = color
	q.position.y = 0.6
	root.add_child(q)

	add_child(root)
	var tw := ring.create_tween().set_loops()
	tw.tween_property(ring, "scale", Vector3(1.35, 1.0, 1.35), 0.7)
	tw.tween_property(ring, "scale", Vector3.ONE, 0.7)
	return root


## Yaw (radians) that points the figure's local +Z along `facing`.
func _facing_yaw(facing: int) -> float:
	var fwd := _facing_vector(facing)
	return atan2(fwd.x, fwd.z)


## A part's color with stealth applied (semi-transparent under Bagworm).
func _shade(u: UnitState, mat: StandardMaterial3D) -> Color:
	var base: Color = _base_colors.get(mat, Color(1, 1, 1))
	return Color(base.r, base.g, base.b, 0.35 if u.stealth_active else 1.0)


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
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.5
	return mat


## X-ray pass: draws a flat team-colored silhouette only where the unit is
## hidden behind something (inverted depth test), so units inside buildings
## or behind towers stay trackable.
func _make_xray(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color, 0.45)
	mat.depth_test = BaseMaterial3D.DEPTH_TEST_INVERTED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return mat


func _make_emissive(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat
