class_name EventLogUI
extends PanelContainer
## On-screen combat log panel. Receives CombatEvents during replay and renders
## them color-coded by phase, auto-scrolling to the newest entry.

const MAX_ENTRIES := 80

var _title: Label
var _log: RichTextLabel
var _entries: Array[String] = []


func _ready() -> void:
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.1, 0.88)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	sb.border_color = Color(0.3, 0.45, 0.65, 0.6)
	sb.set_border_width_all(1)
	add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	_title = Label.new()
	_title.text = "Turn 1 — Combat Log"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_title)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_active = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 13)
	vbox.add_child(_log)


## Sizes the panel against the viewport (right edge, between top bar and the
## bottom timeline), since it lives directly under a CanvasLayer.
func _fit_viewport() -> void:
	var vs := get_viewport().get_visible_rect().size
	position = Vector2(vs.x - 368.0 - 12.0, 52.0)
	size = Vector2(368.0, maxf(0.0, vs.y - 52.0 - 262.0))


func set_turn(n: int) -> void:
	_title.text = "Turn %d — Combat Log" % n


func clear() -> void:
	_entries.clear()
	_log.clear()


func add_event(ev: CombatEvent) -> void:
	add_message(ev.summary(), _phase_color(ev.phase))


## Server replay events arrive as encoded dictionaries (PlanCodec.encode_events).
func add_event_dict(d: Dictionary) -> void:
	add_message("[T%d] %s" % [int(d.get("tick", 0)) + 1, str(d.get("message", ""))], _phase_color(int(d.get("phase", -1))))


func add_message(text: String, color: Color = Color(0.9, 0.92, 0.95)) -> void:
	_entries.append("[color=#%s]%s[/color]" % [color.to_html(false), text.xml_escape()])
	if _entries.size() > MAX_ENTRIES:
		_entries.pop_front()
	_render()


func _render() -> void:
	_log.clear()
	for line in _entries:
		_log.append_text(line + "\n")


func _phase_color(phase: int) -> Color:
	match phase:
		CombatEvent.Phase.STATE:
			return Color(0.45, 0.85, 1.0)
		CombatEvent.Phase.MOVEMENT:
			return Color(0.5, 0.95, 0.6)
		CombatEvent.Phase.DEFENSE:
			return Color(1.0, 0.85, 0.4)
		CombatEvent.Phase.ATTACK:
			return Color(1.0, 0.6, 0.35)
		CombatEvent.Phase.RESOLUTION:
			return Color(1.0, 0.45, 0.45)
		_:
			return Color(0.9, 0.92, 0.95)
