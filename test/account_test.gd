extends Node
## Headless tests for email accounts and profiles: password hashing (PBKDF2
## test vectors), sign-up / sign-in / sessions / sign-out, upgrading a guest,
## abuse limits, profile stats and match history (ranked and friendly),
## privacy of emails, and everything surviving a restart.
##
## Run:
##   godot --headless --path . res://test/account_test.tscn

const PORT := 18130
const DIR := "user://test_account_store"
const PW := "trion-cube-42"

var _failed := false
var _server: MatchServer
var _b: HttpBackend


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_password_hash()
	_wipe(DIR)
	_server = await _start_server(DirStore.new(DIR))
	_b = HttpBackend.new()
	_b.server_url = "http://127.0.0.1:%d" % PORT
	add_child(_b)
	await _test_signup_and_login()
	await _test_guest_upgrade_and_profile()
	await _test_friendly_history()
	await _test_limits()
	await _test_client_flow()
	await _test_restart()
	await _stop_server(_server)
	_wipe(DIR)
	print("ACCOUNT TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- PasswordHash ---------------------------------------------------------------

func _test_password_hash() -> void:
	# Reference values from Python's hashlib.pbkdf2_hmac("sha256", ...).
	var salt := "salt".to_utf8_buffer()
	_check(PasswordHash.derive("password", salt, 1).hex_encode()
		== "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "PBKDF2 vector c=1")
	_check(PasswordHash.derive("password", salt, 2).hex_encode()
		== "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", "PBKDF2 vector c=2")
	_check(PasswordHash.derive("password", salt, 4096).hex_encode()
		== "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", "PBKDF2 vector c=4096")
	var bin := PackedByteArray(range(16))
	_check(PasswordHash.derive("pässwörd", bin, 1000).hex_encode()
		== "2f56986c68f37683f0c4f846ad3742cc90085e0bfdf205d7f45ec47e3caadce8", "PBKDF2 with UTF-8 password")
	var stored := PasswordHash.encode(1000, bin, PasswordHash.derive("x", bin, 1000))
	var parsed := PasswordHash.parse(stored)
	_check(int(parsed.get("iterations", 0)) == 1000 and parsed["salt"] == bin, "hash format round-trips")
	_check(PasswordHash.parse("plain").is_empty() and PasswordHash.parse("pbkdf2_sha256$5$00$00").is_empty(),
		"malformed / too-weak hashes are rejected")
	_check(PasswordHash.check_strength("short") != "" and PasswordHash.check_strength(PW) == "", "password length rule")


# --- Sign up / sign in ---------------------------------------------------------------

func _test_signup_and_login() -> void:
	var bad_email := await _b.sign_up("not-an-email", PW, "Osamu")
	_check(int(bad_email.get("status", 0)) == 400, "sign-up rejects a bad email")
	var weak := await _b.sign_up("osamu@example.com", "short", "Osamu")
	_check(int(weak.get("status", 0)) == 400, "sign-up rejects a short password")
	var no_name := await _b.sign_up("osamu@example.com", PW, "")
	_check(int(no_name.get("status", 0)) == 400, "sign-up needs a name")

	var up := await _b.sign_up("  Osamu@Example.COM ", PW, "Osamu")
	_check(up.get("success", false) and str(up["body"].get("email")) == "osamu@example.com"
		and str(up["body"].get("secret", "")) != "", "sign-up returns a session (email normalized)")
	var pid := str(up["body"]["player_id"])
	var first_secret := str(up["body"]["secret"])
	var stored: Dictionary = _server._accounts[pid]
	_check(str(stored["password_hash"]).begins_with("pbkdf2_sha256$") and not str(stored).contains(PW),
		"password stored only as a PBKDF2 hash")

	var dup := await _b.sign_up("osamu@example.com", PW, "Fake")
	_check(int(dup.get("status", 0)) == 409, "an email can't be registered twice")

	var wrong := await _b.sign_in("osamu@example.com", "not-the-password")
	_check(int(wrong.get("status", 0)) == 403, "wrong password is refused")
	var unknown := await _b.sign_in("nobody@example.com", PW)
	_check(int(unknown.get("status", 0)) == 403 and str(unknown.get("error")) == str(wrong.get("error")),
		"unknown email gets the same answer as a wrong password")

	var login := await _b.sign_in("OSAMU@example.com", PW)
	_check(login.get("success", false) and str(login["body"]["player_id"]) == pid, "sign-in finds the account")
	var second_secret := str(login["body"].get("secret", ""))
	_check(second_secret != "" and second_secret != first_secret, "each device gets its own session")
	_check((await _b.profile(pid, first_secret)).get("success", false)
		and (await _b.profile(pid, second_secret)).get("success", false), "both sessions work")

	var out := await _b.sign_out(pid, second_secret)
	_check(out.get("success", false), "sign-out")
	_check(int((await _b.profile(pid, second_secret)).get("status", 0)) == 403, "a signed-out session stops working")
	_check((await _b.profile(pid, first_secret)).get("success", false), "other devices stay signed in")

	# Emails are private.
	var pub := await _b.get_account(pid)
	var board := await _b.leaderboard()
	_check(not JSON.stringify(pub["body"]).contains("@") and not JSON.stringify(board["body"]).contains("@"),
		"emails never appear in public account data or the leaderboard")
	_check(not pub["body"].has("history"), "match history is private")
	var reset := await _b.request_password_reset("osamu@example.com")
	_check(int(reset.get("status", 0)) == 501, "local-password servers say reset isn't available")

	var guest := await _b.register_account("Wanderer")
	var guest_out := await _b.sign_out(str(guest["body"]["player_id"]), str(guest["body"]["secret"]))
	_check(int(guest_out.get("status", 0)) == 400, "guests can't sign out (it would lose the account)")

	# Deleting the account frees the email.
	var del := await _b.delete_account(pid, first_secret)
	_check(del.get("success", false), "email account can be deleted")
	_check(int((await _b.sign_in("osamu@example.com", PW)).get("status", 0)) == 403, "deleted account can't sign in")
	var again := await _b.sign_up("osamu@example.com", PW, "Osamu")
	_check(again.get("success", false) and str(again["body"]["player_id"]) != pid, "a deleted account's email can be reused")


# --- Guest upgrade + ranked profile --------------------------------------------------

func _test_guest_upgrade_and_profile() -> void:
	var a: Dictionary = (await _b.register_account("Yuma"))["body"]
	var c: Dictionary = (await _b.register_account("Chika"))["body"]
	var units := TriggerLibrary.sample_units()
	var squad := PlanCodec.encode_squad(units)
	var q0 := await _b.queue_ranked(a["player_id"], a["secret"], squad, "live")
	var q1 := await _b.queue_ranked(c["player_id"], c["secret"], squad, "live")
	await _wait(func() -> bool: return _server._tickets[str(q0["body"]["ticket"])]["status"] == "found", 3.0)
	await _b.accept_queue(q0["body"]["ticket"], a["secret"])
	var acc1 := await _b.accept_queue(q1["body"]["ticket"], c["secret"])
	var match_id := str(acc1["body"].get("match_id", ""))
	_check(match_id != "", "ranked match found")
	var token0 := str((await _b.poll_queue(q0["body"]["ticket"], a["secret"]))["body"]["token"])
	var token1 := str(acc1["body"]["token"])

	# Turn 1: both submit Stand Ground + Shield (Shield counts as a move).
	var plan := MatchRunner.build_fallback_plan(units)
	var shields := 0
	for row in PlanCodec.encode_plan(plan)["units"]:
		for lane in ["move", "act"]:
			for act in row[lane]:
				if str(act["card"]) == "Shield":
					shields += 1
	await _b.submit_plan(match_id, token0, 1, PlanCodec.encode_plan(plan))
	await _b.submit_plan(match_id, token1, 1, PlanCodec.encode_plan(plan))
	# Turn 2: nobody submits; the clock runs out and the server auto-fills.
	var m: Dictionary = _server._matches[match_id]
	m["deadline"] = 0.0
	_server._check_timeouts()
	_check(int(m["turn"]) == 3 or int(m["winner"]) != -1, "turn 2 was auto-filled")
	# Chika surrenders.
	var ff := await _b.forfeit(match_id, token1)
	_check(ff.get("success", false), "forfeit ends the match")

	var p0: Dictionary = (await _b.profile(a["player_id"], a["secret"]))["body"]
	var p1: Dictionary = (await _b.profile(c["player_id"], c["secret"]))["body"]
	var h0: Array = p0.get("history", [])
	_check(h0.size() == 1 and str(h0[0]["result"]) == "win" and str(h0[0]["reason"]) == "forfeit"
		and str(h0[0]["opponent"]) == "Chika" and bool(h0[0]["ranked"]) and str(h0[0]["mode"]) == "live",
		"winner's history entry")
	_check(int(h0[0]["trophy_change"]) > 0 and int(p0["rank"]["trophies"]) == int(h0[0]["trophies"]),
		"history records the trophy change")
	var s0: Dictionary = p0["stats"]
	_check(int(s0["played"]) == 1 and int(s0["wins"]) == 1 and is_equal_approx(float(s0["win_rate"]), 1.0)
		and int(s0["streak"]) == 1 and int(s0["best_streak"]) == 1, "winner's totals, win rate, streak")
	_check(str(s0["favorite_move"]) == "Shield" and int(s0["top_moves"][0]["count"]) == shields,
		"favorite move counts submitted turns only (%d Shields, not the auto-filled turn)" % shields)
	var s1: Dictionary = p1["stats"]
	_check(int(s1["losses"]) == 1 and int(s1["streak"]) == 0 and str(p1["history"][0]["result"]) == "loss",
		"loser's profile")
	_check(int(p0["rank"]["position"]) < int(p1["rank"]["position"]), "ladder position follows trophies")
	_check(int(p0["rank"]["best_trophies"]) >= int(p0["rank"]["trophies"])
		and str(p0["rank"]["best_arena"]) != "", "max rank and arena")
	_check(bool(p0["guest"]) and str(p0["email"]) == "", "guest profile")

	# The guest makes an account: same player, progress kept, still signed in here.
	var up := await _b.sign_up("yuma@example.com", PW, "", { "player_id": a["player_id"], "secret": a["secret"] })
	_check(up.get("success", false) and str(up["body"]["player_id"]) == str(a["player_id"])
		and str(up["body"]["secret"]) == str(a["secret"]) and str(up["body"]["name"]) == "Yuma",
		"guest upgrade keeps the account and its name")
	var after: Dictionary = (await _b.profile(a["player_id"], a["secret"]))["body"]
	_check(not bool(after["guest"]) and (after["history"] as Array).size() == 1, "upgraded account keeps its history")
	var login := await _b.sign_in("yuma@example.com", PW)
	_check(login.get("success", false) and str(login["body"]["player_id"]) == str(a["player_id"]),
		"upgraded account can sign in elsewhere")
	var twice := await _b.sign_up("other@example.com", PW, "", { "player_id": a["player_id"], "secret": a["secret"] })
	_check(int(twice.get("status", 0)) == 409, "an account gets only one email")
	var forged := await _b.sign_up("thief@example.com", PW, "", { "player_id": c["player_id"], "secret": "wrong" })
	_check(int(forged.get("status", 0)) == 403, "upgrading needs the guest's secret")


# --- Friendly rooms ---------------------------------------------------------------

func _test_friendly_history() -> void:
	var host: Dictionary = (await _b.sign_up("host@example.com", PW, "Host"))["body"]
	var friend: Dictionary = (await _b.register_account("Friend"))["body"]
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var created := await _b.create_match(squad, "async", host)
	var id := str(created["body"]["match_id"])
	var joined := await _b.join_match(id, squad, friend)
	_check(_server._matches[id]["players"] == [str(host["player_id"]), str(friend["player_id"])],
		"friendly room records both accounts")
	await _b.forfeit(id, str(joined["body"]["token"]))
	var hist: Array = (await _b.profile(host["player_id"], host["secret"]))["body"]["history"]
	_check(hist.size() == 1 and not bool(hist[0]["ranked"]) and str(hist[0]["result"]) == "win"
		and int(hist[0]["trophy_change"]) == 0 and str(hist[0]["opponent"]) == "Friend", "friendly match in history, no trophies")

	# Bad credentials leave the seat anonymous; playing yourself counts once.
	var anon := await _b.create_match(squad, "async", { "player_id": host["player_id"], "secret": "nope" })
	_check(_server._matches[str(anon["body"]["match_id"])]["players"] == ["", ""], "bad credentials: anonymous seat")
	var solo := await _b.create_match(squad, "async", host)
	var solo_id := str(solo["body"]["match_id"])
	await _b.join_match(solo_id, squad, host)
	_check(_server._matches[solo_id]["players"] == [str(host["player_id"]), ""], "the same account can't take both seats")
	# A room nobody joined isn't history.
	var empty := await _b.create_match(squad, "async", host)
	await _b.forfeit(str(empty["body"]["match_id"]), str(empty["body"]["token"]))
	var hist2: Array = (await _b.profile(host["player_id"], host["secret"]))["body"]["history"]
	_check(hist2.size() == 1, "unjoined rooms don't enter the history")


# --- Limits ----------------------------------------------------------------------

func _test_limits() -> void:
	# Hashing is bounded: past MAX_HASH_JOBS at once the server says busy.
	var replies: Array = []
	var busy := false
	for i in MatchServer.MAX_HASH_JOBS + 1:
		var res := _server._handle_request("POST", "/account/login",
			{ "email": "x%d@example.com" % i, "password": "whatever-123" }, { "ip": "127.0.0.1" })
		if res.get("deferred") is HttpServer.Deferred:
			replies.append(res["deferred"])
		elif int(res["status"]) == 503:
			busy = true
	_check(busy and replies.size() == MatchServer.MAX_HASH_JOBS, "concurrent password hashing is capped")
	await _wait(func() -> bool: return replies.all(func(r: HttpServer.Deferred) -> bool: return r.done), 10.0)

	# Two sign-ups racing for one email: exactly one wins.
	var r1: Dictionary = _server._handle_request("POST", "/account/signup",
		{ "email": "race@example.com", "password": PW, "name": "A" }, { "ip": "127.0.0.1" })
	var r2: Dictionary = _server._handle_request("POST", "/account/signup",
		{ "email": "race@example.com", "password": PW, "name": "B" }, { "ip": "127.0.0.1" })
	await _wait(func() -> bool: return r1["deferred"].done and r2["deferred"].done, 10.0)
	var codes := [int(r1["deferred"].response["status"]), int(r2["deferred"].response["status"])]
	codes.sort()
	_check(codes == [200, 409], "racing sign-ups: one account per email")

	# Failed logins from one address are rate limited.
	var ip := "203.0.113.50"
	var last := 0
	for i in MatchServer.LIMIT_AUTH_FAIL[0] + 1:
		var res: Dictionary = _server._handle_request("POST", "/account/login",
			{ "email": "race@example.com", "password": "guess-%d-xx" % i }, { "ip": ip })
		if res.get("deferred") is HttpServer.Deferred:
			var d: HttpServer.Deferred = res["deferred"]
			await _wait(func() -> bool: return d.done, 10.0)
			last = int(d.response["status"])
		else:
			last = int(res["status"])
	_check(last == 429, "repeated wrong passwords get locked out (got %d)" % last)


# --- Client (GameConnection + AccountStore, what the screens call) -------------------

func _test_client_flow() -> void:
	var conn := GameConnection.new()
	add_child(conn)
	await conn.connect_to(_b.server_url)
	AccountStore.clear_for(conn.server_url)   # keyed by this test server's URL only
	var guest := await conn.ensure_account("Hyuse")
	_check(not guest.is_empty() and not AccountStore.is_signed_in(AccountStore.load_for(conn.server_url)),
		"client: online play makes a guest account")
	var up := await conn.sign_up("hyuse@example.com", PW, "")
	var saved := AccountStore.load_for(conn.server_url)
	_check(str(up.get("player_id")) == str(guest["player_id"]) and str(saved.get("email")) == "hyuse@example.com",
		"client: creating an account upgrades this device's guest")
	var old_secret := str(saved["secret"])
	await conn.sign_out()
	_check(AccountStore.load_for(conn.server_url).is_empty(), "client: sign-out forgets the account locally")
	_check(int((await _b.profile(guest["player_id"], old_secret)).get("status", 0)) == 403,
		"client: sign-out ends the session on the server")
	var bad := await conn.sign_in("hyuse@example.com", "wrong-password")
	_check(bad.is_empty() and conn.last_error.begins_with("wrong email or password"), "client: wrong password reported")
	var back := await conn.sign_in("hyuse@example.com", PW)
	_check(str(back.get("player_id")) == str(guest["player_id"]) and AccountStore.is_signed_in(AccountStore.load_for(conn.server_url)),
		"client: sign-in saves the session")
	var prof := await conn.fetch_profile()
	_check(str(prof.get("email")) == "hyuse@example.com" and not bool(prof.get("guest", true)), "client: fetch_profile")
	# A signed-in account the server no longer has is not swapped for a new guest.
	_server._accounts.erase(str(guest["player_id"]))
	var gone := await conn.ensure_account("Hyuse")
	_check(gone.is_empty() and AccountStore.load_for(conn.server_url).is_empty(),
		"client: a vanished signed-in account asks to sign in again")
	AccountStore.clear_for(conn.server_url)
	conn.queue_free()


# --- Restart ---------------------------------------------------------------------

func _test_restart() -> void:
	await _stop_server(_server)
	_server = await _start_server(DirStore.new(DIR))
	var login := await _b.sign_in("yuma@example.com", PW)
	_check(login.get("success", false), "email sign-in works after a restart")
	var p: Dictionary = (await _b.profile(login["body"]["player_id"], login["body"]["secret"]))["body"]
	_check((p.get("history", []) as Array).size() == 1 and str(p["stats"]["favorite_move"]) == "Shield",
		"history and stats survive a restart")
	_check(int((await _b.sign_up("yuma@example.com", PW, "Copy")).get("status", 0)) == 409,
		"email index is rebuilt on load")


# --- Helpers -----------------------------------------------------------------------

func _start_server(store: GameStore) -> MatchServer:
	var s := MatchServer.new()
	s.store = store
	s.port = PORT
	s.password_iterations = 2000   # fast tests; production uses PasswordHash.DEFAULT_ITERATIONS
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
