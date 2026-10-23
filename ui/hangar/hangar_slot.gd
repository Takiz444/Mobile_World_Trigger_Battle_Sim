class_name HangarSlot
extends PanelContainer
## A single Main/Sub loadout slot in the Hangar. Drop target + drag source.
## Right-click a filled slot to clear it.

signal dropped(slot: HangarSlot, data: Dictionary)
signal clear_requested(slot: HangarSlot)

var slot_is_sub: bool
var index: int
var card: TriggerCard

var _label: Label


func _init(p_sub: bool, p_index: int) -> void:
	slot_is_sub = p_sub
	index = p_index
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(180, 48)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_label)
	refresh()


func set_card(c: TriggerCard) -> void:
	card = c
	refresh()


func refresh() -> void:
	if card != null:
		_label.text = "%s (%d T)" % [card.card_name, card.trion_equip_cost]
	else:
		_label.text = "-- EMPTY --"

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.18, 0.28, 0.95) if not slot_is_sub else Color(0.1, 0.14, 0.22, 0.95)
	if card != null:
		sb.border_color = Color(0.45, 0.85, 1.0, 0.9)
		sb.set_border_width_all(2)
	else:
		sb.border_color = Color(0.3, 0.4, 0.55, 0.7)
		sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(6)
	add_theme_stylebox_override("panel", sb)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if card == null:
		return null
	var preview := Label.new()
	preview.text = card.card_name
	set_drag_preview(preview)
	return { "card": card, "from_slot": true, "slot_is_sub": slot_is_sub, "index": index }


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("card")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and data.has("card"):
		dropped.emit(self, data)


func _gui_input(event: InputEvent) -> void:
	# Right-click on desktop, double-tap on touch screens.
	var right: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT
	var double_tap: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.double_click
	if right or double_tap:
		if card != null:
			clear_requested.emit(self)
			accept_event()
