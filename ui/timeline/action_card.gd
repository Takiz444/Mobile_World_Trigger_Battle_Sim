class_name ActionCard
extends PanelContainer
## A draggable action card in the timeline hand.
## Dragging copies the card (the hand is a palette, not a finite deck).

var card: TriggerCard


func _init(c: TriggerCard) -> void:
	card = c
	tooltip_text = c.describe()
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(108, 52)

	var label := Label.new()
	label.text = "%s (%d)" % [c.card_name, c.action_at_cost]
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
