class_name TimelineUI
extends Control
## The planning HUD.
##
## Top bar: one tab per character (name + HP); tap one, or tap the character
## on the board, to command it. Bottom panel: what to do next, then the
## character's turn as two time lanes on a 6-second ruler:
##   Movement   Move / Jump / Wait blocks
##   Actions    attacks, Shield, Look, Bagworm, Spider, Wait blocks
## Each block is as wide as the time the action takes (Stamina makes blocks
## shorter). Tap a card to add it to the end of its lane, tap the board to
## aim it, tap a block to select it, right-click / double-tap to remove it.
## The middle of the screen passes input through to the 3D board.

signal unit_selected(unit_index: int)
signal plan_submitted
## The selected block, or the plan, changed (the board refreshes previews).
signal selection_changed

const READY_COLOR := Color(0.45, 0.95, 0.6)
const WARN_COLOR := Color(1.0, 0.78, 0.35)
const ERROR_COLOR := Color(1.0, 0.5, 0.45)
## HUD footprint, shared with the combat log and camera framing.
const TOP_BAR_HEIGHT := 52.0
const PANEL_HEIGHT := 252.0
## Lane width in pixels for the whole turn.
const LANE_WIDTH := 720.0
const LANE_HEIGHT := 40.0
const HOLD_STEP := 0.25

var _units: Array[UnitData] = []
var _plan: TurnPlan
var _current_unit := 0
var _sel_lane := -1
var _sel_index := -1
var _locked := false
var _status: Array = []   # per unit {hp, max_hp, bailed}
var _ms: MatchState
var _states: Array = []   # own UnitStates (start of turn)

var _unit_tabs: HBoxContainer
var _guide: Label
var _hold_box: HBoxContainer
var _hold_label: Label
var _submit_button: Button
var _tracks: Array = []        # [Control] per lane
var _left_labels: Array = []   # [Label] per lane
var _hand_row: HBoxContainer
var _flash_until := 0
## Submit pressed with an unfinished plan: a second press before this time
## submits without the unfinished parts.
var _submit_armed_until := 0
const SUBMIT_CONFIRM_MS := 4000


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)
	_build_layout()


func _fit_viewport() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func setup(units: Array[UnitData]) -> void:
	_units = units.duplicate()
	_plan = TurnPlan.new(_units)
	_current_unit = 0
	_clear_selection()
	_status.clear()
	for u in _units:
		_status.append({ "hp": u.base_trion_hp, "max_hp": u.base_trion_hp, "bailed": false })
	_refresh_all()


## The match the plan is timed against and the squad's characters in it
## (route lengths depend on the map and where each character stands).
func bind(ms: MatchState, states: Array) -> void:
	_ms = ms
	_states = states
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

	# Head row: what to do next, hold-time stepper, Submit.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vbox.add_child(head)
	_guide = Label.new()
	_guide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_guide.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_guide.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_guide.add_theme_font_size_override("font_size", 16)
	head.add_child(_guide)
	_hold_box = HBoxContainer.new()
	_hold_box.add_theme_constant_override("separation", 4)
	head.add_child(_hold_box)
	var minus := _small_button("−", "Shorter (%.2f s)" % HOLD_STEP)
	minus.pressed.connect(_change_hold.bind(-HOLD_STEP))
	_hold_box.add_child(minus)
	_hold_label = Label.new()
	_hold_label.custom_minimum_size = Vector2(64, 0)
	_hold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hold_box.add_child(_hold_label)
	var plus := _small_button("+", "Longer (%.2f s)" % HOLD_STEP)
	plus.pressed.connect(_change_hold.bind(HOLD_STEP))
	_hold_box.add_child(plus)
	_submit_button = Button.new()
	_submit_button.text = "Submit Turn"
	_submit_button.custom_minimum_size = Vector2(170, 44)
	_submit_button.tooltip_text = "Lock in every character's plan"
	_submit_button.pressed.connect(_on_submit_pressed)
	UiTheme.add_press_feedback(_submit_button)
	head.add_child(_submit_button)

	# Time ruler + two lanes.
	var lanes := VBoxContainer.new()
	lanes.add_theme_constant_override("separation", 3)
	lanes.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(lanes)
	var ruler_row := HBoxContainer.new()
	ruler_row.add_theme_constant_override("separation", 8)
	lanes.add_child(ruler_row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(92, 0)
	ruler_row.add_child(pad)
	var ruler := Ruler.new()
	ruler.custom_minimum_size = Vector2(LANE_WIDTH, 16)
	ruler_row.add_child(ruler)
	for lane_id in [TurnPlan.MOVE_LANE, TurnPlan.ACT_LANE]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		lanes.add_child(row)
		var caption := Label.new()
		caption.text = "Movement" if lane_id == TurnPlan.MOVE_LANE else "Actions"
		caption.custom_minimum_size = Vector2(92, LANE_HEIGHT)
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.add_theme_color_override("font_color", Color(0.7, 0.76, 0.86))
		caption.tooltip_text = "Where the character goes: Move, Jump, Wait" if lane_id == TurnPlan.MOVE_LANE \
			else "What it does meanwhile: attacks, Shield, Look, Bagworm, Spider, Wait"
		caption.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(caption)
		var track := Track.new()
		track.custom_minimum_size = Vector2(LANE_WIDTH, LANE_HEIGHT)
		row.add_child(track)
		_tracks.append(track)
		var wait := _small_button("+ Wait", "Add a pause to this lane")
		wait.custom_minimum_size = Vector2(76, LANE_HEIGHT)
		wait.pressed.connect(_add_wait.bind(lane_id))
		row.add_child(wait)
		var left := Label.new()
		left.custom_minimum_size = Vector2(70, 0)
		left.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(left)
		_left_labels.append(left)

	_hand_row = HBoxContainer.new()
	_hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_hand_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_hand_row)


func _small_button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(44, 40)
	b.focus_mode = Control.FOCUS_NONE
	return b


func _style_panel(p: PanelContainer, color: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)


# --- Refresh ----------------------------------------------------------------

func _refresh_all() -> void:
	if _plan == null:
		return
	_refresh_unit_tabs()
	_refresh_lanes()
	_refresh_hand()


func _refresh_unit_tabs() -> void:
	for c in _unit_tabs.get_children():
		c.queue_free()
	for i in _units.size():
		var st: Dictionary = _status[i] if i < _status.size() else {}
		var b := Button.new()
		var bailed := bool(st.get("bailed", false))
		var hp_text := "OUT" if bailed else "%d HP" % int(st.get("hp", _units[i].base_trion_hp))
		var warn := not bailed and not _problem_of(i).is_empty()
		b.text = "%s%s   %s" % ["⚠ " if warn else "", _units[i].unit_name, hp_text]
		if warn:
			b.add_theme_color_override("font_color", WARN_COLOR)
		b.custom_minimum_size = Vector2(170, 40)
		b.toggle_mode = true
		b.button_pressed = (i == _current_unit)
		b.disabled = bailed
		if bailed:
			b.tooltip_text = "Bailed out"
		elif warn:
			b.tooltip_text = "%s: %s" % [_units[i].unit_name, _problem_of(i)["text"]]
		else:
			b.tooltip_text = "Command %s (or tap them on the board)" % _units[i].unit_name
		b.pressed.connect(select_unit.bind(i))
		_unit_tabs.add_child(b)


## Rebuilds both lanes' blocks from the plan's timing.
func _refresh_lanes() -> void:
	if _plan == null or _tracks.is_empty():
		return
	var u := _current_unit
	var schedules := [_move_schedule(), _plan.act_schedule(u)]
	var error := _unit_error()
	for lane_id in 2:
		var track: Control = _tracks[lane_id]
		for c in track.get_children():
			c.queue_free()
		var sched: Array = schedules[lane_id]
		for i in sched.size():
			var e: Dictionary = sched[i]
			var a: PlanAction = e["action"]
			var start := float(e["start"])
			var end := float(e["end"])
			var bad := (lane_id == TurnPlan.MOVE_LANE and not bool(e.get("ok", true)) and not a.needs_target()) \
				or end > TurnPlan.TURN_SECONDS + TurnPlan.TIME_EPSILON
			var block := Block.new(a, end - start, lane_id == _sel_lane and i == _sel_index, a.needs_target(), bad)
			var x0 := clampf(start / TurnPlan.TURN_SECONDS, 0.0, 1.0) * LANE_WIDTH
			var w := maxf(34.0, clampf(end / TurnPlan.TURN_SECONDS, 0.0, 1.0) * LANE_WIDTH - x0)
			if x0 + w > LANE_WIDTH:
				x0 = maxf(0.0, LANE_WIDTH - w)
			block.position = Vector2(x0, 2)
			block.size = Vector2(w - 2, LANE_HEIGHT - 4)
			block.selected.connect(_on_block_selected.bind(lane_id, i))
			block.remove_requested.connect(_on_block_remove.bind(lane_id, i))
			track.add_child(block)
		var used := 0.0 if sched.is_empty() else float(sched.back()["end"])
		var left: Label = _left_labels[lane_id]
		left.text = "%.1f s left" % maxf(0.0, TurnPlan.TURN_SECONDS - used)
		left.add_theme_color_override("font_color", ERROR_COLOR if used > TurnPlan.TURN_SECONDS + TurnPlan.TIME_EPSILON else Color(0.7, 0.76, 0.86))
	var sel := get_selected_action()
	_hold_box.visible = sel != null and sel.uses_hold() and not _locked
	if sel != null and sel.uses_hold():
		_hold_label.text = "%.2f s" % sel.hold
	# Submit always answers: if a plan is unfinished it says which and where.
	var problem := squad_problem()
	_submit_button.disabled = _locked or _ms == null
	_submit_button.modulate = Color(1.0, 0.85, 0.55) if not problem.is_empty() and not _locked else Color.WHITE
	if problem.is_empty():
		_submit_button.tooltip_text = "Lock in every character's plan"
	else:
		_submit_button.tooltip_text = "%s: %s" % [_units[int(problem["unit"])].unit_name, problem["text"]]
	_refresh_unit_tabs()
	_refresh_guide(error)


func _refresh_hand() -> void:
	for c in _hand_row.get_children():
		c.queue_free()
	if _plan == null:
		return
	for card in _plan.get_available_actions(_current_unit):
		if card.card_name == "Wait":
			continue   # each lane has its own + Wait button
		var ac := ActionCard.new(card, _units[_current_unit])
		ac.tapped.connect(_on_card_tapped)
		_hand_row.add_child(ac)


func _move_schedule() -> Array:
	if _ms == null or _current_unit >= _states.size():
		return []
	return _plan.move_schedule(_ms, _states[_current_unit], _current_unit)


func _unit_error() -> String:
	if _ms == null or _current_unit >= _states.size():
		return ""
	return _plan.unit_error(_ms, _states[_current_unit], _current_unit)


## One short instruction for what to do next.
func _refresh_guide(error: String = "") -> void:
	if _guide == null or _units.is_empty() or Time.get_ticks_msec() < _flash_until:
		return
	var who := _units[_current_unit].unit_name
	var text := ""
	var color := Color(0.85, 0.9, 1.0)
	var sel := get_selected_action()
	if _locked:
		text = "Plan locked in. Watch the turn play out."
	elif sel == null:
		text = "%s: tap an action below. It goes on the end of its lane; you have %.0f seconds." % [who, TurnPlan.TURN_SECONDS]
	elif sel.needs_target():
		color = WARN_COLOR
		match sel.card.card_name:
			"Move":
				text = "Tap the street or a roof to send %s there (tap a building again for lower floors)." % who
			"Grasshopper":
				text = "Tap the street or a roof within %.1f m to jump there." % CityGeometry.JUMP_RANGE
			"Look":
				text = "Tap the spot %s should keep watching." % who
			"Spider":
				text = "Tap a street spot within %.0f m to string the wire." % TurnEngine.SPIDER_RANGE
			_:
				text = "Tap an enemy to target with %s." % sel.card.card_name
	else:
		color = READY_COLOR
		text = "%s set. Add more, pick another character, or Submit Turn." % sel.card.card_name
	if error != "" and not _locked and (sel == null or not sel.needs_target()):
		text = "%s: %s" % [who, error]
		color = ERROR_COLOR
	elif not _locked and (sel == null or not sel.needs_target()):
		# Another character's plan is what holds up Submit: say so.
		var problem := squad_problem()
		if not problem.is_empty() and int(problem["unit"]) != _current_unit:
			text = "%s needs attention: %s (tap the ⚠ tab)." % [_units[int(problem["unit"])].unit_name, problem["text"]]
			color = WARN_COLOR
	_guide.text = text
	_guide.add_theme_color_override("font_color", color)


# --- Public API ---------------------------------------------------------------

func select_unit(i: int) -> void:
	if i < 0 or i >= _units.size():
		return
	if i < _status.size() and bool(_status[i].get("bailed", false)):
		_refresh_unit_tabs()
		return
	if i != _current_unit:
		_current_unit = i
		_clear_selection()
		_refresh_all()
	else:
		_refresh_unit_tabs()
	unit_selected.emit(i)
	selection_changed.emit()


func set_unit_status(i: int, hp: int, max_hp: int, bailed: bool) -> void:
	while _status.size() <= i:
		_status.append({})
	_status[i] = { "hp": hp, "max_hp": max_hp, "bailed": bailed }
	if bailed and i == _current_unit:
		for j in _units.size():
			if j < _status.size() and not bool(_status[j].get("bailed", false)):
				_current_unit = j
				_clear_selection()
				_refresh_all()
				return
	_refresh_unit_tabs()


## The selected block's action, or null.
func get_selected_action() -> PlanAction:
	if _plan == null or _sel_lane < 0:
		return null
	var l := _plan.lane(_current_unit, _sel_lane)
	return l[_sel_index] if _sel_index >= 0 and _sel_index < l.size() else null


## {unit, lane, index, action} for the selected block, or {}.
func get_selection() -> Dictionary:
	var a := get_selected_action()
	if a == null:
		return {}
	return { "unit": _current_unit, "lane": _sel_lane, "index": _sel_index, "action": a }


func has_selection() -> bool:
	return get_selected_action() != null


## Call after changing the selected action's target from the board.
func plan_edited() -> void:
	_refresh_lanes()
	selection_changed.emit()


## A short message in the guide line (e.g. why a tap was refused).
func flash(text: String) -> void:
	_guide.text = text
	_guide.add_theme_color_override("font_color", ERROR_COLOR)
	_flash_until = Time.get_ticks_msec() + 2500


func get_plan() -> TurnPlan:
	return _plan


func get_units() -> Array[UnitData]:
	return _units


func get_current_unit() -> int:
	return _current_unit


func set_locked(locked: bool) -> void:
	_locked = locked
	_refresh_lanes()


## A fresh plan for the next turn (nothing carries over).
func begin_new_turn() -> void:
	_plan = TurnPlan.new(_units)
	_locked = false
	_clear_selection()
	_refresh_all()
	selection_changed.emit()


# --- Interaction ------------------------------------------------------------

func _clear_selection() -> void:
	_sel_lane = -1
	_sel_index = -1


func _on_block_selected(lane_id: int, index: int) -> void:
	if _locked:
		return
	_sel_lane = lane_id
	_sel_index = index
	_refresh_lanes()
	selection_changed.emit()


func _on_block_remove(lane_id: int, index: int) -> void:
	if _locked:
		return
	_plan.remove(_current_unit, lane_id, index)
	if _sel_lane == lane_id:
		if _sel_index == index:
			_clear_selection()
		elif _sel_index > index:
			_sel_index -= 1
	_refresh_lanes()
	selection_changed.emit()


func _on_card_tapped(card: TriggerCard) -> void:
	_append(PlanAction.new(card), TurnPlan.lane_for(card))


func _add_wait(lane_id: int) -> void:
	_append(PlanAction.new(TriggerLibrary.get_wait_card()), lane_id)


func _append(a: PlanAction, lane_id: int) -> void:
	if _locked or _plan == null:
		return
	var used := 0.0
	if lane_id == TurnPlan.MOVE_LANE:
		var sched := _move_schedule()
		used = 0.0 if sched.is_empty() else float(sched.back()["end"])
	else:
		used = _plan.act_used(_current_unit)
	if used >= TurnPlan.TURN_SECONDS - 0.05:
		flash("No time left in the %s lane. Remove or shorten something first." % ("Movement" if lane_id == TurnPlan.MOVE_LANE else "Actions"))
		return
	if a.uses_hold():
		a.hold = clampf(snappedf(minf(a.hold, TurnPlan.TURN_SECONDS - used), HOLD_STEP), TurnPlan.MIN_HOLD, TurnPlan.TURN_SECONDS)
	if not _plan.add(_current_unit, a, lane_id):
		flash("That lane is full.")
		return
	_sel_lane = lane_id
	_sel_index = _plan.lane(_current_unit, lane_id).size() - 1
	_refresh_lanes()
	selection_changed.emit()


func _change_hold(delta: float) -> void:
	var a := get_selected_action()
	if a == null or not a.uses_hold() or _locked:
		return
	a.hold = clampf(a.hold + delta, TurnPlan.MIN_HOLD, TurnPlan.TURN_SECONDS)
	_refresh_lanes()
	selection_changed.emit()


## Submit. With every plan complete it locks in. Otherwise the first press
## jumps to the first unfinished block and explains it; a second press within
## SUBMIT_CONFIRM_MS submits without the unfinished parts.
func _on_submit_pressed() -> void:
	if _locked or _ms == null:
		return
	var problem := squad_problem()
	if not problem.is_empty():
		var now := Time.get_ticks_msec()
		if now > _submit_armed_until:
			_submit_armed_until = now + SUBMIT_CONFIRM_MS
			var u := int(problem["unit"])
			if u != _current_unit:
				_current_unit = u
				_refresh_all()
				unit_selected.emit(u)
			_sel_lane = int(problem["lane"])
			_sel_index = int(problem["index"])
			_refresh_lanes()
			selection_changed.emit()
			flash("%s: %s. Fix it, or press Submit again to go without it." % [_units[u].unit_name, problem["text"]])
			return
		_plan.sanitize(_ms, _states)
		_clear_selection()
	_submit_armed_until = 0
	if not _plan.is_all_valid(_ms, _states):
		flash("This plan can't be submitted.")
		_refresh_lanes()
		return
	plan_submitted.emit()


## The first unfinished plan in the squad: {unit, lane, index, text}, or {}.
func squad_problem() -> Dictionary:
	if _plan == null or _ms == null:
		return {}
	for i in _units.size():
		var p := _problem_of(i)
		if not p.is_empty():
			p["unit"] = i
			return p
	return {}


func _problem_of(i: int) -> Dictionary:
	if _plan == null or _ms == null or i >= _states.size():
		return {}
	var us: UnitState = _states[i]
	if us.is_bailed or (i < _status.size() and bool(_status[i].get("bailed", false))):
		return {}
	return _plan.unit_problem(_ms, us, i)


## Planned actions across the squad that still need a target.
func _missing_targets() -> int:
	var n := 0
	for u in _units.size():
		if u < _status.size() and bool(_status[u].get("bailed", false)):
			continue
		for lane_id in [TurnPlan.MOVE_LANE, TurnPlan.ACT_LANE]:
			for a in _plan.lane(u, lane_id):
				if (a as PlanAction).needs_target():
					n += 1
	return n


# --- Pieces ---------------------------------------------------------------------

## Seconds ruler over the lanes.
class Ruler extends Control:
	func _draw() -> void:
		var font := get_theme_default_font()
		for s in int(TurnPlan.TURN_SECONDS) + 1:
			var x := size.x * s / TurnPlan.TURN_SECONDS
			draw_line(Vector2(x, size.y - 5), Vector2(x, size.y), Color(0.6, 0.66, 0.78, 0.8), 1.0)
			var label := "%ds" % s
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(font, Vector2(clampf(x - w * 0.5, 0.0, size.x - w), size.y - 6), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.66, 0.78))


## A lane's background with second marks.
class Track extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.12, 0.18, 0.95))
		for s in range(1, int(TurnPlan.TURN_SECONDS)):
			var x := size.x * s / TurnPlan.TURN_SECONDS
			draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.3, 0.38, 0.5, 0.35), 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.3, 0.4, 0.55, 0.6), false, 1.0)


## One planned action on a lane.
class Block extends Button:
	signal selected
	signal remove_requested

	func _init(a: PlanAction, seconds: float, is_selected: bool, needs_aim: bool, bad: bool) -> void:
		focus_mode = Control.FOCUS_NONE
		clip_text = true
		text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var label := a.card.card_name
		if a.card.card_name == "Grasshopper":
			label = "Jump"
		text = "%s · aim" % label if needs_aim else "%s %.1fs" % [label, seconds]
		tooltip_text = a.card.describe() + "\nRight-click or double-tap to remove."
		var accent: Color = ActionCard.TYPE_COLORS.get(a.card.card_type, Color(0.4, 0.6, 0.9))
		if a.card.jump:
			accent = ActionCard.TYPE_COLORS[TriggerCard.CardType.MOVE]
		if a.card.card_name == "Wait":
			accent = Color(0.5, 0.55, 0.65)
		var sb := StyleBoxFlat.new()
		sb.bg_color = accent.darkened(0.55)
		sb.border_color = Color(1.0, 0.4, 0.35) if bad else (Color(1.0, 0.8, 0.4) if needs_aim else (Color.WHITE if is_selected else accent))
		sb.set_border_width_all(3 if is_selected else 2)
		sb.set_corner_radius_all(5)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		for state in ["normal", "hover", "pressed", "disabled"]:
			add_theme_stylebox_override(state, sb)
		add_theme_font_size_override("font_size", 13)
		add_theme_color_override("font_color", Color.WHITE)
		add_theme_color_override("font_hover_color", Color.WHITE)
		add_theme_color_override("font_pressed_color", Color.WHITE)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_RIGHT or (event.button_index == MOUSE_BUTTON_LEFT and event.double_click):
				remove_requested.emit()
				accept_event()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				selected.emit()
				accept_event()
