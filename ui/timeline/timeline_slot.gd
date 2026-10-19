class_name TimelineSlot
extends PanelContainer
## A single Main (slot 0) or Sub (slot 1) slot within one tick column.
## Acts as both a drop target (accept cards) and a drag source (move assigned
## cards). Right-click a filled slot to clear it.

signal dropped(slot: TimelineSlot, data: Dictionary)
signal clear_requested(slot: TimelineSlot)
signal selected(slot: TimelineSlot)

var unit_index: int
var tick_index: int
var slot_id: int
var card: TriggerCard
var is_selected: bool = false
var target_hex: Vector2i = Vector2i.ZERO
var target_floor: int = 0
var has_target: bool = false

var _label: Label


func _init(p_unit: int, p_tick: int, p_slot: int) -> void:
	unit_index = p_unit
	tick_index = p_tick
	slot_id = p_slot
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(96, 44)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_label)
	refresh()


func set_card(c: TriggerCard) -> void:
	card = c
	tooltip_text = c.describe() if c != null else ""
	refresh()


func set_target(h: Vector2i, floor: int = 0) -> void:
	target_hex = h
	target_floor = floor
	has_target = true
	refresh()


func clear_target() -> void:
	has_target = false
	refresh()


func set_selected(sel: bool) -> void:
	is_selected = sel
	refresh()


func refresh() -> void:
	if card != null:
		_label.text = card.card_name
		if has_target:
			_label.text += " →%d,%d" % [target_hex.x, target_hex.y]
			if target_floor > 0:
				_label.text += "·f%d" % target_floor
	else:
		_label.text = "--"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.2, 0.3, 0.95) if slot_id == 0 else Color(0.11, 0.15, 0.23, 0.95)
	if is_selected:
		sb.border_color = Color(0.55, 1.0, 0.4, 1.0)
		sb.set_border_width_all(3)
	elif card != null:
		sb.border_color = Color(0.45, 0.85, 1.0, 0.9)
		sb.set_border_width_all(2)
	else:
		sb.border_color = Color(0.3, 0.4, 0.55, 0.7)
		sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(4)
	add_theme_stylebox_override("panel", sb)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if card == null:
		return null
	var preview := Label.new()
	preview.text = card.card_name
	set_drag_preview(preview)
	return { "card": card, "from_slot": true, "unit": unit_index, "tick": tick_index, "slot": slot_id }


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("card")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and data.has("card"):
		dropped.emit(self, data)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			selected.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if card != null:
				clear_requested.emit(self)
				accept_event()
