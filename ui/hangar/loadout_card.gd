class_name LoadoutCard
extends PanelContainer
## Draggable trigger card in the Hangar's available-triggers palette.
## Shows the Trion equip cost (deck-building budget).

var card: TriggerCard


func _init(c: TriggerCard) -> void:
	card = c
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(120, 56)

	var label := Label.new()
	label.text = "%s (%d T)" % [c.card_name, c.trion_equip_cost]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(label)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.22, 0.34, 0.95)
	sb.border_color = Color(0.35, 0.55, 0.85, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(6)
	add_theme_stylebox_override("panel", sb)


func _get_drag_data(_at_position: Vector2) -> Variant:
	var preview := Label.new()
	preview.text = card.card_name
	set_drag_preview(preview)
	return { "card": card, "from_slot": false }
