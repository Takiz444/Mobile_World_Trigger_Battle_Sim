class_name BoardUnits
extends Node3D
## Visualizes UnitState markers on the hex board: team-colored emissive
## humanoid "Trion body" figures, a facing indicator, a selection ring, and
## name/HP labels. Bailed units are hidden. Units stand on the tile surface
## (HexCoord.GROUND_Y) and are raised by floor * HexCoord.FLOOR_HEIGHT inside or
## on top of buildings.
##
## Fog of war: each unit's `fog` state decides how it is drawn — exact
## (SIGHT), as a pulsing radar ping at `ping_pos` (RADAR), or not at all
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
var _vision: Node3D = null           # selected character's vision shape
var _squad_vision: Node3D = null     # faint vision of the rest of the squad
var _squad_vision_key := ""
## The selected character's vision outline in world space (for the spotlight).
var _vision_outline := PackedVector3Array()
## World distance over which a vision area fades out at its edge.
const EDGE_FADE := 1.4
var _vision_center := Vector3.ZERO
var _map_bounds := Rect2()           # board extent (XZ) — sight ends at the edge
var _poses: Dictionary = {}          # UnitState -> Node3D (squash / lunge / hop pivot)
var _pose_tweens: Dictionary = {}    # UnitState -> Tween
var _hp_bars: Dictionary = {}        # UnitState -> MeshInstance3D (hp_bar.gdshader)
var _hp_shown: Dictionary = {}       # UnitState -> HP fraction the bar shows
var _selected: UnitState = null
var _time := 0.0
var _hp_material: ShaderMaterial

## One-shot combat effects (tracers, slashes, popups); rebuilt by setup().
var fx: BoardFx

const TEAM_COLORS: Array[Color] = [Color(0.15, 0.62, 1.0), Color(1.0, 0.36, 0.2)]
const SELECT_COLOR := Color(1.0, 0.9, 0.3)
const HIT_COLOR := Color(1.0, 0.2, 0.18)


## Team identity color. Blue vs orange stays distinguishable under the common
## forms of color blindness; the team ring's shape (circle vs diamond) and the
## facing chevron back it up.
static func team_color(team: int) -> Color:
	return TEAM_COLORS[clampi(team, 0, 1)]


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
	_squad_vision = null
	_squad_vision_key = ""
	_move_tweens.clear()
	_face_tweens.clear()
	_ghost = null
	_ghost_body = null
	_poses.clear()
	_pose_tweens.clear()
	_hp_bars.clear()
	_hp_shown.clear()
	_selected = null
	fx = BoardFx.new()
	fx.name = "Fx"
	add_child(fx)
	for u in units:
		_spawn_marker(u)


## Idle life: figures breathe and bob slightly out of phase, and the selected
## unit's ring pulses. Cosmetic only (touches the figure node, never the
## marker root that the replay tweens).
func _process(delta: float) -> void:
	_time += delta
	var i := 0
	for u in _figures:
		var fig: Node3D = _figures[u]
		if fig.is_visible_in_tree():
			var t := _time * 2.1 + i * 1.7
			fig.position.y = 0.012 + sin(t) * 0.012
			fig.scale = Vector3(1.15, 1.15 * (1.0 + sin(t + 0.6) * 0.012), 1.15)
		i += 1
	if _selected != null and _rings.has(_selected):
		var ring: MeshInstance3D = _rings[_selected]
		var k := 1.0 + 0.07 * sin(_time * 4.0)
		ring.scale = Vector3(k, 1.0, k)
		ring.rotation.y = _time * 0.6


## Updates HP labels, fog visibility, and stealth alpha without moving markers.
func update_labels() -> void:
	for u in _markers:
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		_set_hp_bar(u, true)
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
			var p := Vector3(u.ping_pos.x, HexCoord.GROUND_Y, u.ping_pos.y)
			ping.position = p
			ping.visible = true
		elif ping != null:
			ping.visible = false


## Hard-syncs every marker to the unit's current hex/facing/HP. Kills tweens.
func refresh() -> void:
	for u in _markers:
		_kill_tween(_move_tweens, u)
		_kill_tween(_face_tweens, u)
		_kill_tween(_pose_tweens, u)
		_reset_pose(u)
		var root: Node3D = _markers[u]
		root.scale = Vector3.ONE
		root.position = _world_pos(u)
		root.visible = not u.is_bailed and u.fog == Visibility.State.SIGHT
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		_set_hp_bar(u, false)
		(_figures[u] as Node3D).rotation.y = _facing_yaw(u.facing)


## Places one marker at its unit's position/facing immediately (no tween).
func snap(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	_kill_tween(_face_tweens, u)
	_kill_tween(_pose_tweens, u)
	_reset_pose(u)
	root.position = _world_pos(u)
	(_figures[u] as Node3D).rotation.y = _facing_yaw(u.facing)


## Shows the selection ring under `u` (or clears it when null).
func set_selected(u: UnitState) -> void:
	_selected = u
	for key in _rings:
		var ring: MeshInstance3D = _rings[key]
		ring.visible = key == u


## Hidden-in-plain-sight meshes with materials the board only uses later
## (a Bagworm-stealthed body is a translucent lit material), so ShaderWarmup
## compiles them now rather than mid-match. Tiny and inside a torso; the
## caller frees them once warmed up.
func add_warmup_extras() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for u in _figures:
		var mats: Array = _body_materials.get(u, [])
		if mats.is_empty() or not (_figures[u] as Node3D).is_visible_in_tree():
			continue
		var stealth := (mats[0] as StandardMaterial3D).duplicate() as StandardMaterial3D
		stealth.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var mi := _part(BoxMesh.new(), Vector3(0.02, 0.02, 0.02), Vector3(0, 0.9, 0), stealth)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(_figures[u] as Node3D).add_child(mi)
		out.append(mi)
		break
	return out


## World position of a unit's chest (where shots leave from and land).
func chest_pos(u: UnitState) -> Vector3:
	return _world_pos(u) + Vector3(0, 0.95, 0)


## World position just above a unit's head (damage numbers).
func head_pos(u: UnitState) -> Vector3:
	return _world_pos(u) + Vector3(0, 1.75, 0)


func has_marker(u: UnitState) -> bool:
	return _markers.has(u)


# --- Tween Helpers ----------------------------------------------------------

## Moves a marker from its current position to `world` with a little
## character: a quick crouch (anticipation), a stretched hop along the way,
## and a squash on landing. Total time is `duration`, same as before.
func tween_to(u: UnitState, world: Vector3, duration: float = 0.35) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	var windup := duration * 0.16
	var travel := duration - windup
	var tw := root.create_tween()
	tw.tween_interval(windup)
	tw.tween_property(root, "position", world, travel) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_move_tweens[u] = tw

	var pose: Node3D = _poses.get(u)
	if pose == null:
		return
	_kill_tween(_pose_tweens, u)
	var climb := absf(world.y - root.position.y) > 0.1
	var hop := 0.3 if climb else 0.12
	var ptw := pose.create_tween()
	ptw.tween_property(pose, "scale", Vector3(1.1, 0.86, 1.1), windup).set_ease(Tween.EASE_OUT)
	ptw.tween_property(pose, "scale", Vector3(0.93, 1.1, 0.93), travel * 0.45).set_ease(Tween.EASE_OUT)
	ptw.parallel().tween_property(pose, "position:y", hop, travel * 0.45) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	ptw.tween_property(pose, "position:y", 0.0, travel * 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	ptw.parallel().tween_property(pose, "scale", Vector3.ONE, travel * 0.4)
	ptw.tween_property(pose, "scale", Vector3(1.1, 0.9, 1.1), travel * 0.07)
	ptw.tween_property(pose, "scale", Vector3.ONE, travel * 0.08)
	ptw.tween_callback(_reset_pose.bind(u))
	_pose_tweens[u] = ptw


## Smooth, even motion to `world` over `duration` (replay frames), turning
## to `facing` on the way. A gentle stride bob plays while it moves.
func glide_to(u: UnitState, world: Vector3, facing: float, duration: float) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	var moving := root.position.distance_to(world) > 0.01
	if moving:
		var tw := root.create_tween()
		tw.tween_property(root, "position", world, duration)
		_move_tweens[u] = tw
		var pose: Node3D = _poses.get(u)
		if pose != null and not _pose_tweens.has(u):
			var ptw := pose.create_tween()
			ptw.tween_property(pose, "position:y", 0.06, duration * 0.5).set_trans(Tween.TRANS_SINE)
			ptw.tween_property(pose, "position:y", 0.0, duration * 0.5).set_trans(Tween.TRANS_SINE)
	tween_facing(u, facing, minf(duration, 0.2))


## Turns the figure toward a new facing (shortest way round).
func tween_facing(u: UnitState, facing: float, duration: float = 0.35) -> void:
	var fig: Node3D = _figures.get(u)
	if fig == null:
		return
	_kill_tween(_face_tweens, u)
	var target := fig.rotation.y + wrapf(_facing_yaw(facing) - fig.rotation.y, -PI, PI)
	var tw := fig.create_tween()
	tw.tween_property(fig, "rotation:y", target, duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_face_tweens[u] = tw


## Attack motion: a melee lunge toward `toward` (world position), or a short
## recoil away from it for ranged shots.
func play_attack(u: UnitState, toward: Vector3, melee: bool) -> void:
	var pose: Node3D = _poses.get(u)
	var root: Node3D = _markers.get(u)
	if pose == null or root == null:
		return
	var dir := toward - root.position
	dir.y = 0.0
	if dir.length() < 0.001:
		return
	dir = dir.normalized()
	_kill_tween(_pose_tweens, u)
	_reset_pose(u)
	var tw := pose.create_tween()
	if melee:
		tw.tween_property(pose, "position", -dir * 0.08, 0.05)
		tw.parallel().tween_property(pose, "scale", Vector3(1.08, 0.92, 1.08), 0.05)
		tw.tween_property(pose, "position", dir * 0.42, 0.07).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(pose, "scale", Vector3(0.94, 1.06, 0.94), 0.07)
		tw.tween_property(pose, "position", Vector3.ZERO, 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(pose, "scale", Vector3.ONE, 0.2)
	else:
		tw.tween_property(pose, "position", -dir * 0.13, 0.04).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(pose, "scale", Vector3(1.05, 0.95, 1.05), 0.04)
		tw.tween_property(pose, "position", Vector3.ZERO, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(pose, "scale", Vector3.ONE, 0.2)
	tw.tween_callback(_reset_pose.bind(u))
	_pose_tweens[u] = tw


## A unit taking damage: a white pop, then red fading back to its colors,
## with a squash-and-knockback away from `from_dir` (the attacker's side).
func flash_hit(u: UnitState, from_dir: Vector3 = Vector3.ZERO) -> void:
	var root: Node3D = _markers.get(u)
	var mats: Array = _body_materials.get(u, [])
	if root == null or mats.is_empty():
		return
	var tw := root.create_tween().set_parallel(true)
	for m in mats:
		var mat: StandardMaterial3D = m
		mat.albedo_color = Color(1.6, 1.6, 1.6, mat.albedo_color.a)
		tw.tween_property(mat, "albedo_color", HIT_COLOR, 0.07).set_delay(0.04)
	tw.chain()
	for m in mats:
		var mat: StandardMaterial3D = m
		tw.tween_property(mat, "albedo_color", _shade(u, mat), 0.26)
	tw.chain().tween_callback(_apply_body_style.bind(u))

	var pose: Node3D = _poses.get(u)
	if pose == null:
		return
	_kill_tween(_pose_tweens, u)
	_reset_pose(u)
	var push := Vector3(from_dir.x, 0.0, from_dir.z)
	push = -push.normalized() * 0.16 if push.length() > 0.001 else Vector3.ZERO
	var ptw := pose.create_tween()
	# A held squash frame reads as a beat of hit-stop before the rebound.
	ptw.tween_property(pose, "scale", Vector3(1.22, 0.8, 1.22), 0.03)
	ptw.parallel().tween_property(pose, "position", push, 0.03)
	ptw.tween_interval(0.05)
	ptw.tween_property(pose, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	ptw.parallel().tween_property(pose, "position", Vector3.ZERO, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	ptw.tween_callback(_reset_pose.bind(u))
	_pose_tweens[u] = ptw


## Bail-out: the body flashes white, stretches into a streak of light, and is
## gone, with a beam shooting skyward.
func play_bail(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	_kill_tween(_face_tweens, u)
	_kill_tween(_pose_tweens, u)
	_reset_pose(u)
	if fx != null and root.visible:
		fx.bail_out(root.position, BoardUnits.team_color(u.team))
	for m in _body_materials.get(u, []):
		(m as StandardMaterial3D).albedo_color = Color(1.8, 1.8, 1.8)
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3(1.15, 0.85, 1.15), 0.07)
	tw.tween_property(root, "scale", Vector3(0.04, 2.6, 0.04), 0.24) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: root.visible = false)


# --- Ghost Preview ----------------------------------------------------------

## Shows a translucent "ghost" of `u` at `hex` (movement destination preview).
func show_ghost(u: UnitState, pos: Vector2, level: int = 0, facing: float = INF) -> void:
	if _ghost == null:
		_ghost = _build_ghost()
	var team_color := BoardUnits.team_color(u.team)
	var mat: StandardMaterial3D = _ghost_body.material_override
	mat.albedo_color = Color(team_color.r, team_color.g, team_color.b, 0.35)
	mat.emission = team_color
	_ghost.position = Vector3(pos.x, HexCoord.GROUND_Y + level * HexCoord.FLOOR_HEIGHT, pos.y)
	if is_finite(facing):
		_ghost.rotation.y = _facing_yaw(facing)
	_ghost.visible = true


# --- Vision Cones --------------------------------------------------------------

## Draws the selected character's vision at (hex, floor) facing `facing`:
## one shape combining the all-round detection radius and the long sight cone
## (Visibility.profile), occluded by the city in 3D. Every edge comes from a
## physics raycast fired from the character's eye height against the
## building solids, so the shape is exactly what the character can see.
## Inside a building it sees out only within WINDOW_REACH of the outer wall
## (`own_rect` is the building it stands in, if any). Shadow-casting lights
## at eye height light the same area (buildings throw real shadows).
## Planning shows it at the unit's projected position and facing.
func show_vision(u: UnitState, pos: Vector2, level: int, facing: float, own_rect: Dictionary = {}) -> void:
	clear_vision()
	_vision = _build_vision(u, pos, level, facing, own_rect, true)
	_vision.name = "SelectedVision"
	add_child(_vision)


## Faint vision shapes for the rest of the squad, so you can always tell
## where every character is looking. `entries`: [{unit, hex, floor, facing,
## own_rect}]. Rebuilt only when something in it changed.
func show_squad_vision(entries: Array) -> void:
	var key := ""
	for e in entries:
		key += "%s|%.2f,%.2f|%d|%.3f;" % [str(e["unit"].get_instance_id()), (e["pos"] as Vector2).x, (e["pos"] as Vector2).y, int(e["level"]), float(e["facing"])]
	if _squad_vision != null and key == _squad_vision_key:
		_squad_vision.visible = true
		return
	clear_squad_vision()
	_squad_vision_key = key
	_squad_vision = Node3D.new()
	_squad_vision.name = "SquadVision"
	add_child(_squad_vision)
	for e in entries:
		_squad_vision.add_child(_build_vision(e["unit"], e["pos"], int(e["level"]), float(e["facing"]), e.get("own_rect", {}), false))


func clear_squad_vision() -> void:
	if _squad_vision != null:
		_squad_vision.queue_free()
		_squad_vision = null
	_squad_vision_key = ""


func hide_squad_vision() -> void:
	if _squad_vision != null:
		_squad_vision.visible = false


## One character's combined vision shape; `lit` adds the eye lights and a
## brighter fill (the selected character).
func _build_vision(u: UnitState, pos: Vector2, level: int, facing: float, own_rect: Dictionary, lit: bool) -> Node3D:
	var team_color := BoardUnits.team_color(u.team)
	var saved := [u.pos, u.level, u.facing]
	u.pos = pos
	u.level = level
	u.facing = facing
	var p := Visibility.profile(u)
	u.pos = saved[0]
	u.level = saved[1]
	u.facing = saved[2]

	var fwd := _facing_vector(facing)
	var origin := Vector3(pos.x, HexCoord.GROUND_Y + level * HexCoord.FLOOR_HEIGHT, pos.y)
	var eye := origin + Vector3(0, Visibility.EYE_HEIGHT * HexCoord.FLOOR_HEIGHT, 0)
	var sight_r := float(p["sight_range"]) * _hex_size
	var detect_r := float(p["detect"]) * _hex_size
	var half := float(p["sight_half"])

	var root := Node3D.new()
	root.position = origin + Vector3(0, 0.04 if lit else 0.03, 0)
	# The selected character's area is lit by the spotlight, so its fill
	# stays light; the rest of the squad gets a faint tint.
	var fill := Color(team_color.lerp(Color.WHITE, 0.25), 0.16 if lit else 0.12)
	var pts := _keyhole_points(eye, fwd, detect_r, sight_r, half, own_rect)
	root.add_child(_keyhole_mesh(pts, fill))
	if not lit:
		return root
	_vision_center = root.position
	_vision_outline = PackedVector3Array()
	for p_local in pts:
		_vision_outline.append(root.position + p_local)

	# Light ray casting: real shadowed lights from the eye. Beams start just
	# in front of the figure so its own body doesn't shadow them.
	var tint := team_color.lerp(Color.WHITE, 0.55)
	var lens := eye - root.position + fwd * 0.45 * _hex_size
	root.add_child(_eye_light(lens, fwd, half, sight_r, tint, 2.2))
	var glow := OmniLight3D.new()
	glow.position = eye - root.position + Vector3(0, 1.0, 0)
	glow.omni_range = detect_r
	glow.light_color = tint
	glow.light_energy = 0.8
	glow.shadow_enabled = true
	root.add_child(glow)
	return root


## Outline of the combined vision shape (relative to the character): a
## circle of `detect_r` all round with the sight cone (`half_deg` either side
## of `fwd`) reaching out to `sight_r`. Every point is a raycast, so walls cut
## it. Points never sit exactly on the center, so each keeps its direction.
func _keyhole_points(eye: Vector3, fwd: Vector3, detect_r: float, sight_r: float, half_deg: float,
		own_rect: Dictionary) -> Array[Vector3]:
	var rays: Array = []   # [angle_deg, radius]
	var a := -180.0
	while a < -half_deg:
		rays.append([a, detect_r])
		a += 4.0
	rays.append([-half_deg, detect_r])
	a = -half_deg
	while a <= half_deg:
		rays.append([a, sight_r])
		a += 1.5
	rays.append([half_deg, sight_r])
	rays.append([half_deg, detect_r])
	a = half_deg + 4.0
	while a < 180.0:
		rays.append([a, detect_r])
		a += 4.0
	rays.append([180.0, detect_r])

	var space := get_world_3d().direct_space_state
	var pts: Array[Vector3] = []
	for r in rays:
		var dir := fwd.rotated(Vector3.UP, deg_to_rad(float(r[0])))
		pts.append(dir * maxf(0.05, _ray_reach(space, eye, dir, float(r[1]), own_rect)))
	return pts


## The vision shape as a translucent tint that fades out toward its edge.
func _keyhole_mesh(pts: Array[Vector3], fill: Color) -> Node3D:
	# No hard outline: the tint is strongest around the character and fades
	# to nothing over the last stretch before the edge, so the vision area
	# blends into the shadow outside it.
	var clear := Color(fill, 0.0)
	var core := Color(fill, fill.a * 0.55)
	var fade := EDGE_FADE * _hex_size
	var inner: Array[Vector3] = []
	for p in pts:
		var reach := p.length()
		inner.append(p * maxf(0.0, (reach - minf(fade, reach * 0.6)) / maxf(reach, 0.001)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, pts.size()):
		st.set_normal(Vector3.UP)
		# Center to the start of the fade: a gentle rise in strength.
		st.set_color(core)
		st.add_vertex(Vector3.ZERO)
		st.set_color(fill)
		st.add_vertex(inner[i - 1])
		st.add_vertex(inner[i])
		# The fade band: full strength to transparent at the edge.
		st.set_color(fill)
		st.add_vertex(inner[i - 1])
		st.set_color(clear)
		st.add_vertex(pts[i - 1])
		st.add_vertex(pts[i])
		st.set_color(fill)
		st.add_vertex(inner[i - 1])
		st.set_color(clear)
		st.add_vertex(pts[i])
		st.set_color(fill)
		st.add_vertex(inner[i])
	var body := MeshInstance3D.new()
	body.mesh = st.commit()
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := _flat_material(Color.WHITE)
	mat.vertex_color_use_as_albedo = true
	body.material_override = mat
	var node := Node3D.new()
	node.add_child(body)
	return node


func _flat_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	mat.albedo_color = color
	return mat


## World-space direction `u`'s figure faces (for screen markers).
func facing_vector(u: UnitState) -> Vector3:
	return _facing_vector(u.facing)


## Board extent in XZ (vision rays stop at the edge of the map).
func set_map_bounds(bounds: Rect2) -> void:
	_map_bounds = bounds


func clear_vision() -> void:
	if _vision != null:
		_vision.queue_free()
		_vision = null
	_vision_outline = PackedVector3Array()


## World-space outline of what the selected character can see (empty when no
## vision is shown), and the point it is seen from.
func vision_outline() -> PackedVector3Array:
	return _vision_outline


func vision_center() -> Vector3:
	return _vision_center


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
	GfxLite.glow(mat, Color(1, 1, 1), 1.1)
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

	var team_color := BoardUnits.team_color(u.team)

	# Selection ring (hidden until this unit is selected): a bright dashed
	# ring that pulses and slowly turns (see _process).
	var ring := MeshInstance3D.new()
	ring.name = "SelectionRing"
	ring.mesh = _dashed_ring_mesh(0.5, 0.6, 8)
	ring.material_override = _make_emissive(SELECT_COLOR, 3.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(0, 0.035, 0)
	ring.visible = false
	root.add_child(ring)

	# Team base ring: always-on team identity at the unit's feet. Shape backs
	# up the color: team 0 is a circle, team 1 a diamond.
	var base := MeshInstance3D.new()
	base.name = "TeamRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.3
	torus.outer_radius = 0.37
	torus.rings = 32 if u.team == 0 else 4
	torus.ring_segments = 6
	base.mesh = torus
	base.material_override = _make_emissive(team_color, 1.8)
	base.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	base.position.y = 0.03
	if u.team != 0:
		base.scale = Vector3(1.18, 1.0, 1.18)
	root.add_child(base)

	# Pose pivot: squash / stretch / lunge / hop happen here, so they never
	# fight the replay's position tween on the root or the facing on the figure.
	var pose := Node3D.new()
	pose.name = "Pose"
	root.add_child(pose)

	var figure := _build_figure(u, team_color)
	figure.scale = Vector3.ONE * 1.15
	figure.rotation.y = _facing_yaw(u.facing)
	pose.add_child(figure)

	# Name + HP (always face the camera). Depth-tested so they are hidden
	# behind solid geometry instead of floating on top of it.
	var name_label := Label3D.new()
	name_label.text = u.unit_data.unit_name
	name_label.position = Vector3(0, 2.3, 0)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.font_size = 40
	name_label.pixel_size = 0.0115
	name_label.outline_size = 12
	name_label.modulate = team_color.lerp(Color.WHITE, 0.25)
	name_label.outline_modulate = Color(0.02, 0.03, 0.06, 0.9)
	root.add_child(name_label)

	var bar := MeshInstance3D.new()
	bar.name = "HpBar"
	var quad := QuadMesh.new()
	quad.size = Vector2(1.04, 0.13)
	bar.mesh = quad
	bar.material_override = _hp_bar_material()
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bar.position = Vector3(0, 1.98, 0)
	bar.set_instance_shader_parameter("team_color", team_color)
	root.add_child(bar)

	var label := Label3D.new()
	label.text = str(u.trion_hp)
	label.position = Vector3(0, 1.74, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.pixel_size = 0.0105
	label.outline_size = 12
	label.outline_modulate = Color(0.02, 0.03, 0.06, 0.9)
	root.add_child(label)

	add_child(root)
	_markers[u] = root
	_hp_labels[u] = label
	_hp_bars[u] = bar
	_figures[u] = figure
	_poses[u] = pose
	_rings[u] = ring
	_set_hp_bar(u, false)


func _hp_bar_material() -> ShaderMaterial:
	if _hp_material == null:
		_hp_material = ShaderMaterial.new()
		_hp_material.shader = load("res://levels/board/hp_bar.gdshader")
	return _hp_material


## Updates a unit's HP bar. With `animate`, the lost segment lingers white
## for a moment and then drains, so damage is readable at a glance.
func _set_hp_bar(u: UnitState, animate: bool) -> void:
	var bar: MeshInstance3D = _hp_bars.get(u)
	if bar == null:
		return
	var frac := clampf(float(u.trion_hp) / maxf(1.0, float(u.unit_data.base_trion_hp)), 0.0, 1.0)
	var shown: float = _hp_shown.get(u, frac)
	_hp_shown[u] = frac
	bar.set_instance_shader_parameter("fill", frac)
	if not animate or shown <= frac:
		bar.set_instance_shader_parameter("chip", frac)
		return
	var set_chip := func(v: float) -> void: bar.set_instance_shader_parameter("chip", v)
	set_chip.call(shown)
	var tw := bar.create_tween()
	tw.tween_interval(0.3)
	tw.tween_method(set_chip, shown, frac, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _reset_pose(u: UnitState) -> void:
	var pose: Node3D = _poses.get(u)
	if pose != null:
		pose.position = Vector3.ZERO
		pose.scale = Vector3.ONE


## A flat ring of `dashes` arc segments in the XZ plane.
func _dashed_ring_mesh(inner: float, outer: float, dashes: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 6
	for d in dashes:
		var a0 := TAU * d / dashes
		var span := TAU / dashes * 0.68
		for i in steps:
			var a := a0 + span * i / steps
			var b := a0 + span * (i + 1) / steps
			var ai := Vector3(cos(a) * inner, 0, sin(a) * inner)
			var ao := Vector3(cos(a) * outer, 0, sin(a) * outer)
			var bi := Vector3(cos(b) * inner, 0, sin(b) * inner)
			var bo := Vector3(cos(b) * outer, 0, sin(b) * outer)
			st.set_normal(Vector3.UP)
			st.add_vertex(ai)
			st.add_vertex(bo)
			st.add_vertex(ao)
			st.add_vertex(ai)
			st.add_vertex(bi)
			st.add_vertex(bo)
	return st.commit()


## A low-poly agent in a combat suit, styled like the city: matte
## team-colored jacket, dark trousers and boots, skin-tone head with hair,
## glowing team-colored trim, and a role weapon from the loadout (glowing
## blade for attackers, long rifle for snipers, floating energy cube for
## shooters). A chevron on the ground shows which way the unit faces. Local +Z is "forward"; the node rotates to the unit's facing.
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

	# Facing chevron on the ground in front of the feet.
	var chevron := MeshInstance3D.new()
	chevron.name = "FacingChevron"
	chevron.mesh = _chevron_mesh()
	chevron.material_override = _make_emissive(team_color.lightened(0.2), 2.0)
	chevron.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	chevron.position = Vector3(0, 0.02, 0.42)
	fig.add_child(chevron)

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


## A "V" pointing along +Z, flat on the ground.
func _chevron_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tip := Vector3(0, 0, 0.12)
	var notch := Vector3(0, 0, 0.05)
	var quads := [
		[Vector3(-0.14, 0, -0.05), Vector3(-0.14, 0, 0.02), tip, notch],
		[Vector3(0.14, 0, 0.02), Vector3(0.14, 0, -0.05), notch, tip],
	]
	for q in quads:
		st.set_normal(Vector3.UP)
		for i in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(q[i])
	return st.commit()


## Body part material: matte with a soft toon-like rim so figures separate
## from the street and facades behind them, plus the x-ray pass.
func _part_material(_u: UnitState, color: Color, xray: Material) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	if not GfxLite.enabled():
		mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		mat.rim_enabled = true
		mat.rim = 0.55
		mat.rim_tint = 0.35
	GfxLite.lit(mat)
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
	return Vector3(u.pos.x, HexCoord.GROUND_Y + u.level * HexCoord.FLOOR_HEIGHT, u.pos.y)


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
	var color := BoardUnits.team_color(u.team)
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
func _facing_yaw(facing: float) -> float:
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


## World direction of a facing angle (radians in the ground plane).
func _facing_vector(facing: float) -> Vector3:
	var d := Vector2.from_angle(facing)
	return Vector3(d.x, 0.0, d.y)


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.5
	GfxLite.lit(mat)
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
	GfxLite.glow(mat, color, energy)
	return mat
