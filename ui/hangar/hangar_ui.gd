class_name HangarUI
extends Control
## Pre-match deck-building screen (GDD section 6): configure each unit's
## 8-slot Trigger Holder (4 Main + 4 Sub) against a Trion budget.

var _units: Array[UnitData] = []
var _current_unit := 0

var _unit_tabs: HBoxContainer
var _budget_label: Label
var _budget_bar: ProgressBar
var _main_col: VBoxContainer
var _sub_col: VBoxContainer
var _palette: HBoxContainer
var _start_button: Button
var _server_input: LineEdit
var _join_input: LineEdit
var _host_btn: Button
var _join_btn: Button
var _net_status: Label
var _name_input: LineEdit
var _ranked_btn: Button
var _live_btn: Button
var _searching := false
var _host_live: CheckBox
var _conn: GameConnection
var _search_mode := ""
var _resume_btn: Button
var _delete_btn: Button
var _delete_armed_at := -1
const DELETE_CONFIRM_MS := 4000


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UiTheme.install(get_tree())
	if MatchSession.server_url == ServerConfig.DEV_URL or not ServerConfig.allow_custom_server():
		MatchSession.server_url = ServerConfig.default_url()
	_conn = GameConnection.new()
	_conn.name = "GameConnection"
	add_child(_conn)
	_build_layout()
	_load_squad()


func _load_squad() -> void:
	_units = SquadStore.get_squad()
	for u in _units:
		u.ensure_slot_arrays()
	_current_unit = 0
	_refresh_all()


# --- Layout -----------------------------------------------------------------

func _build_layout() -> void:
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 48
	vbox.offset_right = -48
	vbox.offset_top = 10
	vbox.offset_bottom = -10
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	var title := Label.new()
	title.text = "SQUAD SETUP"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)

	_unit_tabs = HBoxContainer.new()
	_unit_tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	_unit_tabs.add_theme_constant_override("separation", 8)
	vbox.add_child(_unit_tabs)

	# Middle: talent points (left) and the selected character's loadout (right).
	var middle := HBoxContainer.new()
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	middle.add_theme_constant_override("separation", 28)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(middle)
	_build_talent_panel(middle)

	var loadout := VBoxContainer.new()
	loadout.add_theme_constant_override("separation", 6)
	middle.add_child(loadout)

	var budget_row := HBoxContainer.new()
	budget_row.alignment = BoxContainer.ALIGNMENT_CENTER
	budget_row.add_theme_constant_override("separation", 12)
	loadout.add_child(budget_row)

	_budget_label = Label.new()
	_budget_label.add_theme_font_size_override("font_size", 16)
	_budget_label.tooltip_text = "Equipped triggers cost Trion; each character can carry up to %d." % TriggerLibrary.STANDARD_TRION_CAPACITY
	budget_row.add_child(_budget_label)

	_budget_bar = ProgressBar.new()
	_budget_bar.custom_minimum_size = Vector2(260, 16)
	_budget_bar.show_percentage = false
	budget_row.add_child(_budget_bar)

	var columns := HBoxContainer.new()
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_theme_constant_override("separation", 20)
	loadout.add_child(columns)

	_main_col = _build_column("Main Slots", columns)
	_sub_col = _build_column("Sub Slots", columns)

	var palette_label := Label.new()
	palette_label.text = "Available Triggers (drag into slots · right-click or double-tap a slot to clear)"
	palette_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(palette_label)

	var palette_scroll := ScrollContainer.new()
	palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	palette_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	palette_scroll.custom_minimum_size = Vector2(0, 58)
	vbox.add_child(palette_scroll)

	_palette = HBoxContainer.new()
	_palette.alignment = BoxContainer.ALIGNMENT_CENTER
	_palette.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_palette.add_theme_constant_override("separation", 8)
	palette_scroll.add_child(_palette)

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 16)
	vbox.add_child(bottom)

	var reset := Button.new()
	reset.text = "Reset Squad"
	reset.pressed.connect(_on_reset_pressed)
	bottom.add_child(reset)

	_start_button = Button.new()
	_start_button.text = "Start Match"
	_start_button.custom_minimum_size = Vector2(220, 44)
	_start_button.pressed.connect(_on_start_pressed)
	bottom.add_child(_start_button)

	# --- Async multiplayer section ---
	var mp_label := Label.new()
	mp_label.text = "— Online —"
	mp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(mp_label)

	var mp_row := HBoxContainer.new()
	mp_row.alignment = BoxContainer.ALIGNMENT_CENTER
	mp_row.add_theme_constant_override("separation", 8)
	vbox.add_child(mp_row)

	_server_input = LineEdit.new()
	_server_input.text = MatchSession.server_url
	_server_input.placeholder_text = "Server URL"
	_server_input.custom_minimum_size = Vector2(240, 0)
	# Store builds always talk to the production server (ServerConfig).
	_server_input.visible = ServerConfig.allow_custom_server()
	mp_row.add_child(_server_input)

	_host_btn = Button.new()
	_host_btn.text = "Host Online Match"
	_host_btn.pressed.connect(_on_host_online)
	mp_row.add_child(_host_btn)

	_host_live = CheckBox.new()
	_host_live.text = "Live clock"
	_host_live.tooltip_text = "Friendly battle on the live turn clock instead of async turns"
	mp_row.add_child(_host_live)

	_join_input = LineEdit.new()
	_join_input.placeholder_text = "Match ID"
	_join_input.custom_minimum_size = Vector2(170, 0)
	mp_row.add_child(_join_input)

	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.pressed.connect(_on_join_online)
	mp_row.add_child(_join_btn)

	# Ranked matchmaking: account (remembered per server) + rating-based queue.
	var ranked_row := HBoxContainer.new()
	ranked_row.alignment = BoxContainer.ALIGNMENT_CENTER
	ranked_row.add_theme_constant_override("separation", 8)
	vbox.add_child(ranked_row)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Player name"
	_name_input.max_length = 20
	_name_input.custom_minimum_size = Vector2(200, 0)
	var saved := AccountStore.load_for(MatchSession.server_url)
	_name_input.text = str(saved.get("name", ""))
	ranked_row.add_child(_name_input)

	# Live Battle is the trophy ladder (short turn clock, both players
	# online); Async Ranked is the correspondence queue (long turn timer).
	_live_btn = Button.new()
	_live_btn.text = "Live Battle"
	_live_btn.custom_minimum_size = Vector2(200, 40)
	_live_btn.pressed.connect(_on_find_ranked.bind("live"))
	ranked_row.add_child(_live_btn)

	_ranked_btn = Button.new()
	_ranked_btn.text = "Async Ranked"
	_ranked_btn.custom_minimum_size = Vector2(200, 40)
	_ranked_btn.pressed.connect(_on_find_ranked.bind("async"))
	ranked_row.add_child(_ranked_btn)

	_resume_btn = Button.new()
	_resume_btn.text = "Resume Match"
	_resume_btn.tooltip_text = "Get back into a ranked match that is still running"
	_resume_btn.pressed.connect(_on_resume_pressed)
	ranked_row.add_child(_resume_btn)

	# Account deletion must be available in-app (App Store 5.1.1(v), Google
	# Play data-deletion policy). Two taps: the first only arms it.
	_delete_btn = Button.new()
	_delete_btn.text = "Delete Account"
	_delete_btn.add_theme_color_override("font_color", UiTheme.DANGER)
	_delete_btn.visible = not saved.is_empty()
	_delete_btn.pressed.connect(_on_delete_account_pressed)
	ranked_row.add_child(_delete_btn)

	for b in find_children("*", "BaseButton", true, false):
		UiTheme.add_press_feedback(b)

	_net_status = Label.new()
	_net_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_net_status.modulate = Color(1.0, 0.7, 0.5)
	vbox.add_child(_net_status)


func _build_column(title_text: String, parent: HBoxContainer) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	var header := Label.new()
	header.text = title_text
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 18)
	col.add_child(header)
	parent.add_child(col)
	return col


# --- Refresh ----------------------------------------------------------------

func _refresh_all() -> void:
	_refresh_unit_tabs()
	_refresh_slots()
	_refresh_palette()
	_refresh_budget()
	_refresh_talents()


func _refresh_unit_tabs() -> void:
	for c in _unit_tabs.get_children():
		c.queue_free()
	for i in _units.size():
		var u := _units[i]
		var b := Button.new()
		b.text = u.unit_name
		b.tooltip_text = "HP %d · AT %d · ATK %d" % [u.base_trion_hp, TurnPlan.new([u]).get_at_pool(0), u.attack_rating]
		b.custom_minimum_size = Vector2(150, 0)
		b.toggle_mode = true
		b.button_pressed = (i == _current_unit)
		b.pressed.connect(_on_unit_tab.bind(i))
		_unit_tabs.add_child(b)


func _refresh_slots() -> void:
	_clear_column(_main_col)
	_clear_column(_sub_col)

	var u := _units[_current_unit]
	var main_header := Label.new()
	main_header.text = "Main Slots"
	main_header.tooltip_text = "Dominant hand: any trigger"
	main_header.mouse_filter = Control.MOUSE_FILTER_PASS
	main_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_header.add_theme_font_size_override("font_size", 16)
	_main_col.add_child(main_header)
	var sub_header := Label.new()
	sub_header.text = "Sub Slots"
	sub_header.tooltip_text = "Off hand: only triggers marked (sub)"
	sub_header.mouse_filter = Control.MOUSE_FILTER_PASS
	sub_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_header.add_theme_font_size_override("font_size", 16)
	_sub_col.add_child(sub_header)

	for i in UnitData.MAX_MAIN_SLOTS:
		var s := HangarSlot.new(false, i)
		s.dropped.connect(_on_slot_dropped)
		s.clear_requested.connect(_on_slot_clear)
		s.set_card(u.get_slot(false, i))
		_main_col.add_child(s)

	for i in UnitData.MAX_SUB_SLOTS:
		var s := HangarSlot.new(true, i)
		s.dropped.connect(_on_slot_dropped)
		s.clear_requested.connect(_on_slot_clear)
		s.set_card(u.get_slot(true, i))
		_sub_col.add_child(s)


func _refresh_palette() -> void:
	for c in _palette.get_children():
		c.queue_free()
	for card in TriggerLibrary.all_cards():
		_palette.add_child(LoadoutCard.new(card))


func _refresh_budget() -> void:
	var u := _units[_current_unit]
	var total := u.get_total_trion_cost()
	var cap := u.max_trion_capacity
	_budget_label.text = "Trion %d / %d" % [total, cap]
	_budget_bar.max_value = cap
	_budget_bar.value = total
	_budget_bar.modulate = Color(1, 0.4, 0.4) if total > cap else Color.WHITE


func _clear_column(col: VBoxContainer) -> void:
	for c in col.get_children():
		c.queue_free()


# --- Interaction ------------------------------------------------------------

func _on_unit_tab(i: int) -> void:
	if i == _current_unit:
		return
	_current_unit = i
	_refresh_all()


func _on_slot_dropped(slot: HangarSlot, data: Dictionary) -> void:
	var card: TriggerCard = data["card"]
	var is_move: bool = data.get("from_slot", false)
	var u := _units[_current_unit]

	if is_move:
		var src_sub: bool = data["slot_is_sub"]
		var src_idx: int = data["index"]
		if src_sub == slot.slot_is_sub and src_idx == slot.index:
			return
		u.clear_slot(src_sub, src_idx)

	if u.can_assign_slot(card, slot.slot_is_sub, slot.index):
		u.set_slot(card, slot.slot_is_sub, slot.index)
	elif is_move:
		u.set_slot(card, data["slot_is_sub"], data["index"])  # restore source

	_refresh_slots()
	_refresh_budget()
	_refresh_talents()   # the Melee Penchant can change the AT pool
	SquadStore.save()


func _on_slot_clear(slot: HangarSlot) -> void:
	_units[_current_unit].clear_slot(slot.slot_is_sub, slot.index)
	_refresh_slots()
	_refresh_budget()
	_refresh_talents()
	SquadStore.save()


# --- Talents ------------------------------------------------------------------

var _talent_left: Label
var _talent_rows := {}   # stat -> {minus, plus, pips, value}
var _talent_note: Label


func _build_talent_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Label.new()
	title.text = "Talent Points"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_talent_left = Label.new()
	_talent_left.add_theme_font_size_override("font_size", 18)
	_talent_left.tooltip_text = "Shared by the whole squad"
	_talent_left.mouse_filter = Control.MOUSE_FILTER_PASS
	head.add_child(_talent_left)

	for stat in Talents.STATS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.tooltip_text = Talents.HINTS[stat]
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		box.add_child(row)

		var stat_label := Label.new()
		stat_label.text = Talents.LABELS[stat]
		stat_label.custom_minimum_size = Vector2(76, 0)
		row.add_child(stat_label)

		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size = Vector2(44, 44)
		minus.tooltip_text = "Take a point back"
		minus.pressed.connect(_on_talent.bind(stat, -1))
		row.add_child(minus)

		var pips := Label.new()
		pips.custom_minimum_size = Vector2(76, 0)
		pips.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pips.add_theme_color_override("font_color", UiTheme.ACCENT)
		row.add_child(pips)

		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(44, 44)
		plus.tooltip_text = Talents.HINTS[stat]
		plus.pressed.connect(_on_talent.bind(stat, 1))
		row.add_child(plus)

		var value := Label.new()
		value.custom_minimum_size = Vector2(80, 0)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value)
		_talent_rows[stat] = { "minus": minus, "plus": plus, "pips": pips, "value": value }

	_talent_note = Label.new()
	_talent_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_talent_note.custom_minimum_size = Vector2(356, 0)
	_talent_note.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	_talent_note.add_theme_font_size_override("font_size", 14)
	box.add_child(_talent_note)


func _refresh_talents() -> void:
	if _talent_left == null or _units.is_empty():
		return
	var u := _units[_current_unit]
	var left := Talents.remaining(_units)
	_talent_left.text = "%d / %d left" % [left, Talents.POINTS]
	_talent_left.add_theme_color_override("font_color", UiTheme.ACCENT if left > 0 else UiTheme.TEXT_DIM)
	var pool := TurnPlan.new([u]).get_at_pool(0)
	for stat in Talents.STATS:
		var row: Dictionary = _talent_rows[stat]
		var pts := Talents.get_points(u, stat)
		(row["pips"] as Label).text = "●".repeat(pts) + "○".repeat(Talents.MAX_PER_STAT - pts)
		(row["minus"] as Button).disabled = pts <= 0
		(row["plus"] as Button).disabled = not Talents.can_add(_units, u, stat)
		match stat:
			"stamina":
				(row["value"] as Label).text = "%d AT" % pool
			"hp":
				(row["value"] as Label).text = "%d HP" % u.base_trion_hp
			"atk":
				(row["value"] as Label).text = "%d ATK" % u.attack_rating
	if left > 0:
		_talent_note.text = "%d point%s unspent. Points are shared by all three characters." % [left, "" if left == 1 else "s"]
	else:
		_talent_note.text = "All points spent. Take one back with − to move it."


func _on_talent(stat: String, delta: int) -> void:
	var u := _units[_current_unit]
	if delta > 0 and not Talents.can_add(_units, u, stat):
		return
	Talents.set_points(u, stat, Talents.get_points(u, stat) + delta)
	_refresh_talents()
	_refresh_unit_tabs()
	SquadStore.save()


func _on_reset_pressed() -> void:
	SquadStore.reset_to_defaults()
	_load_squad()


func _on_start_pressed() -> void:
	MatchSession.mode = MatchSession.Mode.LOCAL
	MatchSession.live = false
	_start_match_scene()


## Connects (or reconnects) the GameConnection to the Server URL field.
## Returns false and shows why when the server can't be used.
func _connect_server() -> bool:
	var url := _server_input.text.strip_edges().rstrip("/") if ServerConfig.allow_custom_server() \
		else ServerConfig.default_url()
	if url == "":
		_net_status.text = "Online play is not configured in this build."
		return false
	MatchSession.server_url = url
	if _conn.server_url != url or not _conn.is_online():
		_net_status.text = "Connecting to %s…" % url
		await _conn.connect_to(url)
	if not _conn.is_online():
		_net_status.text = _conn.last_error if _conn.status == GameConnection.Status.OUTDATED \
			else "Server unavailable: %s" % _conn.last_error
		return false
	return true


func _prepare_online_squad() -> void:
	MatchSession.mode = MatchSession.Mode.ONLINE
	MatchSession.squad = SquadStore.get_squad().duplicate()
	for u in MatchSession.squad:
		u.ensure_slot_arrays()


func _on_host_online() -> void:
	if not await _connect_server():
		return
	_prepare_online_squad()
	# Friendly battles: the host picks the live clock or async turns.
	var mode := "live" if _host_live.button_pressed else "async"
	var res := await _conn.backend.create_match(PlanCodec.encode_squad(MatchSession.squad), mode)
	if not res.get("success", false):
		_net_status.text = "Host failed: %s" % str(res.get("error", "?"))
		return
	MatchSession.live = mode == "live"
	MatchSession.live_url = _conn.live_url
	MatchSession.match_id = str(res["body"].get("match_id", ""))
	MatchSession.team = 0
	MatchSession.token = str(res["body"].get("token", ""))
	_net_status.text = "Match created: %s" % MatchSession.match_id
	_start_match_scene()


func _on_join_online() -> void:
	var id := _join_input.text.strip_edges()
	if id == "":
		_net_status.text = "Enter a match ID to join."
		return
	if not await _connect_server():
		return
	_prepare_online_squad()
	var res := await _conn.backend.join_match(id, PlanCodec.encode_squad(MatchSession.squad))
	if not res.get("success", false):
		_net_status.text = "Join failed: %s" % str(res.get("error", "?"))
		return
	MatchSession.match_id = id
	MatchSession.team = 1
	MatchSession.token = str(res["body"].get("token", ""))
	# The host decides whether a friendly battle runs on the live clock.
	MatchSession.live = str(res["body"].get("mode", "async")) == "live"
	MatchSession.live_url = _conn.live_url
	_net_status.text = "Joined match %s" % id
	_start_match_scene()


## Ranked matchmaking in `mode` ("live" ladder or "async"): connects,
## ensures an account, and waits for an opponent. Pressing the button again
## cancels the search.
func _on_find_ranked(mode: String) -> void:
	if _searching:
		if mode == _search_mode:
			_searching = false
		return
	_search_mode = mode
	if not await _connect_server():
		return
	var account := await _conn.ensure_account(_name_input.text.strip_edges())
	if account.is_empty():
		_net_status.text = _conn.last_error
		return
	_prepare_online_squad()
	_delete_btn.visible = true

	var button := _live_btn if mode == "live" else _ranked_btn
	var idle_text := button.text
	_searching = true
	button.text = "Cancel Search"
	_net_status.text = "Searching for an opponent…  (%s · %d trophies · %s)" % [
		account.get("name", ""), int(account.get("trophies", 0)), str(account.get("arena", ""))]
	var ticket := await _conn.find_match(PlanCodec.encode_squad(MatchSession.squad), mode,
		func() -> bool: return _searching)
	_searching = false
	button.text = idle_text
	if ticket.is_empty():
		_net_status.text = _conn.last_error
		return
	MatchSession.live = mode == "live"
	MatchSession.live_url = str(ticket.get("live_url", ""))
	MatchSession.match_id = str(ticket["match_id"])
	MatchSession.team = int(ticket["team"])
	MatchSession.token = str(ticket["token"])
	_net_status.text = "Opponent found — ranked match %s" % MatchSession.match_id
	_start_match_scene()


func _start_match_scene() -> void:
	for u in _units:
		u.ensure_slot_arrays()
	UiTheme.change_scene(get_tree(), "res://levels/board/main.tscn")


## Re-enters a ranked match that is still running on the server (the app was
## closed or crashed mid-match). Live matches first: their clock is running.
func _on_resume_pressed() -> void:
	if _searching or not await _connect_server():
		return
	var matches := await _conn.resumable_matches()
	if matches.is_empty():
		_net_status.text = "No match in progress."
		return
	var pick: Dictionary = matches[0]
	for m in matches:
		if str(m.get("mode", "")) == "live":
			pick = m
			break
	_prepare_online_squad()
	MatchSession.live = str(pick.get("mode", "async")) == "live"
	MatchSession.live_url = str(pick.get("live_url", _conn.live_url))
	MatchSession.match_id = str(pick.get("match_id", ""))
	MatchSession.team = int(pick.get("team", 0))
	MatchSession.token = str(pick.get("token", ""))
	_net_status.text = "Rejoining match %s" % MatchSession.match_id
	_start_match_scene()


func _on_delete_account_pressed() -> void:
	var now := Time.get_ticks_msec()
	if _delete_armed_at < 0 or now - _delete_armed_at > DELETE_CONFIRM_MS:
		_delete_armed_at = now
		_delete_btn.text = "Tap again to delete"
		_net_status.text = "This permanently deletes your account, trophies, and rating."
		await get_tree().create_timer(DELETE_CONFIRM_MS / 1000.0).timeout
		if is_inside_tree() and _delete_armed_at == now:
			_delete_armed_at = -1
			_delete_btn.text = "Delete Account"
		return
	_delete_armed_at = -1
	_delete_btn.text = "Delete Account"
	if not await _connect_server():
		return
	_conn.account = AccountStore.load_for(_conn.server_url)
	if _conn.account.is_empty():
		_net_status.text = "No account on this server."
		_delete_btn.visible = false
		return
	if await _conn.delete_account():
		_net_status.text = "Account deleted."
		_delete_btn.visible = false
		_name_input.text = ""
	else:
		_net_status.text = "Could not delete the account: %s" % _conn.last_error
