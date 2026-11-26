class_name PlaceBanner
extends Control
## Where in Tokyo the battle is: a title card that fades in and out at the
## start of a match ("SHIBUYA / Scramble Crossing · Tokyo"), and a small
## permanent map-data credit (the OpenStreetMap licence asks for it wherever
## the map is shown).

const HOLD_SEC := 2.4
const FADE_SEC := 0.6

var _title: Label
var _subtitle: Label
var _card: VBoxContainer
var _credit: Label
var _tween: Tween


func _init() -> void:
	name = "PlaceBanner"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card = VBoxContainer.new()
	_card.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.position = Vector2(0, 92)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_theme_constant_override("separation", 0)
	add_child(_card)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 46)
	_title.add_theme_color_override("font_color", Color(1, 1, 1))
	_title.add_theme_color_override("font_outline_color", Color(0.03, 0.05, 0.12, 0.85))
	_title.add_theme_constant_override("outline_size", 10)
	_card.add_child(_title)
	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 20)
	_subtitle.add_theme_color_override("font_color", Color(0.62, 0.9, 1.0))
	_subtitle.add_theme_color_override("font_outline_color", Color(0.03, 0.05, 0.12, 0.85))
	_subtitle.add_theme_constant_override("outline_size", 6)
	_card.add_child(_subtitle)
	_card.modulate.a = 0.0
	_credit = Label.new()
	_credit.add_theme_font_size_override("font_size", 11)
	_credit.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	_credit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_credit.position = Vector2(8, -TimelineUI.PANEL_HEIGHT - 18)
	_credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_credit)


## Shows the card for a match's section (TokyoMap) and sets the credit.
func show_place(section: Dictionary) -> void:
	if section.is_empty() or TokyoMap.is_sheet(section):
		_credit.text = ""
		return
	var info := TokyoMap.district_info(str(section["district"]))
	_title.text = str(info.get("name", "Tokyo")).to_upper()
	_subtitle.text = "%s  ·  Tokyo" % str(info.get("area", ""))
	_credit.text = "Map data © OpenStreetMap contributors (ODbL) · Buildings: PLATEAU (MLIT)"
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_card.modulate.a = 0.0
	if not is_inside_tree():
		return
	_tween = create_tween()
	_tween.tween_property(_card, "modulate:a", 1.0, FADE_SEC)
	_tween.tween_interval(HOLD_SEC)
	_tween.tween_property(_card, "modulate:a", 0.0, FADE_SEC)


func _process(_delta: float) -> void:
	# Keep the credit just above the timeline whatever the window size.
	var vs := get_viewport_rect().size
	_credit.position = Vector2(8, vs.y - TimelineUI.PANEL_HEIGHT - 18)
