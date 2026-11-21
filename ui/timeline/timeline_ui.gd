class_name TimelineUI
extends Control
## The planning HUD (GDD section 7).
##
## Top bar: one tab per character (name + HP); tap one, or tap the character
## on the board, to command it. Bottom panel: the character's 6-tick plan
## (Main and Sub rows), its action cards, a one-line instruction that says
## what to do next, the AT meter, and the Submit button.
##
## Placing an action: tap a card (it goes into the selected tick, or the next
## free one) or drag it onto a tick; then tap a highlighted hex on the board
## if the action needs a target. Right-click or double-tap a tick to clear it.
## The middle of the screen passes input through to the 3D board.

signal unit_selected(unit_index: int)
signal plan_submitted
## Emitted whenever the selected tick slot (or its card) changes, so the
## board can refresh highlights.
signal targeting_changed

const READY_COLOR := Color(0.45, 0.95, 0.6)
## HUD footprint, shared with the combat log and camera framing.
const TOP_BAR_HEIGHT := 52.0
const PANEL_HEIGHT := 244.0
const WARN_COLOR := Color(1.0, 0.78, 0.35)

var _units: Array[UnitData] = []
var _plan: TurnPlan
var _current_unit := 0
var _selected_slot: TimelineSlot
var _locked := false
## Per character: {hp, max_hp, bailed} from the match (set_unit_status).
var _status: Array = []

var _unit_tabs: HBoxContainer
var _timeline_row: HBoxContainer
var _hand_row: HBoxContainer
var _guide: Label
var _at_label: Label
var _at_bar: ProgressBar
var _submit_button: Button

var _current_slots: Array = []  # [tick][slot] -> TimelineSlot


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)
	_build_layout()


## This Control lives directly under a CanvasLayer, so anchors are not resolved
## against a parent Control — size it explicitly from the viewport.
func _fit_viewport() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func setup(units: Array[UnitData]) -> void:
	_units = units.duplicate()
	_plan = TurnPlan.new(_units)
	_current_unit = 0
	_selected_slot = null
	_status.clear()
	for u in _units:
		_status.append({ "hp": u.base_trion_hp, "max_hp": u.base_trion_hp, "bailed": false })
	_refresh_all()


# --- Layout -----------------------------------------------------------------

func _build_layout() -> void:
	var top_bar := PanelContainer.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = TOP_BAR_HEIGHT
	_style_panel(top_bar, Color(0.07, 0.09, 0.14, 0.9))
	add_child(top_bar)

	_unit_tabs = HBoxContainer.new()
	_unit_tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	_unit_tabs.add_theme_constant_override("separation", 8)
	top_bar.add_child(_unit_tabs)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -PANEL_HEIGHT
	_style_panel(bottom, Color(0.06, 0.08, 0.12, 0.94))
	add_child(bottom)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	bottom.add_child(vbox)

	# Top row: what to do next (left), then the AT meter and Submit.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vbox.add_child(head)

	_guide = Label.new()
	_guide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_guide.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_guide.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_guide.add_theme_font_size_override("font_size", 16)
	head.add_child(_guide)

	var at_caption := Label.new()
	at_caption.text = "AT"
	at_caption.tooltip_text = "Action Tokens: every action costs AT. Unused AT does not carry over."
	at_caption.mouse_filter = Control.MOUSE_FILTER_PASS
	at_caption.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	head.add_child(at_caption)

	_at_bar = ProgressBar.new()
	_at_bar.custom_minimum_size = Vector2(150, 16)
	_at_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_at_bar.show_percentage = false
	head.add_child(_at_bar)

	_at_label = Label.new()
	_at_label.custom_minimum_size = Vector2(56, 0)
	head.add_child(_at_label)

	_submit_button = Button.new()
	_submit_button.text = "Submit Turn"
	_submit_button.custom_minimum_size = Vector2(170, 44)
	_submit_button.tooltip_text = "Lock in every character's plan"
	_submit_button.pressed.connect(_on_submit_pressed)
	UiTheme.add_press_feedback(_submit_button)
	head.add_child(_submit_button)

	_timeline_row = HBoxContainer.new()
	_timeline_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_timeline_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_timeline_row)

	_hand_row = HBoxContainer.new()
	_hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_hand_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_hand_row)


func _style_panel(p: PanelContainer, color: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)


# --- Refresh ----------------------------------------------------------------

func _refresh_all() -> void:
	_refresh_unit_tabs()
	_refresh_timeline_view()
	_refresh_hand()
	_refresh_at()


func _refresh_unit_tabs() -> void:
	for c in _unit_tabs.get_children():
		c.queue_free()
	for i in _units.size():
		var st: Dictionary = _status[i] if i < _status.size() else {}
		var b := Button.new()
		var bailed := bool(st.get("bailed", false))
		b.text = "%s   %s" % [_units[i].unit_name,
			"OUT" if bailed else "%d HP" % int(st.get("hp", _units[i].base_trion_hp))]
		b.custom_minimum_size = Vector2(170, 40)
		b.toggle_mode = true
		b.button_pressed = (i == _current_unit)
		b.disabled = bailed
		b.tooltip_text = "Bailed out" if bailed else "Command %s (or tap them on the board)" % _units[i].unit_name
		b.pressed.connect(select_unit.bind(i))
		_unit_tabs.add_child(b)


func _refresh_timeline_view() -> void:
	for c in _timeline_row.get_children():
		c.queue_free()
	_current_slots.clear()
	_selected_slot = null

	# Row captions.
	var captions := VBoxContainer.new()
	captions.add_theme_constant_override("separation", 2)
	var blank := Label.new()
	blank.text = " "
	captions.add_child(blank)
	for text in ["Main", "Sub"]:
		var l := Label.new()
		l.text = text
		l.custom_minimum_size = Vector2(44, 44)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_color", Color(0.65, 0.7, 0.8))
		l.tooltip_text = "Main hand" if text == "Main" else "Off hand: a second action in the same tick costs +1 AT"
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		captions.add_child(l)
	_timeline_row.add_child(captions)

	for tick in TurnPlan.TICKS_PER_TURN:
		var tick_slots: Array = []
		tick_slots.resize(2)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)

		var header := Label.new()
		header.text = "Tick %d" % (tick + 1)
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
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
	targeting_changed.emit()


func _refresh_timeline_cards() -> void:
	for tick in TurnPlan.TICKS_PER_TURN:
		var ta: TickAction = _plan.get_tick(_current_unit, tick)
		for slot in 2:
			var s: TimelineSlot = _current_slots[tick][slot]
			s.set_card(_plan.get_card(_current_unit, tick, slot))
			if ta.slot_has_target(slot):
				s.set_target(ta.slot_target(slot), ta.slot_target_floor(slot))
			else:
				s.clear_target()
			s.set_selected(s == _selected_slot)
	_refresh_guide()


func _refresh_hand() -> void:
	for c in _hand_row.get_children():
		c.queue_free()
	for card in _plan.get_available_actions(_current_unit):
		var ac := ActionCard.new(card)
		ac.tapped.connect(_on_card_tapped)
		_hand_row.add_child(ac)


func _refresh_at() -> void:
	var pool := _plan.get_at_pool(_current_unit)
	var spent := _plan.get_at_spent(_current_unit)
	_at_label.text = "%d / %d" % [spent, pool]
	_at_bar.max_value = pool
	_at_bar.value = spent
	_submit_button.disabled = _locked or not _plan.is_all_valid()
	_refresh_guide()


## One short instruction for what to do next.
func _refresh_guide() -> void:
	if _guide == null or _units.is_empty():
		return
	var who := _units[_current_unit].unit_name
	var text := ""
	var color := Color(0.85, 0.9, 1.0)
	if _locked:
		text = "Plan locked in. Watch the turn play out."
	elif _selected_slot == null:
		text = "%s: tap an action card below to add it to the next free tick." % who
	else:
		var card := _plan.get_card(_current_unit, _selected_slot.tick_index, _selected_slot.slot_id)
		var ta: TickAction = _plan.get_tick(_current_unit, _selected_slot.tick_index)
		var tick := _selected_slot.tick_index + 1
		if card == null:
			text = "Tick %d selected: tap an action card to place it here." % tick
		elif TurnPlan.needs_target(card) and not ta.slot_has_target(_selected_slot.slot_id):
			text = "Tap a highlighted hex on the board to aim %s (tick %d)." % [card.card_name, tick]
			color = WARN_COLOR
		else:
			text = "%s set for tick %d. Add more actions, pick another character, or Submit Turn." % [card.card_name, tick]
			color = READY_COLOR
	var missing := _missing_targets()
	if not _locked and missing > 0 and color != WARN_COLOR:
		text += "   (%d action%s still need%s a target)" % [missing, "" if missing == 1 else "s", "s" if missing == 1 else ""]
	_guide.text = text
	_guide.add_theme_color_override("font_color", color)


## Placed actions of the whole squad that still need a hex.
func _missing_targets() -> int:
	var n := 0
	for u in _units.size():
		if u < _status.size() and bool(_status[u].get("bailed", false)):
			continue
		for t in TurnPlan.TICKS_PER_TURN:
			var ta := _plan.get_tick(u, t)
			for slot in [TurnPlan.MAIN_SLOT, TurnPlan.SUB_SLOT]:
				if TurnPlan.needs_target(ta.slot_card(slot)) and not ta.slot_has_target(slot):
					n += 1
	return n


# --- Public API ---------------------------------------------------------------

## Switches the plan view to character `i` and tells the board (which focuses
## the camera on it). Selecting the current character again re-focuses.
func select_unit(i: int) -> void:
	if i < 0 or i >= _units.size():
		return
	if i < _status.size() and bool(_status[i].get("bailed", false)):
		_refresh_unit_tabs()
		return
	if i != _current_unit:
		_current_unit = i
		_refresh_all()
	else:
		_refresh_unit_tabs()
	unit_selected.emit(i)


## HP / bail-out state for a character tab. Switches away from a character
## that just bailed out.
func set_unit_status(i: int, hp: int, max_hp: int, bailed: bool) -> void:
	while _status.size() <= i:
		_status.append({})
	_status[i] = { "hp": hp, "max_hp": max_hp, "bailed": bailed }
	if bailed and i == _current_unit:
		for j in _units.size():
			if j < _status.size() and not bool(_status[j].get("bailed", false)):
				_current_unit = j
				_refresh_all()
				return
	_refresh_unit_tabs()


## Sets the target/destination hex (and optional floor) for the selected tick
## slot (Main and Sub aim independently). Called when the player taps a hex.
func set_target_for_selected_slot(hex: Vector2i, floor: int = 0) -> void:
	if _selected_slot == null or _locked:
		return
	var card := _plan.get_card(_selected_slot.unit_index, _selected_slot.tick_index, _selected_slot.slot_id)
	if card == null:
		return
	_plan.set_target(_selected_slot.unit_index, _selected_slot.tick_index, hex, floor, _selected_slot.slot_id)
	_refresh_timeline_cards()
	targeting_changed.emit()


func has_selected_slot() -> bool:
	return _selected_slot != null


func get_plan() -> TurnPlan:
	return _plan


func get_units() -> Array[UnitData]:
	return _units


func get_current_unit() -> int:
	return _current_unit


## Info about the selected tick slot, used by the board to compute valid
## move/attack hexes. Empty Dictionary when nothing is selected.
func get_selected_target_info() -> Dictionary:
	if _selected_slot == null:
		return {}
	var ta: TickAction = _plan.get_tick(_selected_slot.unit_index, _selected_slot.tick_index)
	var card: TriggerCard = ta.sub_card if _selected_slot.slot_id == TurnPlan.SUB_SLOT else ta.main_card
	return {
		"unit": _selected_slot.unit_index,
		"tick": _selected_slot.tick_index,
		"slot": _selected_slot.slot_id,
		"card": card,
	}


func set_locked(locked: bool) -> void:
	_locked = locked
	_refresh_at()


## Resets the plan for the next turn (AT does not carry over, GDD 5.1).
func begin_new_turn() -> void:
	_plan = TurnPlan.new(_units)
	_locked = false
	_refresh_all()


# --- Interaction ------------------------------------------------------------

func _on_slot_selected(slot: TimelineSlot) -> void:
	if _locked:
		return
	_selected_slot = slot
	_refresh_timeline_cards()
	targeting_changed.emit()


## Tap-to-place: the card goes into the selected tick if it is empty, else
## into the next free tick after it (so tapping cards one after another
## builds the turn in order). Drag a card onto a filled tick to replace it.
func _on_card_tapped(card: TriggerCard) -> void:
	if _locked:
		return
	var u := _current_unit
	var start := 0
	if _selected_slot != null:
		if _plan.get_card(u, _selected_slot.tick_index, _selected_slot.slot_id) == null:
			if _try_place(u, _selected_slot.tick_index, _selected_slot.slot_id, card):
				_after_place(_selected_slot.tick_index, _selected_slot.slot_id)
				return
		start = _selected_slot.tick_index
	for tick in range(start, TurnPlan.TICKS_PER_TURN):
		for slot in [TurnPlan.MAIN_SLOT, TurnPlan.SUB_SLOT]:
			if _plan.get_card(u, tick, slot) != null:
				continue
			if slot == TurnPlan.SUB_SLOT and _plan.get_card(u, tick, TurnPlan.MAIN_SLOT) == null:
				continue   # fill Main first
			if _try_place(u, tick, slot, card):
				_after_place(tick, slot)
				return
	_flash_guide("Not enough AT (or no free tick) for %s." % card.card_name)


## Puts `card` in a slot; a different card replaces the old one and its target.
func _try_place(u: int, tick: int, slot: int, card: TriggerCard) -> bool:
	var old := _plan.get_card(u, tick, slot)
	if old == card:
		return true
	if not _plan.can_assign(u, tick, slot, card):
		return false
	_plan.assign(u, tick, slot, card)
	_plan.get_tick(u, tick).clear_slot_target(slot)
	return true


func _after_place(tick: int, slot: int) -> void:
	_selected_slot = _current_slots[tick][slot]
	_refresh_timeline_cards()
	_refresh_at()
	targeting_changed.emit()


func _flash_guide(text: String) -> void:
	_guide.text = text
	_guide.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))


func _on_slot_dropped(slot: TimelineSlot, data: Dictionary) -> void:
	if _locked:
		return
	var card: TriggerCard = data["card"]
	var is_move: bool = data.get("from_slot", false)
	var u := slot.unit_index

	if is_move:
		var src_unit: int = data["unit"]
		var src_tick: int = data["tick"]
		var src_slot: int = data["slot"]
		if src_unit != u:
			return  # cards cannot be moved across characters
		if src_tick == slot.tick_index and src_slot == slot.slot_id:
			return  # dropped on itself
		# A moved action keeps its target.
		var src := _plan.get_tick(src_unit, src_tick)
		var had := src.slot_has_target(src_slot)
		var hex := src.slot_target(src_slot)
		var floor := src.slot_target_floor(src_slot)
		_plan.clear(src_unit, src_tick, src_slot)
		if _try_place(u, slot.tick_index, slot.slot_id, card):
			if had:
				_plan.set_target(u, slot.tick_index, hex, floor, slot.slot_id)
		else:
			_plan.assign(src_unit, src_tick, src_slot, card)  # restore source
			if had:
				_plan.set_target(src_unit, src_tick, hex, floor, src_slot)
			_flash_guide("%s doesn't fit there (slot rules or AT)." % card.card_name)
	elif not _try_place(u, slot.tick_index, slot.slot_id, card):
		_flash_guide("%s doesn't fit there (slot rules or AT)." % card.card_name)
		return

	_selected_slot = slot
	_refresh_timeline_cards()
	_refresh_at()
	targeting_changed.emit()


func _on_slot_clear(slot: TimelineSlot) -> void:
	if _locked:
		return
	if _plan.clear(slot.unit_index, slot.tick_index, slot.slot_id):
		_refresh_timeline_cards()
		_refresh_at()
		targeting_changed.emit()


func _on_submit_pressed() -> void:
	if _locked or not _plan.is_all_valid():
		return
	plan_submitted.emit()
