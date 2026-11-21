class_name UiTheme
extends RefCounted
## The game's one UI theme, built in code (no imported assets) and installed
## on the root window so every screen shares it: dark glass panels, a cyan
## accent, rounded buttons with hover / pressed / focus / disabled states,
## and touch-sized controls (44 px minimum at the 1280x720 base).
##
## Also owns the fade used when switching screens.

const BG := Color(0.045, 0.06, 0.1)
const PANEL := Color(0.075, 0.1, 0.16, 0.94)
const PANEL_EDGE := Color(0.24, 0.36, 0.56, 0.75)
const BUTTON := Color(0.12, 0.17, 0.27)
const BUTTON_HOVER := Color(0.17, 0.25, 0.39)
const BUTTON_PRESSED := Color(0.09, 0.13, 0.21)
const ACCENT := Color(0.36, 0.78, 1.0)
const ACCENT_DIM := Color(0.24, 0.5, 0.72)
const TEXT := Color(0.9, 0.93, 0.97)
const TEXT_DIM := Color(0.6, 0.67, 0.77)
const DANGER := Color(1.0, 0.45, 0.4)
const GOOD := Color(0.45, 0.95, 0.6)

const TOUCH_MIN := 44.0
const FADE_SEC := 0.18

static var _theme: Theme


static func get_theme() -> Theme:
	if _theme == null:
		_theme = _build()
	return _theme


## Installs the theme on the whole window (every Control inherits it).
static func install(tree: SceneTree) -> void:
	if tree != null and tree.root.theme != get_theme():
		tree.root.theme = get_theme()


## Fades to black, switches to `scene_path`, and fades back in.
static func change_scene(tree: SceneTree, scene_path: String) -> void:
	if tree == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 100
	layer.name = "SceneFade"
	var rect := ColorRect.new()
	rect.color = Color(BG.r, BG.g, BG.b, 0.0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_STOP   # no clicks mid-transition
	layer.add_child(rect)
	tree.root.add_child(layer)
	var tw := layer.create_tween()
	tw.tween_property(rect, "color:a", 1.0, FADE_SEC)
	tw.tween_callback(func() -> void: tree.change_scene_to_file(scene_path))
	tw.tween_interval(0.05)
	tw.tween_property(rect, "color:a", 0.0, FADE_SEC)
	tw.tween_callback(layer.queue_free)


## A quick scale pop when a button is pressed (call once per button).
static func add_press_feedback(button: BaseButton) -> void:
	button.button_down.connect(func() -> void:
		button.pivot_offset = button.size * 0.5
		var tw := button.create_tween()
		tw.tween_property(button, "scale", Vector2(0.96, 0.96), 0.05)
		tw.tween_property(button, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))


static func panel_style(fill: Color = PANEL, edge: Color = PANEL_EDGE, radius: int = 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = edge
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(10)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 6
	return sb


static func _button_style(fill: Color, edge: Color, edge_width: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = edge
	sb.set_border_width_all(edge_width)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	# 16 px text + margins = the 44 px touch minimum.
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


static func _build() -> Theme:
	var t := Theme.new()
	t.default_font_size = 16

	var normal := _button_style(BUTTON, PANEL_EDGE)
	var hover := _button_style(BUTTON_HOVER, ACCENT_DIM)
	var pressed := _button_style(BUTTON_PRESSED, ACCENT, 2)
	var disabled := _button_style(Color(0.09, 0.11, 0.16, 0.7), Color(0.2, 0.24, 0.32, 0.5))
	var focus := _button_style(Color(0, 0, 0, 0), ACCENT, 2)
	focus.draw_center = false
	for type in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("pressed", type, pressed)
		t.set_stylebox("disabled", type, disabled)
		t.set_stylebox("focus", type, focus)
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, Color.WHITE)
		t.set_color("font_pressed_color", type, ACCENT)
		t.set_color("font_focus_color", type, Color.WHITE)
		t.set_color("font_disabled_color", type, Color(TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 0.55))

	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", Color.WHITE)
	t.set_color("font_pressed_color", "CheckBox", ACCENT)
	t.set_stylebox("focus", "CheckBox", focus)

	var field := _button_style(Color(0.05, 0.07, 0.11), PANEL_EDGE)
	var field_focus := _button_style(Color(0.05, 0.07, 0.11), ACCENT, 2)
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", field_focus)
	t.set_stylebox("read_only", "LineEdit", disabled)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 0.7))
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35))

	t.set_stylebox("panel", "PanelContainer", panel_style())
	t.set_stylebox("panel", "Panel", panel_style())
	var tip := panel_style(Color(0.04, 0.055, 0.09, 0.97), ACCENT_DIM, 6)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.05, 0.07, 0.11)
	bar_bg.border_color = PANEL_EDGE
	bar_bg.set_border_width_all(1)
	bar_bg.set_corner_radius_all(6)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = ACCENT
	bar_fill.set_corner_radius_all(6)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", bar_fill)

	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_constant("line_separation", "RichTextLabel", 3)
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(ACCENT_DIM.r, ACCENT_DIM.g, ACCENT_DIM.b, 0.6)
	grabber.set_corner_radius_all(4)
	grabber.content_margin_left = 3
	grabber.content_margin_right = 3
	t.set_stylebox("grabber", "VScrollBar", grabber)
	t.set_stylebox("grabber_highlight", "VScrollBar", grabber)
	t.set_stylebox("grabber_pressed", "VScrollBar", grabber)
	t.set_stylebox("grabber", "HScrollBar", grabber)
	t.set_stylebox("grabber_highlight", "HScrollBar", grabber)
	t.set_stylebox("grabber_pressed", "HScrollBar", grabber)
	return t
