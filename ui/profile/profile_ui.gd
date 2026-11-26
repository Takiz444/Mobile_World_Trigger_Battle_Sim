class_name ProfileUI
extends Control
## The player's profile (POST /account/profile): current and best rank, ladder
## position, win rate, streaks, favorite move, skill rating, and recent
## matches. Signed-in players can sign out here; guests are offered an
## account (their progress moves to it).

const HANGAR := "res://ui/hangar/hangar.tscn"
const WELCOME := "res://ui/welcome/welcome.tscn"
const WIN := Color(0.45, 0.95, 0.6)
const LOSS := Color(1.0, 0.45, 0.4)
const DRAW := Color(0.75, 0.78, 0.85)

var _conn: GameConnection
var _content: VBoxContainer
var _account_btn: Button
var _signed_in := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UiTheme.install(get_tree())
	_conn = GameConnection.new()
	_conn.name = "GameConnection"
	add_child(_conn)
	_build_frame()
	_load()


func _build_frame() -> void:
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 40
	root.offset_right = -40
	root.offset_top = 12
	root.offset_bottom = -12
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	root.add_child(bar)
	var back := Button.new()
	back.text = "Back"
	back.tooltip_text = "Back to your squad"
	back.custom_minimum_size = Vector2(170, 0)
	back.pressed.connect(func() -> void: UiTheme.change_scene(get_tree(), HANGAR))
	bar.add_child(back)
	var title := UiTheme.label("PROFILE", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	# Same width as Back, so the title stays centered when the button hides.
	var right_slot := HBoxContainer.new()
	right_slot.custom_minimum_size = Vector2(170, 0)
	right_slot.alignment = BoxContainer.ALIGNMENT_END
	bar.add_child(right_slot)
	_account_btn = Button.new()
	_account_btn.custom_minimum_size = Vector2(170, 0)
	_account_btn.visible = false
	_account_btn.pressed.connect(_on_account_pressed)
	right_slot.add_child(_account_btn)

	_content = VBoxContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 12)
	root.add_child(_content)
	for b in find_children("*", "BaseButton", true, false):
		UiTheme.add_press_feedback(b)


func _load() -> void:
	_show_message("Loading your profile…")
	var url := MatchSession.server_url if ServerConfig.allow_custom_server() else ServerConfig.default_url()
	var saved := AccountStore.load_for(url)
	_signed_in = AccountStore.is_signed_in(saved)
	if saved.is_empty():
		_show_no_account()
		return
	await _conn.connect_to(url)
	if not is_inside_tree():
		return
	if not _conn.is_online():
		_show_message("Can't reach the server right now.", true)
		return
	var profile := await _conn.fetch_profile()
	if not is_inside_tree():
		return
	if profile.is_empty():
		_show_message(_conn.last_error, true)
		return
	_show_profile(profile)


# --- States ---------------------------------------------------------------------

func _clear() -> void:
	for c in _content.get_children():
		c.queue_free()


func _show_message(text: String, retry := false) -> void:
	_clear()
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	var l := UiTheme.label(text, 18, UiTheme.TEXT_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(l)
	if retry:
		var b := Button.new()
		b.text = "Try Again"
		b.pressed.connect(_load)
		box.add_child(b)


## A guest who has never played online has no server account yet.
func _show_no_account() -> void:
	_clear()
	_account_btn.visible = false   # the call to action is in the middle
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var head := UiTheme.label("No profile yet", 24)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(head)
	var l := UiTheme.label("Your profile starts with your first online match. Create an account to keep "
		+ "your rank and match history on every device.", 16, UiTheme.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(l)
	var create := Button.new()
	create.text = "Create Account"
	UiTheme.style_primary(create)
	create.pressed.connect(_open_welcome.bind(true))
	box.add_child(create)


func _show_profile(p: Dictionary) -> void:
	_clear()
	_signed_in = not bool(p.get("guest", true))
	_set_account_button()
	var rank: Dictionary = p.get("rank", {})
	var stats: Dictionary = p.get("stats", {})

	_content.add_child(_header(p))

	# Headline numbers.
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 10)
	_content.add_child(tiles)
	var played := int(stats.get("played", 0))
	tiles.add_child(_tile("CURRENT RANK", "%d" % int(rank.get("trophies", 0)), "trophies  ·  %s" % rank.get("arena", "")))
	tiles.add_child(_tile("MAX RANK", "%d" % int(rank.get("best_trophies", 0)), "best  ·  %s" % rank.get("best_arena", "")))
	tiles.add_child(_tile("LADDER", "#%d" % int(rank.get("position", 0)), "of %d players  ·  season %d" % [
		int(rank.get("players", 0)), int(p.get("season", 1))]))
	tiles.add_child(_tile("WIN RATE", "%d%%" % roundi(float(stats.get("win_rate", 0.0)) * 100.0) if played > 0 else "–",
		"%d W  ·  %d L  ·  %d D" % [int(stats.get("wins", 0)), int(stats.get("losses", 0)), int(stats.get("draws", 0))]))
	tiles.add_child(_tile("MATCHES", "%d" % played, "streak %d  ·  best %d" % [
		int(stats.get("streak", 0)), int(stats.get("best_streak", 0))]))
	var fav := str(stats.get("favorite_move", ""))
	var top_moves: Array = stats.get("top_moves", [])
	tiles.add_child(_tile("FAVORITE MOVE", fav if fav != "" else "–",
		"used %d times" % int(top_moves[0].get("count", 0)) if fav != "" and not top_moves.is_empty() else "play a match to find out"))

	# History (left) and moves / rating (right).
	var lower := HBoxContainer.new()
	lower.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lower.add_theme_constant_override("separation", 12)
	_content.add_child(lower)
	lower.add_child(_history_panel(p.get("history", [])))
	lower.add_child(_side_panel(rank, stats, top_moves))


func _set_account_button() -> void:
	_account_btn.visible = true
	if _signed_in:
		_account_btn.text = "Sign Out"
		_account_btn.tooltip_text = "Sign out on this device"
	else:
		_account_btn.text = "Create Account"
		_account_btn.tooltip_text = "Keep your progress on every device"


func _on_account_pressed() -> void:
	if not _signed_in:
		_open_welcome(true)
		return
	_account_btn.disabled = true
	await _conn.sign_out()
	if is_inside_tree():
		UiTheme.change_scene(get_tree(), WELCOME)


func _open_welcome(create: bool) -> void:
	WelcomeUI.start_on_create = create
	UiTheme.change_scene(get_tree(), WELCOME)


# --- Pieces ---------------------------------------------------------------------

func _header(p: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)
	var player_name := str(p.get("name", "Player"))
	# Round avatar with the name's first letter.
	var avatar := PanelContainer.new()
	avatar.custom_minimum_size = Vector2(56, 56)
	var circle := StyleBoxFlat.new()
	circle.bg_color = UiTheme.ACCENT_DIM
	circle.set_corner_radius_all(28)
	circle.anti_aliasing = true
	avatar.add_theme_stylebox_override("panel", circle)
	var initial := UiTheme.label(player_name.left(1).to_upper(), 26, Color.WHITE)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar.add_child(initial)
	row.add_child(avatar)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(names)
	names.add_child(UiTheme.label(player_name, 24))
	var sub := ""
	if bool(p.get("guest", true)):
		sub = "Guest account  ·  progress is saved on this device only"
	else:
		sub = str(p.get("email", ""))
		if p.get("email_verified") is bool and not p["email_verified"]:
			sub += "  (not verified yet: check your inbox)"
	var since := float(p.get("created_at", 0.0))
	if since > 0.0:
		sub += "  ·  playing since %s" % _date(since)
	names.add_child(UiTheme.label(sub, 14, UiTheme.TEXT_DIM))
	return panel


func _tile(caption: String, value: String, detail: String) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(0, 96)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	box.add_child(UiTheme.label(caption, 12, UiTheme.ACCENT))
	var v := UiTheme.label(value, 26)
	v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.clip_text = true
	box.add_child(v)
	var d := UiTheme.label(detail, 12, UiTheme.TEXT_DIM)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(d)
	return panel


func _history_panel(history: Array) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 2.0
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(UiTheme.label("MATCH HISTORY", 15, UiTheme.ACCENT))
	if history.is_empty():
		var empty := UiTheme.label("No matches yet. Ranked matches, and friendly rooms you play while "
			+ "signed in, show up here.", 15, UiTheme.TEXT_DIM)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(empty)
		return panel
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	for e in history:
		if e is Dictionary:
			list.add_child(_history_row(e))
	return panel


func _history_row(e: Dictionary) -> Control:
	var result := str(e.get("result", "draw"))
	var color := WIN if result == "win" else (LOSS if result == "loss" else DRAW)
	var row_panel := PanelContainer.new()
	var rs := UiTheme.panel_style(Color(0.06, 0.085, 0.13, 0.9), Color(color.r, color.g, color.b, 0.35), 8)
	rs.set_content_margin_all(8)
	rs.shadow_size = 0
	row_panel.add_theme_stylebox_override("panel", rs)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row_panel.add_child(row)

	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(64, 0)
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(color.r, color.g, color.b, 0.18)
	bs.set_corner_radius_all(6)
	bs.set_content_margin_all(6)
	badge.add_theme_stylebox_override("panel", bs)
	var bl := UiTheme.label(result.to_upper(), 15, color)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(bl)
	row.add_child(badge)

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 0)
	row.add_child(mid)
	var opponent := str(e.get("opponent", ""))
	mid.add_child(UiTheme.label("vs %s   ·   %s" % [opponent if opponent != "" else "a guest", _mode_name(e)], 16))
	var bits: Array[String] = [_reason_name(str(e.get("reason", "")), result)]
	var turns := int(e.get("turns", 0))
	if turns > 0:
		bits.append("%d turn%s" % [turns, "" if turns == 1 else "s"])
	var left: Variant = e.get("units_left")
	if left is Array and (left as Array).size() == 2:
		bits.append("%d v %d standing" % [int(left[0]), int(left[1])])
	if str(e.get("top_move", "")) != "":
		bits.append("most used: %s" % e["top_move"])
	mid.add_child(UiTheme.label("  ·  ".join(bits), 13, UiTheme.TEXT_DIM))

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 0)
	row.add_child(right)
	var change := int(e.get("trophy_change", 0))
	var change_text := ""
	if change != 0:
		change_text = "%+d trophies" % change
	elif bool(e.get("ranked", false)) and int(e.get("rating_change", 0)) != 0:
		change_text = "%+d rating" % int(e["rating_change"])
	var cl := UiTheme.label(change_text, 15, WIN if change > 0 or (change == 0 and int(e.get("rating_change", 0)) > 0) else LOSS)
	cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(cl)
	var when := UiTheme.label(_ago(float(e.get("ended_at", 0.0))), 13, UiTheme.TEXT_DIM)
	when.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(when)
	return row_panel


func _side_panel(rank: Dictionary, stats: Dictionary, top_moves: Array) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	box.add_child(UiTheme.label("TOP MOVES", 15, UiTheme.ACCENT))
	if top_moves.is_empty():
		box.add_child(UiTheme.label("Your most used triggers and actions appear here.", 14, UiTheme.TEXT_DIM))
	else:
		var most := maxi(1, int(top_moves[0].get("count", 1)))
		for m in top_moves:
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", 8)
			box.add_child(line)
			var name_l := UiTheme.label(str(m.get("card", "")), 14)
			name_l.custom_minimum_size = Vector2(110, 0)
			line.add_child(name_l)
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.max_value = most
			bar.value = int(m.get("count", 0))
			bar.custom_minimum_size = Vector2(0, 12)
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(bar)
			line.add_child(UiTheme.label("%d" % int(m.get("count", 0)), 14, UiTheme.TEXT_DIM))

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	box.add_child(gap)
	box.add_child(UiTheme.label("SKILL RATING", 15, UiTheme.ACCENT))
	box.add_child(UiTheme.label("%d now  ·  %d peak" % [int(rank.get("rating", 0)), int(rank.get("best_rating", 0))], 16))
	var ranked: Dictionary = stats.get("ranked", {})
	box.add_child(UiTheme.label("Ranked record: %d W  ·  %d L  ·  %d D" % [
		int(ranked.get("wins", 0)), int(ranked.get("losses", 0)), int(ranked.get("draws", 0))], 14, UiTheme.TEXT_DIM))
	return panel


# --- Formatting -----------------------------------------------------------------

static func _mode_name(e: Dictionary) -> String:
	var live := str(e.get("mode", "async")) == "live"
	if bool(e.get("ranked", false)):
		return "Live ranked" if live else "Slow ranked"
	return "Friendly (fast turns)" if live else "Friendly"


## How the match ended, from this player's side (`result`: win / loss / draw).
static func _reason_name(reason: String, result: String) -> String:
	match reason:
		"elimination":
			return "Elimination"
		"turn_cap":
			return "Decided on points" if result != "draw" else "Turn limit"
		"forfeit":
			return "Opponent surrendered" if result == "win" else "Surrendered"
		"afk":
			if result == "draw":
				return "Both players away"
			return "Opponent went away" if result == "win" else "Away too long"
	return reason.capitalize()


static func _ago(t: float) -> String:
	if t <= 0.0:
		return ""
	var s := int(Time.get_unix_time_from_system() - t)
	if s < 60:
		return "just now"
	if s < 3600:
		return "%d min ago" % (s / 60)
	if s < 86400:
		return "%d h ago" % (s / 3600)
	if s < 86400 * 30:
		return "%d d ago" % (s / 86400)
	return _date(t)


static func _date(t: float) -> String:
	var d := Time.get_date_dict_from_unix_time(int(t))
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %d" % [months[int(d["month"]) - 1], int(d["day"]), int(d["year"])]
