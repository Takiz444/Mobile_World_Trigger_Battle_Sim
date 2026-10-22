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
var _search_mode := ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
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
	bg.color = Color(0.05, 0.07, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 48
	vbox.offset_right = -48
	vbox.offset_top = 24
	vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 12)
	add_child(vbox)

	var title := Label.new()
	title.text = "HANGAR — Trigger Holder"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(title)

	_unit_tabs = HBoxContainer.new()
	_unit_tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	_unit_tabs.add_theme_constant_override("separation", 8)
	vbox.add_child(_unit_tabs)

	var budget_row := HBoxContainer.new()
	budget_row.alignment = BoxContainer.ALIGNMENT_CENTER
	budget_row.add_theme_constant_override("separation", 12)
	vbox.add_child(budget_row)

	_budget_label = Label.new()
	_budget_label.add_theme_font_size_override("font_size", 18)
	budget_row.add_child(_budget_label)

	_budget_bar = ProgressBar.new()
	_budget_bar.custom_minimum_size = Vector2(320, 22)
	_budget_bar.show_percentage = false
	budget_row.add_child(_budget_bar)

	var columns := HBoxContainer.new()
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_theme_constant_override("separation", 48)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(columns)

	_main_col = _build_column("Main Slots (Dominant Hand)", columns)
	_sub_col = _build_column("Sub Slots (Off Hand)", columns)

	var palette_label := Label.new()
	palette_label.text = "Available Triggers (drag into slots · right-click or double-tap a slot to clear)"
	palette_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(palette_label)

	var palette_scroll := ScrollContainer.new()
	palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	palette_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	palette_scroll.custom_minimum_size = Vector2(0, 64)
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
	mp_label.text = "— Async Multiplayer —"
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
	mp_row.add_child(_server_input)

	_host_btn = Button.new()
	_host_btn.text = "Host Online Match"
	_host_btn.pressed.connect(_on_host_online)
	mp_row.add_child(_host_btn)

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


func _refresh_slots() -> void:
	_clear_column(_main_col)
	_clear_column(_sub_col)

	var u := _units[_current_unit]
	var main_header := Label.new()
	main_header.text = "Main Slots (Dominant Hand)"
	main_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_header.add_theme_font_size_override("font_size", 18)
	_main_col.add_child(main_header)
	var sub_header := Label.new()
	sub_header.text = "Sub Slots (Off Hand)"
	sub_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_header.add_theme_font_size_override("font_size", 18)
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


func _on_slot_clear(slot: HangarSlot) -> void:
	_units[_current_unit].clear_slot(slot.slot_is_sub, slot.index)
	_refresh_slots()
	_refresh_budget()


func _on_reset_pressed() -> void:
	SquadStore.reset_to_defaults()
	_load_squad()


func _on_start_pressed() -> void:
	MatchSession.mode = MatchSession.Mode.LOCAL
	MatchSession.live = false
	_start_match_scene()


func _on_host_online() -> void:
	_net_status.text = ""
	MatchSession.mode = MatchSession.Mode.ONLINE
	MatchSession.live = false
	MatchSession.live_url = ""
	MatchSession.server_url = _server_input.text.strip_edges()
	MatchSession.squad = SquadStore.get_squad().duplicate()
	MatchSession.seed = 12345

	var backend := HttpBackend.new()
	add_child(backend)
	backend.server_url = MatchSession.server_url
	var res := await backend.create_match(MatchSession.seed, PlanCodec.encode_squad(MatchSession.squad))
	backend.queue_free()

	if not res.get("success", false):
		_net_status.text = "Host failed: %s" % str(res.get("error", "?"))
		return
	MatchSession.match_id = str(res["body"].get("match_id", ""))
	MatchSession.team = 0
	MatchSession.token = str(res["body"].get("token", ""))
	_net_status.text = "Match created: %s" % MatchSession.match_id
	_start_match_scene()


func _on_join_online() -> void:
	_net_status.text = ""
	var id := _join_input.text.strip_edges()
	if id == "":
		_net_status.text = "Enter a match ID to join."
		return

	MatchSession.mode = MatchSession.Mode.ONLINE
	MatchSession.server_url = _server_input.text.strip_edges()
	MatchSession.squad = SquadStore.get_squad().duplicate()

	var backend := HttpBackend.new()
	add_child(backend)
	backend.server_url = MatchSession.server_url
	var res := await backend.join_match(id, PlanCodec.encode_squad(MatchSession.squad))
	backend.queue_free()

	if not res.get("success", false):
		_net_status.text = "Join failed: %s" % str(res.get("error", "?"))
		return
	MatchSession.match_id = id
	MatchSession.team = 1
	MatchSession.token = str(res["body"].get("token", ""))
	# The host decides whether a friendly battle runs on the live clock.
	MatchSession.live = str(res["body"].get("mode", "async")) == "live"
	MatchSession.live_url = ""
	_net_status.text = "Joined match %s" % id
	_start_match_scene()


## Ranked matchmaking: registers (once per server), joins the `mode` queue
## ("live" ladder or "async"), and polls until paired. Pressing the button
## again cancels the search.
func _on_find_ranked(mode: String) -> void:
	if _searching:
		if mode == _search_mode:
			_searching = false
		return
	_search_mode = mode
	_net_status.text = ""
	var server := _server_input.text.strip_edges()
	MatchSession.server_url = server
	MatchSession.squad = SquadStore.get_squad().duplicate()
	for u in MatchSession.squad:
		u.ensure_slot_arrays()

	var backend := HttpBackend.new()
	add_child(backend)
	backend.server_url = server
	var account := await _ensure_account(backend, server)
	if account.is_empty():
		backend.queue_free()
		return

	var squad := PlanCodec.encode_squad(MatchSession.squad)
	var res := await backend.queue_ranked(account["player_id"], account["secret"], squad, mode)
	if int(res.get("status", 0)) == 403:
		# The server no longer knows this account (e.g. a fresh server): re-register.
		AccountStore.clear_for(server)
		account = await _ensure_account(backend, server)
		if account.is_empty():
			backend.queue_free()
			return
		res = await backend.queue_ranked(account["player_id"], account["secret"], squad, mode)
	if not res.get("success", false):
		_net_status.text = "Matchmaking failed: %s" % str(res.get("error", "?"))
		backend.queue_free()
		return

	var profile := await backend.get_account(account["player_id"])
	var trophies := int(profile.get("body", {}).get("trophies", 0))
	var arena := str(profile.get("body", {}).get("arena", ""))
	var button := _live_btn if mode == "live" else _ranked_btn
	var idle_text := button.text
	_searching = true
	button.text = "Cancel Search"
	var ticket: Dictionary = res["body"]
	while _searching and str(ticket.get("status", "")) == "queued":
		_net_status.text = "Searching for an opponent…  (%s · %d trophies · %s)" % [account["name"], trophies, arena]
		await get_tree().create_timer(1.0).timeout
		var poll := await backend.poll_queue(str(ticket["ticket"]), account["secret"])
		if poll.get("success", false):
			ticket = poll["body"]
	button.text = idle_text
	if str(ticket.get("status", "")) != "matched":
		_searching = false
		await backend.cancel_queue(str(ticket.get("ticket", "")), account["secret"])
		_net_status.text = "Search cancelled."
		backend.queue_free()
		return
	_searching = false
	backend.queue_free()
	MatchSession.mode = MatchSession.Mode.ONLINE
	MatchSession.live = mode == "live"
	MatchSession.live_url = str(ticket.get("live_url", ""))
	MatchSession.match_id = str(ticket["match_id"])
	MatchSession.team = int(ticket["team"])
	MatchSession.token = str(ticket["token"])
	_net_status.text = "Opponent found — ranked match %s" % MatchSession.match_id
	_start_match_scene()


## Saved account for `server`, or a newly registered one. {} on failure.
func _ensure_account(backend: HttpBackend, server: String) -> Dictionary:
	var account := AccountStore.load_for(server)
	if not account.is_empty():
		return account
	var player_name := _name_input.text.strip_edges()
	if player_name == "":
		player_name = "Player"
	var res := await backend.register_account(player_name)
	if not res.get("success", false):
		_net_status.text = "Could not create account: %s" % str(res.get("error", "?"))
		return {}
	AccountStore.save_for(server, res["body"])
	return AccountStore.load_for(server)


func _start_match_scene() -> void:
	for u in _units:
		u.ensure_slot_arrays()
	get_tree().change_scene_to_file("res://levels/board/main.tscn")
