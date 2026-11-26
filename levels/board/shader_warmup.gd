class_name ShaderWarmup
extends Control
## Draws a freshly built board a few materials at a time instead of all in
## the first frame, behind a "Preparing the battlefield" curtain.
##
## On the Web build each new shader compiles synchronously when first drawn
## (see GfxLite); doing them all in one frame froze the page long enough for
## the browser to offer to kill it. Here every group of geometry that shares
## a shader is held back (moved to HOLD_LAYER, which the camera doesn't draw)
## and released one group per frame, so the page keeps answering between
## compiles and the curtain shows progress. Lights, fog and visibility are
## left alone, so each shader compiles exactly as the board will use it.

signal finished

## Render layer 20: geometry waiting for its turn.
const HOLD_LAYER := 1 << 19

var _groups: Array = []   # Array of Array[GeometryInstance3D]
var _label: Label
var _bar: ProgressBar


## Holds back `root`'s geometry and starts releasing it. Adds itself to
## `ui_parent` as a full-screen curtain and frees itself when done.
static func start(root: Node3D, camera: Camera3D, ui_parent: Node) -> ShaderWarmup:
	var w := ShaderWarmup.new()
	w.name = "ShaderWarmup"
	ui_parent.add_child(w)
	w._hold(root, camera)
	w._run()
	return w


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.08, 0.92)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 14)
	add_child(box)
	_label = Label.new()
	_label.text = "Preparing the battlefield…"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 30)
	box.add_child(_label)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(420, 14)
	_bar.show_percentage = false
	box.add_child(_bar)


func _hold(root: Node3D, camera: Camera3D) -> void:
	if camera != null:
		camera.cull_mask &= ~HOLD_LAYER
	var by_key := {}
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		var g := node as GeometryInstance3D
		if g.layers & HOLD_LAYER:
			continue
		var key := group_key(g)
		if not by_key.has(key):
			by_key[key] = []
			_groups.append(by_key[key])
		by_key[key].append(g)
		g.set_meta(&"warm_layers", g.layers)
		g.layers = HOLD_LAYER
	_bar.max_value = maxi(_groups.size(), 1)


func _run() -> void:
	# First frame: sky, lights, and the curtain only.
	await RenderingServer.frame_post_draw
	for i in _groups.size():
		for g in _groups[i]:
			_release(g)
		_bar.value = i + 1
		await RenderingServer.frame_post_draw
		if not is_inside_tree():
			return
	finished.emit()
	queue_free()


## Puts everything back at once (e.g. the scene is closing).
func _exit_tree() -> void:
	for group in _groups:
		for g in group:
			_release(g)
	_groups.clear()


static func _release(g: Variant) -> void:
	if is_instance_valid(g) and (g as Object).has_meta(&"warm_layers"):
		(g as GeometryInstance3D).layers = int(g.get_meta(&"warm_layers"))
		(g as Object).remove_meta(&"warm_layers")


## Geometry that draws with the same shader shares a key (material class and
## the features that pick a StandardMaterial3D shader, or the custom shader).
static func group_key(g: GeometryInstance3D) -> String:
	if not (g is MeshInstance3D or g is MultiMeshInstance3D):
		return g.get_class()
	var mats: Array = []
	if g.material_override != null:
		mats.append(g.material_override)
	elif g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
		var mi := g as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			mats.append(mi.get_active_material(s))
	var parts: PackedStringArray = []
	for m in mats:
		parts.append(_material_key(m))
	return g.get_class() + "|" + "|".join(parts)


static func _material_key(m: Material) -> String:
	if m == null:
		return "-"
	var key := ""
	if m is ShaderMaterial:
		var sh: Shader = (m as ShaderMaterial).shader
		key = "S%d" % (sh.get_instance_id() if sh != null else 0)
	elif m is BaseMaterial3D:
		var b := m as BaseMaterial3D
		key = "B" + str([b.transparency, b.shading_mode, b.diffuse_mode, b.specular_mode, b.blend_mode,
			b.cull_mode, b.depth_draw_mode, b.no_depth_test, b.depth_test, b.rim_enabled,
			b.emission_enabled, b.billboard_mode, b.vertex_color_use_as_albedo,
			b.albedo_texture != null, b.disable_receive_shadows])
	else:
		key = m.get_class()
	if m.next_pass != null:
		key += ">" + _material_key(m.next_pass)
	return key
