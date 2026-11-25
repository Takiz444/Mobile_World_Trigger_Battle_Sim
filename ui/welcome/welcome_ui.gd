class_name WelcomeUI
extends Control
## The first screen: sign in with email, create an account, or continue as a
## guest. Signed-in players skip it (straight to the Hangar). Guests can still
## play everything: offline vs AI needs no account, and online play makes a
## guest account that lives only on this device. Creating an account while a
## guest account is saved here moves its trophies and history to the new one.

const HANGAR := "res://ui/hangar/hangar.tscn"
## The server's minimum (PasswordHash.MIN_LENGTH), checked here first.
const PASSWORD_MIN_LENGTH := 8

## Opened from the Hangar / Profile ("Sign In", "Create Account"): which tab
## to show first. Reset after use.
static var start_on_create := false

var _conn: GameConnection
var _create := false
var _busy := false
var _tab_sign_in: Button
var _tab_create: Button
var _email: LineEdit
var _password: LineEdit
var _name_row: Control
var _name: LineEdit
var _submit: Button
var _guest_btn: Button
var _status: Label
var _hint: Label
var _server_input: LineEdit
var _forgot: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UiTheme.install(get_tree())
	if MatchSession.server_url == ServerConfig.DEV_URL or not ServerConfig.allow_custom_server():
		MatchSession.server_url = ServerConfig.default_url()
	# Already signed in on this device: nothing to ask.
	if AccountStore.is_signed_in(AccountStore.load_for(MatchSession.server_url)) and not start_on_create:
		_go_to_hangar.call_deferred()
		return
	_conn = GameConnection.new()
	_conn.name = "GameConnection"
	add_child(_conn)
	_build()
	_set_mode(start_on_create)
	start_on_create = false


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(440, 0)
	column.add_theme_constant_override("separation", 10)
	center.add_child(column)

	var title := UiTheme.label("TRION TACTICS", 34, UiTheme.ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var tagline := UiTheme.label("3v3 simultaneous tactics in a living city", 16, UiTheme.TEXT_DIM)
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(tagline)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	column.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)

	# Two tabs: Sign In / Create Account.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	box.add_child(tabs)
	var group := ButtonGroup.new()
	_tab_sign_in = _tab("Sign In", group, tabs)
	_tab_sign_in.pressed.connect(_set_mode.bind(false))
	_tab_create = _tab("Create Account", group, tabs)
	_tab_create.pressed.connect(_set_mode.bind(true))

	_email = _field(box, "Email", "you@example.com")
	_email.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	_password = _field(box, "Password", "At least %d characters" % PASSWORD_MIN_LENGTH)
	_password.secret = true
	_password.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	_name = _field(box, "Player name", "The name other players see")
	_name.max_length = NameRules.PLAYER_NAME_MAX
	_name_row = _name.get_parent()

	_hint = UiTheme.label("", 13, UiTheme.TEXT_DIM)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_hint)

	_submit = Button.new()
	UiTheme.style_primary(_submit)
	_submit.pressed.connect(_on_submit)
	box.add_child(_submit)

	# Servers using Auth0 email a reset link; others say they can't.
	_forgot = Button.new()
	_forgot.text = "Forgot password?"
	_forgot.flat = true
	_forgot.focus_mode = Control.FOCUS_NONE
	_forgot.add_theme_color_override("font_color", UiTheme.ACCENT)
	_forgot.add_theme_font_size_override("font_size", 14)
	_forgot.pressed.connect(_on_forgot)
	box.add_child(_forgot)

	_status = UiTheme.label("", 14, UiTheme.DANGER)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.visible = false
	box.add_child(_status)

	for f in [_email, _password, _name]:
		(f as LineEdit).text_submitted.connect(func(_t: String) -> void: _on_submit())

	# --- or play as a guest ---------------------------------------------------------
	var divider := HBoxContainer.new()
	divider.add_theme_constant_override("separation", 12)
	column.add_child(divider)
	divider.add_child(_rule())
	var or_label := UiTheme.label("or", 14, UiTheme.TEXT_DIM)
	divider.add_child(or_label)
	divider.add_child(_rule())

	_guest_btn = Button.new()
	_guest_btn.text = "Continue as Guest"
	_guest_btn.tooltip_text = "Play without an account"
	_guest_btn.pressed.connect(_go_to_hangar)
	column.add_child(_guest_btn)
	var guest_note := UiTheme.label(
		"Guests can play offline and online. Online progress is kept on this device only.", 13, UiTheme.TEXT_DIM)
	guest_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	guest_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(guest_note)

	# Development builds: which server to sign in to.
	_server_input = LineEdit.new()
	_server_input.text = MatchSession.server_url
	_server_input.placeholder_text = "Server URL (dev)"
	_server_input.tooltip_text = "Development builds only: which server to sign in to"
	_server_input.visible = ServerConfig.allow_custom_server()
	column.add_child(_server_input)

	for b in find_children("*", "BaseButton", true, false):
		UiTheme.add_press_feedback(b)


func _set_mode(create: bool) -> void:
	_create = create
	_tab_sign_in.button_pressed = not create
	_tab_create.button_pressed = create
	_name_row.visible = create
	_submit.text = "Create Account" if create else "Sign In"
	_password.placeholder_text = "At least %d characters" % PASSWORD_MIN_LENGTH if create else "Your password"
	var saved := AccountStore.load_for(_server_url())
	if create and not saved.is_empty() and not AccountStore.is_signed_in(saved):
		_hint.text = "Your guest progress (trophies and match history) moves to this account."
		if _name.text == "":
			_name.text = str(saved.get("name", ""))
	elif create:
		_hint.text = "Your profile keeps your rank and match history on every device."
	elif not saved.is_empty() and not AccountStore.is_signed_in(saved):
		_hint.text = "Signing in replaces the guest account on this device. To keep its progress, use Create Account instead."
	else:
		_hint.text = ""
	_hint.visible = _hint.text != ""
	_forgot.visible = not create
	_show_error("")


func _on_submit() -> void:
	if _busy:
		return
	var email := _email.text.strip_edges()
	var password := _password.text
	var player_name := _name.text.strip_edges()
	var problem := _check_input(email, password, player_name)
	if problem != "":
		_show_error(problem)
		return
	_set_busy(true)
	_show_error("")
	var url := _server_url()
	MatchSession.server_url = url
	if _conn.server_url != url or not _conn.is_online():
		await _conn.connect_to(url)
	if not is_inside_tree():
		return
	if not _conn.is_online():
		_set_busy(false)
		_show_error(_conn.last_error if _conn.status == GameConnection.Status.OUTDATED
			else "Can't reach the server. Check your connection, or continue as a guest.")
		return
	var session: Dictionary
	if _create:
		session = await _conn.sign_up(email, password, player_name)
	else:
		session = await _conn.sign_in(email, password)
	if not is_inside_tree():
		return
	_set_busy(false)
	if session.is_empty():
		_show_error(_friendly(_conn.last_error))
		return
	_go_to_hangar()


## Client-side checks before bothering the server ("" = fine).
func _check_input(email: String, password: String, player_name: String) -> String:
	var at := email.find("@")
	if at < 1 or at == email.length() - 1 or not email.substr(at + 1).contains("."):
		_email.grab_focus()
		return "Enter a valid email address."
	if password == "":
		_password.grab_focus()
		return "Enter your password."
	if _create and password.length() < PASSWORD_MIN_LENGTH:
		_password.grab_focus()
		return "Use at least %d characters for your password." % PASSWORD_MIN_LENGTH
	if _create and player_name == "":
		_name.grab_focus()
		return "Pick a player name."
	return ""


## Server errors, worded for players.
static func _friendly(error: String) -> String:
	if error.begins_with("wrong email or password"):
		return "That email and password don't match. Try again."
	if error.begins_with("an account with this email already exists"):
		return "An account with this email already exists. Sign in instead."
	if error.begins_with("too many"):
		return "Too many attempts. Please wait a few minutes and try again."
	if error.begins_with("server busy"):
		return "The server is busy. Try again in a moment."
	return error.left(1).to_upper() + error.substr(1) if error != "" else "Something went wrong. Try again."


func _set_busy(busy: bool) -> void:
	_busy = busy
	_submit.disabled = busy
	_guest_btn.disabled = busy
	_tab_sign_in.disabled = busy
	_tab_create.disabled = busy
	_forgot.disabled = busy
	if busy:
		_submit.text = "Creating account…" if _create else "Signing in…"
	else:
		_submit.text = "Create Account" if _create else "Sign In"


func _show_error(text: String, good := false) -> void:
	_status.text = text
	_status.visible = text != ""
	_status.add_theme_color_override("font_color", UiTheme.GOOD if good else UiTheme.DANGER)


func _on_forgot() -> void:
	if _busy:
		return
	var email := _email.text.strip_edges()
	if not email.contains("@"):
		_email.grab_focus()
		_show_error("Enter your email above, then tap Forgot password.")
		return
	_set_busy(true)
	_show_error("")
	var url := _server_url()
	MatchSession.server_url = url
	if _conn.server_url != url or not _conn.is_online():
		await _conn.connect_to(url)
	if not is_inside_tree():
		return
	if not _conn.is_online():
		_set_busy(false)
		_show_error("Can't reach the server. Check your connection and try again.")
		return
	var res := await _conn.backend.request_password_reset(email)
	if not is_inside_tree():
		return
	_set_busy(false)
	if res.get("success", false):
		_show_error("If an account uses that email, a reset link is on its way. Check your inbox.", true)
	elif int(res.get("status", 0)) == 501:
		_show_error("Password reset isn't available on this server.")
	else:
		_show_error(_friendly(str(res.get("error", ""))))


func _server_url() -> String:
	if ServerConfig.allow_custom_server() and _server_input != null and _server_input.text.strip_edges() != "":
		return _server_input.text.strip_edges().rstrip("/")
	return MatchSession.server_url if ServerConfig.allow_custom_server() else ServerConfig.default_url()


func _go_to_hangar() -> void:
	UiTheme.change_scene(get_tree(), HANGAR)


# --- Building blocks ------------------------------------------------------------

func _card_style() -> StyleBoxFlat:
	var sb := UiTheme.panel_style()
	sb.set_content_margin_all(18)
	sb.set_corner_radius_all(14)
	return sb


func _tab(text: String, group: ButtonGroup, parent: Control) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	var on := StyleBoxFlat.new()
	on.bg_color = Color(0, 0, 0, 0)
	on.border_color = UiTheme.ACCENT
	on.border_width_bottom = 3
	on.content_margin_top = 10
	on.content_margin_bottom = 10
	var off := on.duplicate() as StyleBoxFlat
	off.border_color = UiTheme.PANEL_EDGE
	off.border_width_bottom = 1
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", off)
	b.add_theme_stylebox_override("disabled", off)
	b.add_theme_color_override("font_pressed_color", UiTheme.ACCENT)
	b.add_theme_color_override("font_hover_pressed_color", UiTheme.ACCENT)
	b.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	b.add_theme_font_size_override("font_size", 17)
	parent.add_child(b)
	return b


## A labelled text field; returns the LineEdit (its parent is the row).
func _field(parent: Control, caption: String, placeholder: String) -> LineEdit:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	parent.add_child(row)
	row.add_child(UiTheme.label(caption, 14, UiTheme.TEXT_DIM))
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 42)
	row.add_child(edit)
	return edit


func _rule() -> Control:
	var line := ColorRect.new()
	line.color = UiTheme.PANEL_EDGE
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return line
