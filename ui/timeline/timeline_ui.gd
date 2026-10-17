class_name TimelineUI
extends Control
## 6-tick timeline ribbon + card hand + AT economy UI (GDD section 7).
##
## Top bar: unit quick-select tabs. Bottom panel: 6 tick columns (Main/Sub),
## draggable action-card hand, AT meter, and the Submit All button.
## The middle of the screen passes mouse input through to the 3D board.

signal unit_selected(unit_index: int)
signal plan_submitted

var _units: Array[UnitData] = []
var _plan: TurnPlan
var _current_unit := 0
var _selected_slot: TimelineSlot
var _locked := false

var _unit_tabs: HBoxContainer
var _timeline_row: HBoxContainer
var _hand_row: HBoxContainer
var _at_label: Label
var _at_bar: ProgressBar
var _submit_button: Button

var _current_slots: Array = []  # [tick][slot] -> TimelineSlot


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_layout()


func setup(units: Array[UnitData]) -> void:
	_units = units.duplicate()
	_plan = TurnPlan.new(_units)
	_current_unit = 0
	_refresh_unit_tabs()
	_refresh_timeline_view()
	_refresh_hand()
	_refresh_at()


# --- Layout -----------------------------------------------------------------

func _build_layout() -> void:
	var top_bar := PanelContainer.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = 44
	_style_panel(top_bar, Color(0.07, 0.09, 0.14, 0.9))
	add_child(top_bar)

	_unit_tabs = HBoxContainer.new()
	_unit_tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	_unit_tabs.add_theme_constant_override("separation", 8)
	top_bar.add_child(_unit_tabs)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -248
	_style_panel(bottom, Color(0.06, 0.08, 0.12, 0.92))
	add_child(bottom)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	bottom.add_child(vbox)

	_timeline_row = HBoxContainer.new()
	_timeline_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_timeline_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_timeline_row)

	_hand_row = HBoxContainer.new()
	_hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_hand_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_hand_row)

	var at_row := HBoxContainer.new()
	at_row.alignment = BoxContainer.ALIGNMENT_CENTER
	at_row.add_theme_constant_override("separation", 10)
	vbox.add_child(at_row)

	var hint := Label.new()
	hint.text = "Drag cards into slots  ·  right-click a slot to clear"
	hint.modulate = Color(0.7, 0.75, 0.85)
	at_row.add_child(hint)

	_at_label = Label.new()
	_at_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	at_row.add_child(_at_label)

	_at_bar = ProgressBar.new()
	_at_bar.custom_minimum_size = Vector2(160, 18)
	_at_bar.show_percentage = false
	at_row.add_child(_at_bar)

	_submit_button = Button.new()
	_submit_button.text = "Submit All"
	_submit_button.pressed.connect(_on_submit_pressed)
	at_row.add_child(_submit_button)


func _style_panel(p: PanelContainer, color: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)


# --- Refresh ----------------------------------------------------------------

func _refresh_unit_tabs() -> void:
	for c in _unit_tabs.get_children():
		c.queue_free()
	for i in _units.size():
		var b := Button.new()
		b.text = "%d. %s" % [i + 1, _units[i].unit_name]
		b.toggle_mode = true
		b.button_pressed = (i == _current_unit)
		b.pressed.connect(_on_unit_tab.bind(i))
		_unit_tabs.add_child(b)


func _refresh_timeline_view() -> void:
	for c in _timeline_row.get_children():
		c.queue_free()
	_current_slots.clear()
	_selected_slot = null
	for tick in TurnPlan.TICKS_PER_TURN:
		var tick_slots: Array = []
		tick_slots.resize(2)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)

		var header := Label.new()
		header.text = "Tick %d" % (tick + 1)
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(header)

		for slot in 2:
			var s := TimelineSlot.new(_current_unit, tick, slot)
			s.dropped.connect(_on_slot_dropped)
			s.clear_requested.connect(_on_slot_clear)
			s.selected.connect(_on_slot_selected)
			tick_slots[slot] = s
			col.add_child(s)

		_current_slots.append(tick_slots)
		_timeline_row.add_child(col)
	_refresh_timeline_cards()


func _refresh_timeline_cards() -> void:
	for tick in TurnPlan.TICKS_PER_TURN:
		var ta: TickAction = _plan.get_tick(_current_unit, tick)
		for slot in 2:
			var s: TimelineSlot = _current_slots[tick][slot]
			s.set_card(_plan.get_card(_current_unit, tick, slot))
			if ta.has_target:
				s.set_target_hex(ta.target_hex)
			else:
				s.clear_target()
			s.set_selected(s == _selected_slot)


func _refresh_hand() -> void:
	for c in _hand_row.get_children():
		c.queue_free()
	for card in _plan.get_available_actions(_current_unit):
		_hand_row.add_child(ActionCard.new(card))


func _refresh_at() -> void:
	var pool := _plan.get_at_pool(_current_unit)
	var spent := _plan.get_at_spent(_current_unit)
	_at_label.text = "AT %d / %d" % [spent, pool]
	_at_bar.max_value = pool
	_at_bar.value = spent
	_submit_button.disabled = _locked or not _plan.is_all_valid()


# --- Interaction ------------------------------------------------------------

func _on_unit_tab(i: int) -> void:
	if i == _current_unit:
		return
	_current_unit = i
	_refresh_unit_tabs()
	_refresh_timeline_view()
	_refresh_hand()
	_refresh_at()
	unit_selected.emit(i)


func _on_slot_selected(slot: TimelineSlot) -> void:
	_selected_slot = slot
	_refresh_timeline_cards()


## Sets the target/destination hex for the currently selected tick slot.
## Called when the player clicks a hex on the 3D board.
func set_target_for_selected_slot(hex: Vector2i) -> void:
	if _selected_slot == null:
		return
	_plan.set_target(_selected_slot.unit_index, _selected_slot.tick_index, hex)
	_refresh_timeline_cards()


func get_plan() -> TurnPlan:
	return _plan


func get_units() -> Array[UnitData]:
	return _units


func set_locked(locked: bool) -> void:
	_locked = locked
	_refresh_at()


## Resets the turn plan for the next turn (AT does not carry over per GDD 5.1).
func begin_new_turn() -> void:
	_plan = TurnPlan.new(_units)
	_locked = false
	_refresh_timeline_view()
	_refresh_hand()
	_refresh_at()


func _on_slot_dropped(slot: TimelineSlot, data: Dictionary) -> void:
	var card: TriggerCard = data["card"]
	var is_move: bool = data.get("from_slot", false)

	if is_move:
		var src_unit: int = data["unit"]
		var src_tick: int = data["tick"]
		var src_slot: int = data["slot"]
		if src_unit != slot.unit_index:
			return  # cards cannot be moved across units
		if src_unit == slot.unit_index and src_tick == slot.tick_index and src_slot == slot.slot_id:
			return  # dropped on itself
		_plan.clear(src_unit, src_tick, src_slot)

	if not _plan.assign(slot.unit_index, slot.tick_index, slot.slot_id, card):
		if is_move:
			_plan.assign(data["unit"], data["tick"], data["slot"], card)  # restore source

	_refresh_timeline_cards()
	_refresh_at()


func _on_slot_clear(slot: TimelineSlot) -> void:
	if _plan.clear(slot.unit_index, slot.tick_index, slot.slot_id):
		_refresh_timeline_cards()
		_refresh_at()


func _on_submit_pressed() -> void:
	if not _plan.is_all_valid():
		return
	plan_submitted.emit()
	print("Plan submitted:")
	for i in _units.size():
		print("  %s: AT %d / %d" % [_units[i].unit_name, _plan.get_at_spent(i), _plan.get_at_pool(i)])
