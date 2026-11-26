extends Node
## Headless tests for sign-in through Auth0 (Auth0Client + MatchServer) against
## an in-process fake of the Auth0 endpoints the server uses: sign-up,
## password-realm sign-in (id_token), the forwarded player IP, password reset,
## Management API deletion, outages, and restarts. Also the deploy/.env loader.
##
## Run:
##   godot --headless --path . res://test/auth0_test.tscn

const PORT := 18140
const AUTH0_PORT := 18145   # not PORT + 1: that is the live port
const DIR := "user://test_auth0_store"
const CLIENT_ID := "test-client-id"
const SECRET := "test-client-secret-0123456789"
const PW := "Trion-cube-42"

var _failed := false
var _fake: FakeAuth0
var _server: MatchServer
var _b: HttpBackend
var _accounts_before_kuga := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_env_file()
	_wipe(DIR)
	_fake = FakeAuth0.new()
	add_child(_fake)
	_fake.start(AUTH0_PORT)
	_server = await _start_server()
	_b = HttpBackend.new()
	_b.server_url = "http://127.0.0.1:%d" % PORT
	add_child(_b)
	await _test_signup_login()
	await _test_existing_auth0_users()
	await _test_pre_auth0_account_moves()
	await _test_reset_delete_outage()
	await _test_restart()
	await _stop_server(_server)
	_fake.stop()
	_wipe(DIR)
	print("AUTH0 TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- deploy/.env loader -------------------------------------------------------------

func _test_env_file() -> void:
	var path := ProjectSettings.globalize_path("user://test.env")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("# comment\nTT_T_PLAIN=abc\nexport TT_T_EXPORT=1\nTT_T_QUOTED=\"mongodb+srv://u:p@h/?a=1&w=majority\"\n"
		+ "TT_T_SINGLE='x y'\nTT_T_EMPTY=\nTT_T_KEPT=from-file\nnot a setting\n")
	f.close()
	OS.set_environment("TT_T_KEPT", "from-environment")
	var n := MatchServer.load_env(path)
	_check(n == 5, "env file: 5 settings loaded (%d)" % n)
	_check(OS.get_environment("TT_T_PLAIN") == "abc" and OS.get_environment("TT_T_EXPORT") == "1"
		and OS.get_environment("TT_T_SINGLE") == "x y", "env file: plain, export, and quoted values")
	_check(OS.get_environment("TT_T_QUOTED") == "mongodb+srv://u:p@h/?a=1&w=majority", "env file: connection strings keep & and ?")
	_check(OS.get_environment("TT_T_KEPT") == "from-environment", "env file: real environment variables win")
	_check(MatchServer.load_env(path + ".missing") == -1, "env file: a missing file is fine")
	DirAccess.remove_absolute(path)


# --- Sign-up / sign-in --------------------------------------------------------------

func _test_signup_login() -> void:
	var health := await _b.health()
	_check(str(health["body"].get("auth")) == "auth0", "health says sign-in is Auth0")

	var up := await _b.sign_up("Osamu@Example.com", PW, "Osamu")
	_check(up.get("success", false) and str(up["body"].get("email")) == "osamu@example.com", "sign-up through Auth0")
	var pid := str(up["body"].get("player_id", ""))
	var acc: Dictionary = _server._accounts.get(pid, {})
	_check(str(acc.get("auth0_sub", "")).begins_with("auth0|") and str(acc.get("password_hash")) == "",
		"account linked to its Auth0 user; no password stored by the game")
	_check(_fake.users.has("osamu@example.com") and str(_fake.users["osamu@example.com"]["nickname"]) == "Osamu",
		"Auth0 has the user with its nickname")
	var prof: Dictionary = (await _b.profile(pid, str(up["body"]["secret"])))["body"]
	_check(not bool(prof["email_verified"]) and not bool(prof["guest"]), "profile shows the email isn't verified yet")

	var weak := await _b.sign_up("weak@example.com", "password1", "Weak")
	_check(int(weak.get("status", 0)) == 400 and str(weak.get("error")).begins_with("password is too weak"),
		"Auth0's password policy is passed on")
	var dup := await _b.sign_up("osamu@example.com", PW, "Again")
	_check(int(dup.get("status", 0)) == 409, "duplicate email refused")

	# Through the request handler, to see the player's IP reach Auth0.
	var res: Dictionary = _server._handle_request("POST", "/account/login",
		{ "email": "osamu@example.com", "password": "nope-Nope-1" }, { "ip": "203.0.113.7" })
	var d: HttpServer.Deferred = res["deferred"]
	await _wait(func() -> bool: return d.done, 5.0)
	_check(int(d.response["status"]) == 403 and _fake.last_forwarded_for == "203.0.113.7",
		"wrong password: 403, with the player's IP forwarded to Auth0")

	var login := await _b.sign_in("osamu@example.com", PW)
	_check(login.get("success", false) and str(login["body"]["player_id"]) == pid
		and str(login["body"]["secret"]) != str(up["body"]["secret"]), "sign-in: same account, new session")

	# A guest makes an account: same player id, still signed in on this device.
	var guest: Dictionary = (await _b.register_account("Yuma"))["body"]
	var upg := await _b.sign_up("yuma@example.com", PW, "", guest)
	_check(upg.get("success", false) and str(upg["body"]["player_id"]) == str(guest["player_id"])
		and str(upg["body"]["secret"]) == str(guest["secret"]), "guest upgrade through Auth0 keeps the account")


func _test_existing_auth0_users() -> void:
	# Made in the Auth0 dashboard: first sign-in creates the game account.
	_fake.add_user("chika@example.com", PW, "Chika")
	var first := await _b.sign_in("chika@example.com", PW)
	_check(first.get("success", false) and str(first["body"]["name"]) == "Chika", "Auth0-only user gets a game account")
	var pid := str(first["body"]["player_id"])
	# Verified and changed email in Auth0: picked up on the next sign-in.
	_fake.users["chika@example.com"]["email_verified"] = true
	_fake.rename("chika@example.com", "chika.amatori@example.com")
	var again := await _b.sign_in("chika.amatori@example.com", PW)
	var prof: Dictionary = (await _b.profile(pid, str(again["body"]["secret"])))["body"]
	_check(str(again["body"]["player_id"]) == pid and str(prof["email"]) == "chika.amatori@example.com"
		and bool(prof["email_verified"]), "email change and verification sync from Auth0")
	_check(not _server._email_index.has("chika@example.com"), "old email released")


## An account from before Auth0 (local password) moves over only once Auth0
## has verified the email.
func _test_pre_auth0_account_moves() -> void:
	_accounts_before_kuga = _server._accounts.size()
	var old := _server._new_email_account("Kuga")
	old["email"] = "kuga@example.com"
	old["password_hash"] = "pbkdf2_sha256$1000$00$00"
	_server._email_index["kuga@example.com"] = old["id"]
	var up := await _b.sign_up("kuga@example.com", PW, "Kuga")
	_check(int(up.get("status", 0)) == 409 and str(up.get("error")).contains("verify your email")
		and _fake.users.has("kuga@example.com"), "pre-Auth0 email: Auth0 user made, verification asked for")
	var early := await _b.sign_in("kuga@example.com", PW)
	_check(int(early.get("status", 0)) == 403 and str(early.get("error")).begins_with("verify your email")
		and _server._accounts.size() == _accounts_before_kuga + 1, "unverified: asked to verify, no stray account made")
	_fake.users["kuga@example.com"]["email_verified"] = true
	var later := await _b.sign_in("kuga@example.com", PW)
	_check(str(later["body"].get("player_id", "")) == str(old["id"]), "verified: the old account moves to Auth0")


func _test_reset_delete_outage() -> void:
	var reset := await _b.request("POST", "/account/password_reset", { "email": "osamu@example.com" })
	_check(reset.get("success", false) and _fake.resets.has("osamu@example.com"), "password reset email requested from Auth0")
	var bad := await _b.request("POST", "/account/password_reset", { "email": "nope" })
	_check(int(bad.get("status", 0)) == 400, "password reset needs an email")

	var gone := await _b.sign_up("gone@example.com", PW, "Gone")
	var del := await _b.delete_account(str(gone["body"]["player_id"]), str(gone["body"]["secret"]))
	await _wait(func() -> bool: return not _fake.users.has("gone@example.com"), 5.0)
	_check(del.get("success", false) and not _fake.users.has("gone@example.com"), "deleting the account deletes the Auth0 user")

	_fake.stop()
	var down := await _b.sign_in("osamu@example.com", PW)
	_check(int(down.get("status", 0)) == 503 and str(down.get("error")).contains("unavailable"),
		"Auth0 unreachable: a clear 503")
	_fake.start(AUTH0_PORT)


func _test_restart() -> void:
	var before := await _b.sign_in("osamu@example.com", PW)
	await _stop_server(_server)
	_server = await _start_server()
	var after := await _b.sign_in("osamu@example.com", PW)
	_check(after.get("success", false) and str(after["body"]["player_id"]) == str(before["body"]["player_id"]),
		"Auth0 links survive a restart")


# --- Helpers -----------------------------------------------------------------------

func _start_server() -> MatchServer:
	var s := MatchServer.new()
	s.store = DirStore.new(DIR)
	s.port = PORT
	s.auth0_domain = "http://127.0.0.1:%d" % AUTH0_PORT
	s.auth0_client_id = CLIENT_ID
	s.auth0_client_secret = SECRET
	add_child(s)
	await _wait(func() -> bool: return s._http._tcp.is_listening(), 5.0)
	return s


func _stop_server(s: MatchServer) -> void:
	remove_child(s)
	s.queue_free()
	await get_tree().create_timer(0.2).timeout


func _wait(cond: Callable, timeout_sec: float) -> void:
	var end := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _wipe(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for kind in GameStore.KINDS:
		var dir := "%s/%s" % [path, kind]
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute("%s/%s" % [dir, f])
		DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(path)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)


## The Auth0 endpoints Auth0Client calls, with Auth0's response shapes.
class FakeAuth0 extends Node:
	const CONNECTION := "Username-Password-Authentication"
	var users := {}     # email -> {sub, password, nickname, email_verified}
	var resets: Array = []
	var last_forwarded_for := ""
	var _next := 1
	var _http: HttpServer
	var _port := 0

	func start(port: int) -> void:
		_port = port
		_http = HttpServer.new()
		_http.allowed_methods = ["GET", "POST", "DELETE"]
		_http.start(port, _handle)

	func stop() -> void:
		if _http != null:
			_http.stop()
			_http = null

	func _process(_delta: float) -> void:
		if _http != null:
			_http.poll()

	func add_user(email: String, password: String, nickname: String) -> void:
		users[email] = { "sub": "auth0|%d" % _next, "password": password, "nickname": nickname, "email_verified": false }
		_next += 1

	func rename(old: String, new_email: String) -> void:
		users[new_email] = users[old]
		users.erase(old)

	func _handle(method: String, path: String, body: Dictionary, ctx: Dictionary = {}) -> Dictionary:
		if method == "POST" and path == "/dbconnections/signup":
			if body.get("client_id") != "test-client-id" or body.get("connection") != CONNECTION:
				return _r(400, { "error": "bad client" })
			var pw := str(body.get("password", ""))
			if pw.length() < 8 or pw.to_lower() == pw:
				return _r(400, { "name": "PasswordStrengthError", "code": "invalid_password", "message": "Password is too weak" })
			var email := str(body.get("email", "")).to_lower()
			if users.has(email):
				return _r(400, { "code": "invalid_signup", "description": "Invalid sign up" })
			add_user(email, pw, str(body.get("nickname", "")))
			return _r(200, { "_id": str(users[email]["sub"]).trim_prefix("auth0|"), "email": email, "email_verified": false })
		if method == "POST" and path == "/oauth/token":
			if body.get("client_secret") != "test-client-secret-0123456789":
				return _r(401, { "error": "access_denied" })
			if body.get("grant_type") == "client_credentials":
				return _r(200, { "access_token": "mgmt-token", "expires_in": 86400, "token_type": "Bearer" })
			last_forwarded_for = str(ctx.get("headers", {}).get("auth0-forwarded-for", ""))
			var u: Dictionary = users.get(str(body.get("username", "")).to_lower(), {})
			if body.get("realm") != CONNECTION or u.is_empty() or u["password"] != body.get("password"):
				return _r(403, { "error": "invalid_grant", "error_description": "Wrong email or password." })
			var email := ""
			for e in users:
				if users[e] == u:
					email = e
			var claims := { "iss": "http://127.0.0.1:%d/" % _port, "aud": "test-client-id", "sub": u["sub"],
				"exp": Time.get_unix_time_from_system() + 3600, "email": email,
				"email_verified": u["email_verified"], "nickname": u["nickname"] }
			var jwt := "%s.%s.sig" % [_b64url({ "alg": "RS256" }), _b64url(claims)]
			return _r(200, { "access_token": "at", "id_token": jwt, "token_type": "Bearer", "expires_in": 86400 })
		if method == "POST" and path == "/dbconnections/change_password":
			resets.append(str(body.get("email", "")))
			return _r(200, "We've just sent you an email to reset your password.")
		if method == "DELETE" and path.begins_with("/api/v2/users/"):
			if str(ctx.get("bearer", "")) != "mgmt-token":
				return _r(401, { "error": "unauthorized" })
			var sub := path.trim_prefix("/api/v2/users/").uri_decode()
			for e in users.keys():
				if users[e]["sub"] == sub:
					users.erase(e)
			return _r(204, {})
		return _r(404, { "error": "not found" })

	func _r(status: int, body: Variant) -> Dictionary:
		return { "status": status, "body": body }

	static func _b64url(d: Dictionary) -> String:
		return Marshalls.utf8_to_base64(JSON.stringify(d)).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")
