class_name BoardFx
extends Node3D
## One-shot combat effects for the replay: bullet tracers, melee slashes,
## impact sparks, shield flashes, bail-out beams, and floating damage numbers.
##
## Everything is procedural (primitive meshes, CPU particles, tweens) and
## self-cleaning: each effect is its own node whose tween frees it when done,
## so effects are safe to fire and forget, and freeing this node (scene
## change, rematch) cancels all of them. Effects are purely cosmetic: they
## never touch match state or replay timing.

const TRACER_SPEED := 42.0      # world units per second
const TRACER_MIN_TIME := 0.07
const TRACER_MAX_TIME := 0.2

var _shield_shader: Shader


## A glowing bolt from `from` to `to` with a fading streak behind it.
## `arc` > 0 bends the path sideways and up (curving shots). Returns the
## flight time so the caller can time the impact.
func tracer(from: Vector3, to: Vector3, color: Color, arc: float = 0.0, heavy: bool = false) -> float:
	var dist := from.distance_to(to)
	if dist < 0.05:
		return 0.0
	var time := clampf(dist / TRACER_SPEED, TRACER_MIN_TIME, TRACER_MAX_TIME)
	var width := 0.085 if heavy else 0.05

	muzzle_flash(from, color, heavy)

	var bolt := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, width, minf(dist, 1.3 if heavy else 0.8))
	bolt.mesh = box
	bolt.material_override = _glow_material(color.lerp(Color.WHITE, 0.55), 4.0)
	bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bolt)

	var side := (to - from).cross(Vector3.UP).normalized()
	var mid := (from + to) * 0.5 + (side * arc + Vector3.UP * absf(arc) * 0.6)
	var place := func(t: float) -> void:
		var p := _bezier(from, mid, to, t)
		var ahead := _bezier(from, mid, to, minf(1.0, t + 0.05))
		bolt.position = p
		if not ahead.is_equal_approx(p):
			bolt.look_at_from_position(p, ahead, _safe_up(ahead - p))
	place.call(0.0)
	var tw := bolt.create_tween()
	tw.tween_method(place, 0.0, 1.0, time)
	tw.tween_callback(bolt.queue_free)

	# Straight shots leave a streak that fades after the bolt lands.
	if is_zero_approx(arc):
		var streak := MeshInstance3D.new()
		var sbox := BoxMesh.new()
		sbox.size = Vector3(width * 0.5, width * 0.5, dist)
		streak.mesh = sbox
		var mat := _glow_material(color, 1.6)
		streak.material_override = mat
		streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(streak)
		streak.look_at_from_position((from + to) * 0.5, to, _safe_up(to - from))
		var c0 := mat.albedo_color
		mat.albedo_color = Color(c0, 0.0)
		var stw := streak.create_tween()
		stw.tween_property(mat, "albedo_color", Color(c0, 0.75), time * 0.6)
		stw.tween_property(mat, "albedo_color", Color(c0, 0.0), 0.22)
		stw.parallel().tween_property(streak, "scale", Vector3(0.2, 0.2, 1.0), 0.22)
		stw.tween_callback(streak.queue_free)
	return time


## Short bright burst at a weapon's muzzle.
func muzzle_flash(at: Vector3, color: Color, heavy: bool = false) -> void:
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 8
	sphere.rings = 4
	flash.mesh = sphere
	var mat := _glow_material(color.lerp(Color.WHITE, 0.6), 5.0)
	flash.material_override = mat
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.position = at
	var size := 0.42 if heavy else 0.26
	flash.scale = Vector3.ONE * size * 0.4
	add_child(flash)
	var tw := flash.create_tween().set_parallel(true)
	tw.tween_property(flash, "scale", Vector3.ONE * size, 0.07).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(mat.albedo_color, 0.0), 0.12)
	tw.chain().tween_callback(flash.queue_free)


## A crescent blade arc sweeping across `at`, facing along `dir` (attacker
## toward target).
func slash(at: Vector3, dir: Vector3, color: Color, heavy: bool = false) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 0.001:
		flat = Vector3.FORWARD
	flat = flat.normalized()
	var arc := MeshInstance3D.new()
	arc.mesh = _crescent_mesh(0.62 if heavy else 0.5, 0.2 if heavy else 0.14, 1.9)
	var mat := _glow_material(color.lerp(Color.WHITE, 0.7), 4.5)
	arc.material_override = mat
	arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(arc)
	# The crescent lies in its local XZ plane bulging toward -Z; tilt it so
	# the cut reads as a diagonal swing from the camera.
	arc.look_at_from_position(at, at + flat, Vector3.UP)
	arc.rotate_object_local(Vector3.FORWARD, deg_to_rad(-38.0))
	arc.rotate_object_local(Vector3.UP, deg_to_rad(55.0))
	arc.scale = Vector3.ONE * 0.55
	var tw := arc.create_tween().set_parallel(true)
	tw.tween_property(arc, "scale", Vector3.ONE * 1.2, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(a: float) -> void: arc.rotate_object_local(Vector3.UP, deg_to_rad(-a)), 0.0, 14.0, 0.16)
	tw.tween_property(mat, "albedo_color", Color(mat.albedo_color, 0.0), 0.2).set_delay(0.06)
	tw.chain().tween_callback(arc.queue_free)


## Sparks and an expanding ring where a hit lands.
func impact(at: Vector3, color: Color, heavy: bool = false) -> void:
	_burst(at, color.lerp(Color.WHITE, 0.4), 18 if heavy else 10, 3.6 if heavy else 2.6, 0.32, Vector3(0, 1, 0), 180.0, -6.0)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.5
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	var mat := _glow_material(color.lerp(Color.WHITE, 0.5), 3.0)
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = at
	ring.scale = Vector3.ONE * 0.2
	add_child(ring)
	var size := 1.25 if heavy else 0.85
	var tw := ring.create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(size, size * 0.4, size), 0.24).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(mat.albedo_color, 0.0), 0.24).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(ring.queue_free)


## A hexagon-patterned energy barrier flaring up in front of a defender.
## `toward` is the direction the hit came from; Vector3.ZERO (or `full`)
## draws the all-round barrier of a full guard.
func shield_flash(at: Vector3, toward: Vector3, color: Color, full: bool = false) -> void:
	if _shield_shader == null:
		_shield_shader = load("res://levels/board/shield.gdshader")
	var dome := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.62
	sphere.height = 1.24
	sphere.radial_segments = 24
	sphere.rings = 12
	dome.mesh = sphere
	var mat := ShaderMaterial.new()
	mat.shader = _shield_shader
	mat.set_shader_parameter("color", color.lerp(Color.WHITE, 0.35))
	var flat := Vector3(toward.x, 0.0, toward.z)
	var all_round := full or flat.length() < 0.001
	mat.set_shader_parameter("facing", Vector3.ZERO if all_round else flat.normalized())
	mat.set_shader_parameter("strength", 0.0)
	dome.material_override = mat
	dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dome.position = at
	dome.scale = Vector3.ONE * 0.85
	add_child(dome)
	var tw := dome.create_tween()
	tw.tween_method(func(v: float) -> void: mat.set_shader_parameter("strength", v), 0.0, 1.0, 0.06)
	tw.parallel().tween_property(dome, "scale", Vector3.ONE * 1.05, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(v: float) -> void: mat.set_shader_parameter("strength", v), 1.0, 0.0, 0.38).set_ease(Tween.EASE_IN)
	tw.tween_callback(dome.queue_free)


## Bail-out: a column of light shooting skyward with rising motes and a
## ground flash.
func bail_out(at: Vector3, color: Color) -> void:
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.2
	cyl.bottom_radius = 0.26
	cyl.height = 1.0
	cyl.radial_segments = 12
	cyl.cap_top = false
	cyl.cap_bottom = false
	beam.mesh = cyl
	var mat := _glow_material(color.lerp(Color.WHITE, 0.6), 4.0)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	beam.material_override = mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)
	var height := 14.0
	var grow := func(h: float) -> void:
		beam.scale.y = h
		beam.position = at + Vector3(0, h * 0.5, 0)
	grow.call(0.6)
	var tw := beam.create_tween()
	tw.tween_method(grow, 0.6, height, 0.2).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(beam, "scale:x", 1.5, 0.1)
	tw.parallel().tween_property(beam, "scale:z", 1.5, 0.1)
	tw.tween_property(beam, "scale:x", 0.02, 0.35).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(beam, "scale:z", 0.02, 0.35).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(mat, "albedo_color", Color(mat.albedo_color, 0.0), 0.35).set_ease(Tween.EASE_IN)
	tw.tween_callback(beam.queue_free)

	_burst(at + Vector3(0, 0.5, 0), color.lerp(Color.WHITE, 0.5), 28, 3.2, 0.7, Vector3.UP, 35.0, 3.0)
	impact(at + Vector3(0, 0.06, 0), color, true)


## A number (or word) that pops, floats up, and fades. Always drawn on top.
func popup(at: Vector3, text: String, color: Color, big: bool = false) -> void:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = false
	label.render_priority = 10
	label.outline_render_priority = 9
	label.font_size = 64 if big else 48
	label.pixel_size = 0.0085
	label.outline_size = 14
	label.modulate = color
	label.outline_modulate = Color(0.02, 0.03, 0.06, 0.95)
	# A small sideways scatter keeps stacked numbers from overlapping exactly.
	var jitter := Vector3(randf_range(-0.18, 0.18), 0.0, randf_range(-0.1, 0.1))
	label.position = at + jitter
	label.scale = Vector3.ONE * 0.4
	add_child(label)
	var tw := label.create_tween().set_parallel(true)
	tw.tween_property(label, "scale", Vector3.ONE * (1.25 if big else 1.0), 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "position:y", label.position.y + 0.9, 0.85).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, 0.3).set_delay(0.55)
	tw.tween_property(label, "outline_modulate:a", 0.0, 0.3).set_delay(0.55)
	tw.chain().tween_callback(label.queue_free)


## A soft ring that expands along the ground (stealth toggles, landings).
func ground_pulse(at: Vector3, color: Color, size: float = 0.9) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.44
	torus.outer_radius = 0.5
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	var mat := _glow_material(color, 2.0)
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = at + Vector3(0, 0.05, 0)
	ring.scale = Vector3(0.3, 0.3, 0.3)
	add_child(ring)
	var tw := ring.create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(size, 0.3, size) * 1.6, 0.4).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(mat.albedo_color, 0.0), 0.4)
	tw.chain().tween_callback(ring.queue_free)


# --- Helpers ----------------------------------------------------------------

func _burst(at: Vector3, color: Color, amount: int, speed: float, life: float, direction: Vector3, spread: float, gravity_y: float) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.92
	p.amount = amount
	p.lifetime = life
	p.direction = direction
	p.spread = spread
	p.initial_velocity_min = speed * 0.45
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, gravity_y, 0)
	p.damping_min = 1.5
	p.damping_max = 3.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = curve
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.06, 0.06, 0.06)
	mesh.material = _glow_material(color, 4.0)
	p.mesh = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = at
	add_child(p)
	p.emitting = true
	var tw := p.create_tween()
	tw.tween_interval(life + 0.15)
	tw.tween_callback(p.queue_free)


## Unshaded, additive-looking glow: over-bright albedo so the bloom picks it
## up, alpha-blended so it can fade out.
func _glow_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(color.r * energy, color.g * energy, color.b * energy, 1.0)
	mat.disable_receive_shadows = true
	return mat


func _bezier(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	return a.lerp(b, t).lerp(b.lerp(c, t), t)


## An up vector that is never parallel to `dir` (look_at needs one).
func _safe_up(dir: Vector3) -> Vector3:
	return Vector3.RIGHT if absf(dir.normalized().dot(Vector3.UP)) > 0.98 else Vector3.UP


## A flat crescent in the XZ plane (bulging toward -Z), thick in the middle
## and tapering to points, spanning `sweep` radians.
func _crescent_mesh(radius: float, thickness: float, sweep: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 14
	var prev_in := Vector3.ZERO
	var prev_out := Vector3.ZERO
	for i in segments + 1:
		var t := float(i) / segments
		var a := -sweep * 0.5 + sweep * t
		var w := thickness * sin(t * PI)
		var dir := Vector3(sin(a), 0.0, -cos(a))
		var p_out := dir * (radius + w * 0.5)
		var p_in := dir * (radius - w * 0.5)
		if i > 0:
			st.set_normal(Vector3.UP)
			st.add_vertex(prev_in)
			st.add_vertex(prev_out)
			st.add_vertex(p_out)
			st.add_vertex(prev_in)
			st.add_vertex(p_out)
			st.add_vertex(p_in)
		prev_in = p_in
		prev_out = p_out
	return st.commit()
