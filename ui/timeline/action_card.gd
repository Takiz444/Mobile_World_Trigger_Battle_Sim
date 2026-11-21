class_name ActionCard
extends PanelContainer
## An action card in the planning hand: tap it to add the action to the end
## of its lane. Shows how long it takes this character. The hand is a palette,
## not a deck: cards are never used up.

signal tapped(card: TriggerCard)

const TYPE_COLORS := {
	TriggerCard.CardType.MOVE: Color(0.35, 0.8, 0.55),
	TriggerCard.CardType.MELEE: Color(1.0, 0.5, 0.4),
	TriggerCard.CardType.RANGED: Color(1.0, 0.72, 0.35),
	TriggerCard.CardType.SHIELD: Color(0.45, 0.8, 1.0),
	TriggerCard.CardType.UTILITY: Color(0.75, 0.6, 1.0),
	TriggerCard.CardType.STEALTH: Color(0.6, 0.65, 0.8),
}

var card: TriggerCard
var _press := Vector2.INF
var _sb: StyleBoxFlat


func _init(c: TriggerCard, data: UnitData = null) -> void:
	card = c
	tooltip_text = c.describe()
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(112, 48)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)

	var title := Label.new()
	title.text = c.card_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var cost := Label.new()
	# How long it takes this character (Stamina shortens it).
	var tempo := data.tempo if data != null else 1.0
	if TurnPlan.is_move_card(c) and not c.jump:
		cost.text = "%.1f m/s" % (TurnPlan.speed(data) if data != null else TurnPlan.BASE_SPEED)
	elif c.card_type == TriggerCard.CardType.SHIELD:
		cost.text = "hold"
	else:
		cost.text = "%.1f s" % (c.action_time / tempo)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cost.add_theme_font_size_override("font_size", 13)
	cost.add_theme_color_override("font_color", Color(0.7, 0.76, 0.86))
	box.add_child(cost)

	var accent: Color = TYPE_COLORS.get(c.card_type, Color(0.35, 0.55, 0.85))
	if c.jump:
		accent = TYPE_COLORS[TriggerCard.CardType.MOVE]
	_sb = StyleBoxFlat.new()
	_sb.bg_color = Color(0.13, 0.18, 0.28, 0.96)
	_sb.border_color = accent
	_sb.set_border_width_all(1)
	_sb.border_width_top = 3
	_sb.set_corner_radius_all(6)
	_sb.set_content_margin_all(4)
	add_theme_stylebox_override("panel", _sb)
	mouse_entered.connect(func() -> void: _sb.bg_color = Color(0.18, 0.25, 0.38, 0.98))
	mouse_exited.connect(func() -> void: _sb.bg_color = Color(0.13, 0.18, 0.28, 0.96))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press = event.position
		elif _press != Vector2.INF and event.position.distance_to(_press) < 12.0 \
				and not get_viewport().gui_is_dragging():
			_press = Vector2.INF
			tapped.emit(card)
			accept_event()
		else:
			_press = Vector2.INF
