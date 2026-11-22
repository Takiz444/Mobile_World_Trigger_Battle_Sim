class_name HangarUI
extends Control
## The main menu: build your squad (GDD section 6: each unit's 8-slot
## Trigger Holder, 4 Main + 4 Sub, against a Trion budget, plus talents),
## then pick how to play:
##   PRACTICE VS AI   offline, against the built-in AI,
##   RANKED ONLINE    matchmaking against players of your skill (live or slow),
##   PLAY A FRIEND    an unranked room shared by code.
## A banner offers to rejoin an online match that is still running.

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
var _resume_banner: PanelContainer
var _resume_label: Label
var _ranked_info: Label
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
	_check_resumable()


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
	vbox.offset_left = 40
	vbox.offset_right = -40
	vbox.offset_top = 8
	vbox.offset_bottom = -8
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	# --- 1. Your squad (editing) -------------------------------------------------
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	vbox.add_child(title_row)
	var title_pad := Control.new()
	title_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_pad)
	var title := Label.new()
	title.text = "YOUR SQUAD"
	title.add_theme_font_size_override("font_size", 24)
	title_row.add_child(title)
	var title_right := HBoxContainer.new()
	title_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_right.alignment = BoxContainer.ALIGNMENT_END
	title_row.add_child(title_right)
	var reset := Button.new()
	reset.text = "Reset Squad"
	reset.tooltip_text = "Put every character back to the default loadout and talents"
	reset.pressed.connect(_on_reset_pressed)
	title_right.add_child(reset)

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
	palette_label.text = "Available Triggers  ·  drag into a slot  ·  right-click or double-tap a slot to clear"
	palette_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	palette_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	palette_label.add_theme_font_size_override("font_size", 14)
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

	# --- 2. A running match to get back into (shown only when there is one) ---
	_resume_banner = PanelContainer.new()
	_resume_banner.add_theme_stylebox_override("panel",
		UiTheme.panel_style(Color(0.1, 0.2, 0.14, 0.95), UiTheme.GOOD, 8))
	_resume_banner.visible = false
	vbox.add_child(_resume_banner)
	var resume_row := HBoxContainer.new()
	resume_row.alignment = BoxContainer.ALIGNMENT_CENTER
	resume_row.add_theme_constant_override("separation", 16)
	_resume_banner.add_child(resume_row)
	_resume_label = Label.new()
	_resume_label.text = "You have a match in progress."
	resume_row.add_child(_resume_label)
	_resume_btn = Button.new()
	_resume_btn.text = "Rejoin Match"
	_resume_btn.tooltip_text = "Get back into your online match that is still running"
	_resume_btn.pressed.connect(_on_resume_pressed)
	_style_primary(_resume_btn, UiTheme.GOOD)
	resume_row.add_child(_resume_btn)

	# --- 3. How to play: three clear choices --------------------------------------
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 12)
	vbox.add_child(cards)

	# Practice vs the computer.
	var practice := _play_card(cards, "PRACTICE VS AI", "Offline. Try your squad against the computer.")
	_start_button = Button.new()
	_start_button.text = "Play vs AI"
	_start_button.tooltip_text = "Start a match against the built-in AI (no account needed)"
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.pressed.connect(_on_start_pressed)
	_style_primary(_start_button)
	practice.add_child(_start_button)

	# Ranked matchmaking against other players.
	var ranked := _play_card(cards, "RANKED ONLINE", "Get matched with a player of your skill.")
	ranked.get_parent().size_flags_stretch_ratio = 1.5
	var ranked_row := HBoxContainer.new()
	ranked_row.add_theme_constant_override("separation", 8)
	ranked.add_child(ranked_row)
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Your name"
	_name_input.tooltip_text = "The name other players see"
	_name_input.max_length = NameRules.PLAYER_NAME_MAX
	_name_input.custom_minimum_size = Vector2(150, 0)
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var saved := AccountStore.load_for(MatchSession.server_url)
	_name_input.text = str(saved.get("name", ""))
	_name_input.text_changed.connect(func(t: String) -> void:
		if AccountStore.load_for(MatchSession.server_url).is_empty():
			_refresh_ranked_info({ "name": t.strip_edges() }))
	ranked_row.add_child(_name_input)
	# Live Battle is the trophy ladder (short turn clock, both players
	# online); the async queue plays over hours (long turn timer).
	_live_btn = Button.new()
	_live_btn.text = "Find Match"
	_live_btn.tooltip_text = "Live ranked battle: both players online, %d-second turns, trophies on the line" % Ladder.LIVE_TURN_SEC
	_live_btn.custom_minimum_size = Vector2(170, 0)
	_live_btn.pressed.connect(_on_find_ranked.bind("live"))
	_style_primary(_live_btn)
	ranked_row.add_child(_live_btn)
	var ranked_row2 := HBoxContainer.new()
	ranked_row2.add_theme_constant_override("separation", 8)
	ranked.add_child(ranked_row2)
	_ranked_info = Label.new()
	_ranked_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ranked_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ranked_info.add_theme_font_size_override("font_size", 14)
	_ranked_info.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	ranked_row2.add_child(_ranked_info)
	_ranked_btn = Button.new()
	_ranked_btn.text = "Slow Match"
	_ranked_btn.tooltip_text = "Ranked match played over hours: submit a turn whenever you like"
	_ranked_btn.pressed.connect(_on_find_ranked.bind("async"))
	ranked_row2.add_child(_ranked_btn)

	# A private match with a friend, by room code.
	var friend := _play_card(cards, "PLAY A FRIEND", "Unranked. Share a room code.")
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 8)
	friend.add_child(host_row)
	_host_btn = Button.new()
	_host_btn.text = "Create Room"
	_host_btn.tooltip_text = "Start a room and get a code to send your friend"
	_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_btn.pressed.connect(_on_host_online)
	host_row.add_child(_host_btn)
	_host_live = CheckBox.new()
	_host_live.text = "Fast turns"
	_host_live.tooltip_text = "Play on the live turn clock (both online). Off: take your time, turns can wait for hours."
	host_row.add_child(_host_live)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	friend.add_child(join_row)
	_join_input = LineEdit.new()
	_join_input.placeholder_text = "Room code"
	_join_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_input.text_submitted.connect(func(_t: String) -> void: _on_join_online())
	join_row.add_child(_join_input)
	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.pressed.connect(_on_join_online)
	join_row.add_child(_join_btn)

	# --- 4. Footer: messages, account, dev server -------------------------------
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	vbox.add_child(footer)
	_server_input = LineEdit.new()
	_server_input.text = MatchSession.server_url
	_server_input.placeholder_text = "Server URL (dev)"
	_server_input.tooltip_text = "Development builds only: which server to play on"
	_server_input.custom_minimum_size = Vector2(230, 0)
	# Store builds always talk to the production server (ServerConfig).
	_server_input.visible = ServerConfig.allow_custom_server()
	footer.add_child(_server_input)
	_net_status = Label.new()
	_net_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_net_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_net_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_net_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_status.add_theme_color_override("font_color", Color(1.0, 0.75, 0.55))
	footer.add_child(_net_status)
	# Account deletion must be available in-app (App Store 5.1.1(v), Google
	# Play data-deletion policy). Two taps: the first only arms it.
	_delete_btn = Button.new()
	_delete_btn.text = "Delete Account"
	_delete_btn.flat = true
	_delete_btn.add_theme_color_override("font_color", UiTheme.DANGER)
	_delete_btn.add_theme_font_size_override("font_size", 14)
	_delete_btn.visible = not saved.is_empty()
	_delete_btn.pressed.connect(_on_delete_account_pressed)
	footer.add_child(_delete_btn)

	for b in find_children("*", "BaseButton", true, false):
		UiTheme.add_press_feedback(b)
	_refresh_ranked_info(saved)


## A titled card in the play row; returns the box to put its controls in.
func _play_card(parent: HBoxContainer, heading: String, blurb: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	var head := Label.new()
	head.text = heading
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color", UiTheme.ACCENT)
	box.add_child(head)
	var sub := Label.new()
	sub.text = blurb
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	box.add_child(sub)
	return box


## The main call to action: a filled accent button.
func _style_primary(b: Button, color: Color = UiTheme.ACCENT) -> void:
	var dark := Color(0.03, 0.06, 0.1)
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = color.lightened(0.12) if state == "hover" else (color.darkened(0.15) if state == "pressed" else color)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 16
		sb.content_margin_right = 16
		sb.content_margin_top = 10
		sb.content_margin_bottom = 10
		if state == "focus":
			sb.draw_center = false
			sb.border_color = Color.WHITE
			sb.set_border_width_all(2)
		b.add_theme_stylebox_override(state, sb)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, dark)
	b.add_theme_font_size_override("font_size", 17)


## Who you'll play as on this server, under the Find Match button.
func _refresh_ranked_info(account: Dictionary) -> void:
	if _searching:
		return
	if account.is_empty() or str(account.get("name", "")) == "":
		_ranked_info.text = "Pick a name (or play as a guest), then find a match."
	elif account.has("trophies"):
		_ranked_info.text = "%s  ·  %d trophies  ·  %s" % [account["name"], int(account["trophies"]),
			str(account.get("arena", Ladder.arena_name(int(account.get("best_trophies", account["trophies"])))))]
	else:
		_ranked_info.text = "Playing as %s" % account["name"]


## While a search runs, other ways to start a match are locked.
func _set_play_locked(locked: bool, searching_button: Button) -> void:
	for b in [_start_button, _host_btn, _join_btn, _live_btn, _ranked_btn, _resume_btn]:
		if b != searching_button:
			(b as Button).disabled = locked
	_name_input.editable = not locked
	_join_input.editable = not locked


## Shows the "match in progress" banner when this account has one running
## (checked quietly in the background when the screen opens).
func _check_resumable() -> void:
	var url := ServerConfig.default_url() if not ServerConfig.allow_custom_server() else MatchSession.server_url
	if url == "" or AccountStore.load_for(url).is_empty():
		return
	if _conn.server_url != url or not _conn.is_online():
		await _conn.connect_to(url)
	if not is_inside_tree() or not _conn.is_online():
		return
	var matches := await _conn.resumable_matches()
	if not is_inside_tree() or matches.is_empty():
		return
	var live := matches.any(func(m: Dictionary) -> bool: return str(m.get("mode", "")) == "live")
	_resume_label.text = "Your live match is still running — get back in before the clock runs out!" if live \
		else "You have %d ranked match%s in progress." % [matches.size(), "" if matches.size() == 1 else "es"]
	_resume_banner.visible = true


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
		b.tooltip_text = "HP %d · Speed %d%% · ATK %d" % [u.base_trion_hp, roundi(u.tempo * 100.0), u.attack_rating]
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
	_refresh_talents()   # the Melee Penchant changes walking speed
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

		# Drawn as shapes, not "●○" text: the web build has no system fonts
		# to fall back on, and the default font lacks those glyphs.
		var pips := HBoxContainer.new()
		pips.custom_minimum_size = Vector2(76, 0)
		pips.alignment = BoxContainer.ALIGNMENT_CENTER
		pips.add_theme_constant_override("separation", 4)
		for i in Talents.MAX_PER_STAT:
			var pip := Panel.new()
			pip.custom_minimum_size = Vector2(11, 11)
			pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pips.add_child(pip)
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


## A round talent pip: solid when the point is spent, an outline when not.
func _pip_style(filled: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.set_corner_radius_all(6)
	s.bg_color = UiTheme.ACCENT if filled else Color(0, 0, 0, 0)
	s.border_color = UiTheme.ACCENT
	s.set_border_width_all(0 if filled else 2)
	s.anti_aliasing = true
	return s


func _refresh_talents() -> void:
	if _talent_left == null or _units.is_empty():
		return
	var u := _units[_current_unit]
	var left := Talents.remaining(_units)
	_talent_left.text = "%d / %d left" % [left, Talents.POINTS]
	_talent_left.add_theme_color_override("font_color", UiTheme.ACCENT if left > 0 else UiTheme.TEXT_DIM)
	for stat in Talents.STATS:
		var row: Dictionary = _talent_rows[stat]
		var pts := Talents.get_points(u, stat)
		var pips := (row["pips"] as HBoxContainer).get_children()
		for i in pips.size():
			(pips[i] as Panel).add_theme_stylebox_override("panel", _pip_style(i < pts))
		(row["minus"] as Button).disabled = pts <= 0
		(row["plus"] as Button).disabled = not Talents.can_add(_units, u, stat)
		match stat:
			"stamina":
				(row["value"] as Label).text = "%d%% speed" % roundi(u.tempo * 100.0)
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
		_net_status.text = "Couldn't create a room: %s" % str(res.get("error", "?"))
		return
	MatchSession.live = mode == "live"
	MatchSession.live_url = _conn.live_url
	MatchSession.match_id = str(res["body"].get("match_id", ""))
	MatchSession.team = 0
	MatchSession.token = str(res["body"].get("token", ""))
	_net_status.text = "Room %s created: send this code to your friend." % MatchSession.match_id
	_start_match_scene()


func _on_join_online() -> void:
	var id := _join_input.text.strip_edges()
	if id == "":
		_net_status.text = "Enter the room code your friend sent you."
		_join_input.grab_focus()
		return
	if not await _connect_server():
		return
	_prepare_online_squad()
	var res := await _conn.backend.join_match(id, PlanCodec.encode_squad(MatchSession.squad))
	if not res.get("success", false):
		_net_status.text = "Couldn't join room %s: %s" % [id, str(res.get("error", "?"))]
		return
	MatchSession.match_id = id
	MatchSession.team = 1
	MatchSession.token = str(res["body"].get("token", ""))
	# The host decides whether a friendly battle runs on the live clock.
	MatchSession.live = str(res["body"].get("mode", "async")) == "live"
	MatchSession.live_url = _conn.live_url
	_net_status.text = "Joined room %s" % id
	_start_match_scene()


## Ranked matchmaking in `mode` ("live" or "async"): connects, ensures an
## account, and waits for an opponent. Pressing the button again cancels.
func _on_find_ranked(mode: String) -> void:
	if _searching:
		if mode == _search_mode:
			_searching = false
		return
	# No name yet: play as a guest name (it can be any name next time).
	if _name_input.text.strip_edges() == "" and AccountStore.load_for(MatchSession.server_url).is_empty():
		_name_input.text = "Player%04d" % (randi() % 10000)
	_search_mode = mode
	var button := _live_btn if mode == "live" else _ranked_btn
	var idle_text := button.text
	_searching = true
	_set_play_locked(true, button)
	button.text = "Cancel"
	_ranked_info.text = "Connecting…"
	_net_status.text = ""
	var ticket := await _search(mode)
	_searching = false
	if not is_inside_tree():
		return
	button.text = idle_text
	_set_play_locked(false, null)
	_refresh_ranked_info(_conn.account)
	if ticket.is_empty():
		_net_status.text = _conn.last_error
		return
	MatchSession.live = str(ticket.get("mode", mode)) == "live"
	MatchSession.live_url = str(ticket.get("live_url", ""))
	MatchSession.match_id = str(ticket["match_id"])
	MatchSession.team = int(ticket["team"])
	MatchSession.token = str(ticket["token"])
	_ranked_info.text = "Opponent found!  Starting the battle…"
	_start_match_scene()


## Connects, makes sure there's an account, and runs the search. The
## matched ticket, or {} (_conn.last_error says why).
func _search(mode: String) -> Dictionary:
	if not await _connect_server():
		_conn.last_error = _net_status.text
		return {}
	var account := await _conn.ensure_account(_name_input.text.strip_edges())
	if account.is_empty() or not _searching:
		return {}
	_prepare_online_squad()
	_delete_btn.visible = true
	_name_input.text = str(account.get("name", _name_input.text))
	return await _conn.find_match(PlanCodec.encode_squad(MatchSession.squad), mode,
		func() -> bool: return _searching,
		func(t: Dictionary) -> void:
			if is_inside_tree() and _searching:
				_ranked_info.text = search_status_text(t))


## The status line for a matchmaking ticket view (GameConnection.find_match).
static func search_status_text(t: Dictionary) -> String:
	match str(t.get("status", "")):
		"found":
			return "Opponent found!  Getting ready…"
		"matched":
			return "Opponent found!  Starting the battle…"
		"expired":
			return "Reconnecting to the queue…"
	var text := "Searching…  %s" % _clock(float(t.get("wait_sec", 0.0)))
	var others := int(t.get("searching", 1)) - 1
	if others > 0:
		text += "  ·  %d other%s searching" % [others, "" if others == 1 else "s"]
	else:
		text += "  ·  waiting for another player"
	var usual := float(t.get("estimated_wait", -1.0))
	if usual >= 0.0:
		text += "  ·  usual wait %s" % _clock(usual)
	return text


static func _clock(sec: float) -> String:
	var s := maxi(0, int(sec))
	return "%d:%02d" % [s / 60, s % 60]


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
		_resume_banner.visible = false
		_refresh_ranked_info({})
	else:
		_net_status.text = "Could not delete the account: %s" % _conn.last_error
