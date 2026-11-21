extends Node
## Headless security / abuse regression tests: everything a modified client
## could try against the server or the rules. Each check here corresponds to
## a hole that existed once.
##
## Run:
##   godot --headless --path . res://test/security_test.tscn

const PORT := 18140
const URL := "http://127.0.0.1:18140"

var _server: MatchServer
var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_engine_bounds()
	_test_no_probing()
	_test_mutual_knockout()
	_test_spider_range()
	_test_fogged_wires()
	_test_names()
	_test_plan_numbers()
	_test_secret_compare()

	_server = MatchServer.new()
	_server.persist = false
	_server.port = PORT
	add_child(_server)
	await get_tree().create_timer(0.5).timeout
	await _test_http_surface()
	await _test_accounts_and_resume()
	_test_limits()
	await _test_slow_reader()

	print("SECURITY TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Rules --------------------------------------------------------------------

## A plan target billions of hexes away used to reach HexCoord.line() and
## hang the server (one request froze every match).
func _test_engine_bounds() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), 3]])
	var far := Vector2i(2000000000, -2000000000)
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_look_card())
	p0.set_target(0, 0, far)
	p0.assign(0, 1, TurnPlan.MAIN_SLOT, TriggerLibrary.get_move_card())
	p0.set_target(0, 1, far)
	p0.assign(0, 2, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Kogetsu"))
	p0.set_target(0, 2, far)
	var started := Time.get_ticks_msec()
	TickEngine.new().resolve(ms, p0, _plan(ms, 1))
	_check(Time.get_ticks_msec() - started < 1000, "absurd targets resolve instantly")
	_check((ms.teams[0][0] as UnitState).hex == Vector2i(0, 0), "absurd move target is ignored")


## A failed attack must not reveal whether an unseen enemy stands on the hex.
func _test_no_probing() -> void:
	# Shooter (Asteroid, range 5) at origin; enemy far out of range.
	var ms := _match([[0, Vector2i(0, 0), 0, 1], [1, Vector2i(0, 9), 3]])
	var events := _attack(ms, "Asteroid", Vector2i(0, 9))
	var empty := _attack(_match([[0, Vector2i(0, 0), 0, 1], [1, Vector2i(5, 9), 3]]), "Asteroid", Vector2i(0, 9))
	_check(_messages(events) == _messages(empty), "out-of-range attack reads the same with or without a target")
	_check(_no_enemy_named(events), "out-of-range attack names no enemy")

	# In range but stealthed beyond the reveal range: same as an empty hex.
	ms = _match([[0, Vector2i(0, 0), 0, 1], [1, Vector2i(0, 5), 3]])
	(ms.teams[1][0] as UnitState).stealth_active = true
	var p1 := _plan(ms, 1)
	p1.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Bagworm"))
	events = _attack(ms, "Asteroid", Vector2i(0, 5), p1)
	empty = _attack(_match([[0, Vector2i(0, 0), 0, 1], [1, Vector2i(9, 9), 3]]), "Asteroid", Vector2i(0, 5))
	_check(_messages(events) == _messages(empty), "attack on a stealthed unit reads like an empty hex")
	_check((ms.teams[1][0] as UnitState).trion_hp == 100, "stealthed unit beyond reveal range takes no damage")


func _test_mutual_knockout() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 1), 3]])
	for u in ms.all_units():
		u.is_bailed = true
	_check(MatchRunner.winner(ms) == MatchRunner.DRAW, "both squads down on the same tick is a draw")
	(ms.teams[0][0] as UnitState).is_bailed = false
	_check(MatchRunner.winner(ms) == 0, "last squad standing still wins")


func _test_spider_range() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0, 3], [1, Vector2i(0, 9), 3]])
	var p0 := _plan(ms, 0)
	var spider := TriggerLibrary.get_card("Spider")
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, spider)
	p0.set_target(0, 0, Vector2i(0, 20))
	p0.assign(0, 1, TurnPlan.MAIN_SLOT, spider)
	p0.set_target(0, 1, Vector2i(0, 2))
	TickEngine.new().resolve(ms, p0, _plan(ms, 1))
	_check(not ms.wires.has(Vector2i(0, 20)), "Spider wire can't be strung across the map")
	_check(ms.wires.has(Vector2i(0, 2)), "Spider wire in range still deploys")


func _test_fogged_wires() -> void:
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 1)
	# One wire per team on a hex the other team can't see (spawns are random).
	var seen := [Visibility.visible_hexes(ms, 0), Visibility.visible_hexes(ms, 1)]
	var hidden := [Vector2i.ZERO, Vector2i.ZERO]   # hidden[t]: a hex team t can't see
	var found := [false, false]
	var keys: Array = ms.tiles.keys()
	keys.sort()
	for hex in keys:
		for t in 2:
			if not found[t] and not seen[t].has(hex) and ms.floor_legal(hex, 0) 					and not (found[1 - t] and hidden[1 - t] == hex):
				hidden[t] = hex
				found[t] = true
	ms.wires[hidden[0]] = 1   # team 1's wire, out of team 0's sight
	ms.wires[hidden[1]] = 0   # team 0's wire, out of team 1's sight
	var view0: Array = Visibility.encode_view(ms, 0, 1, true)["wires"]
	var view1: Array = Visibility.encode_view(ms, 1, 1, true)["wires"]
	_check(view0.size() == 1 and int(view0[0][2]) == 0, "enemy wires out of sight are not sent")
	_check(view1.size() == 1 and int(view1[0][2]) == 1, "each side gets only its own unseen wires")
	var sighted: Array = Visibility.encode_view(ms, 0, 1, false)["wires"]
	_check(sighted.size() == 2, "without fogging every wire is listed (local play)")


func _test_names() -> void:
	_check(NameRules.clean("  A  [b]x[/b]\n<i>" + char(0x202E) + " ") == "A bx/bi", "names lose markup and control characters")
	_check(not NameRules.is_clean("[url=x]y[/url]", 20) and NameRules.is_clean("Kuga 2", 20), "markup is not a clean name")
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	squad[0]["name"] = "[img]res://icon.svg[/img]"
	_check(PlanCodec.validate_squad(squad) != "", "squad with a markup unit name is rejected")
	squad[0]["name"] = "x".repeat(4000)
	_check(PlanCodec.validate_squad(squad) != "", "squad with an oversized unit name is rejected")
	squad[0]["name"] = { "a": 1 }
	_check(PlanCodec.validate_squad(squad) != "", "squad with a non-text unit name is rejected")
	squad = PlanCodec.encode_squad(TriggerLibrary.sample_units())
	squad[0]["main"] = [null, null, null, null, null, null, null, null, null]
	_check(PlanCodec.validate_squad(squad) != "", "oversized slot arrays are rejected")
	squad[0]["main"] = [{ "x": 1 }]
	_check(PlanCodec.validate_squad(squad) != "", "non-text trigger names are rejected")


func _test_plan_numbers() -> void:
	var units := TriggerLibrary.sample_units()
	var base := PlanCodec.encode_plan(TurnPlan.new(units))
	for bad in [[1e300, 0], [0.5, 0], [2000000000, 0], ["1", 2], [0, null]]:
		var plan: Dictionary = base.duplicate(true)
		plan["units"][0][0]["main"] = "Move"
		plan["units"][0][0]["target"] = bad
		_check(str(PlanCodec.decode_plan_checked(plan, units)["error"]) != "", "plan target %s is rejected" % str(bad))
	var floor_plan: Dictionary = base.duplicate(true)
	floor_plan["units"][0][0]["target"] = [0, 0]
	floor_plan["units"][0][0]["target_floor"] = 1e18
	_check(str(PlanCodec.decode_plan_checked(floor_plan, units)["error"]) != "", "absurd target floor is rejected")
	var card_plan: Dictionary = base.duplicate(true)
	card_plan["units"][0][0]["main"] = ["Move"]
	_check(str(PlanCodec.decode_plan_checked(card_plan, units)["error"]) != "", "non-text card is rejected")


func _test_secret_compare() -> void:
	_check(MatchServer._same("abc", "abc") and not MatchServer._same("abc", "abd")
		and not MatchServer._same("abc", "abcd") and not MatchServer._same("", "a"), "constant-time compare is exact")
	_check(MatchServer._int([], 7) == 7 and MatchServer._int({}, 7) == 7 and MatchServer._int("12", 0) == 12
		and MatchServer._int(1e300, 3) == 3 and MatchServer._int(4.0, 0) == 4, "untrusted numbers are read safely")


# --- Server -------------------------------------------------------------------

func _test_http_surface() -> void:
	var b := _backend()
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var created := await b.request("POST", "/match/create", { "squad": squad, "seed": 1 })
	var id := str(created["body"]["match_id"])
	var token0 := str(created["body"]["token"])
	var joined := await b.join_match(id, squad)
	var token1 := str(joined["body"]["token"])
	_check(not joined["body"].has("seed"), "join does not reveal the match seed")
	_check(int(_server._matches[id]["seed"]) != 1, "the server ignores a client-chosen seed")

	var mine := await b.get_match(id, token0)
	_check(int(mine["body"].get("team", -1)) == 0 and mine["body"].has("view"), "bearer token authorizes the player view")
	_check(not mine["body"].has("seed") and not JSON.stringify(mine["body"]).contains("rng"), "player view carries no seed or RNG state")
	_check(not JSON.stringify(mine["body"]).contains(token1), "player view never contains the opponent's token")

	var in_url := await b.request("GET", "/match/%s?token=%s" % [id, token0])
	_check(in_url.get("success", false) and not in_url["body"].has("team"), "a token in the URL is ignored")

	# Radar offsets can't be reproduced from public values.
	var m: Dictionary = _server._matches[id]
	_check(_server._radar_salt(m, 15) != 15 and _server._radar_salt(m, 15) == _server._radar_salt(m, 15)
		and _server._radar_salt(m, 15) != _server._radar_salt(m, 16), "radar salt is keyed per match and stable per tick")
	var other := m.duplicate()
	other["radar_key"] = int(m["radar_key"]) + 1
	_check(_server._radar_salt(m, 15) != _server._radar_salt(other, 15), "radar salt differs between matches")

	var plan := PlanCodec.encode_plan(TurnPlan.new(TriggerLibrary.sample_units()))
	var no_turn := await b.request("POST", "/match/%s/submit" % id, { "token": token0, "plan": plan })
	_check(int(no_turn.get("status", 0)) == 409, "a submit without a turn number is refused")

	# Wrongly typed fields are client errors, never server errors.
	for body in [{ "squad": 5 }, { "squad": [1, 2, 3, 4] }, { "squad": squad, "mode": [] }]:
		var res := await b.request("POST", "/match/create", body)
		_check(int(res.get("status", 0)) in [200, 400], "malformed create %s is handled" % str(body).left(30))
	for body in [{ "token": token0, "turn": [], "plan": plan }, { "token": token0, "turn": 1, "plan": [] },
			{ "token": token0, "turn": 1, "plan": { "units": [1, 2, 3, 4] } }, { "token": {}, "turn": 1, "plan": plan }]:
		var res := await b.request("POST", "/match/%s/submit" % id, body)
		_check(int(res.get("status", 0)) in [400, 403, 409], "malformed submit is refused cleanly (%d)" % int(res.get("status", 0)))

	var far_plan: Dictionary = plan.duplicate(true)
	far_plan["units"][0][0]["main"] = "Look"
	far_plan["units"][0][0]["target"] = [2000000000, 0]
	var far := await b.submit_plan(id, token0, 1, far_plan)
	_check(int(far.get("status", 0)) == 400, "a plan with an absurd target is refused")

	var raw := await _raw("DELETE /match/%s HTTP/1.1\r\nHost: x\r\n\r\n" % id)
	_check(raw.begins_with("HTTP/1.1 405"), "unexpected HTTP methods are refused")
	raw = await _raw("POST /account/register HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n[1,2]")
	_check(raw.begins_with("HTTP/1.1 400"), "a non-object JSON body is refused")
	raw = await _raw("GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
	_check(raw.contains("Cache-Control: no-store") and raw.contains("nosniff"), "responses carry no-store / nosniff headers")


func _test_accounts_and_resume() -> void:
	var b := _backend()
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var bad_name := await b.register_account("[color=red]x")
	_check(str(bad_name["body"].get("name", "")) == "color=redx", "account names are stripped of markup")
	var not_text := await b.request("POST", "/account/register", { "name": ["a"] })
	_check(int(not_text.get("status", 0)) == 400, "non-text account names are refused")

	var a: Dictionary = (await b.register_account("Alpha"))["body"]
	var c: Dictionary = (await b.register_account("Bravo"))["body"]
	var stored: Dictionary = _server._accounts[a["player_id"]]
	_check(not stored.has("secret") and not JSON.stringify(stored).contains(str(a["secret"])),
		"account secrets are stored only as a hash")
	_check(not JSON.stringify((await b.get_account(a["player_id"]))["body"]).contains("secret"),
		"public profile exposes no secret material")

	var q0 := await b.queue_ranked(a["player_id"], a["secret"], squad, "live")
	await b.queue_ranked(c["player_id"], c["secret"], squad, "live")
	var polled := await b.poll_queue(str(q0["body"]["ticket"]), a["secret"])
	_check(str(polled["body"].get("status", "")) == "matched", "queue poll works with a bearer secret")
	var in_url := await b.request("GET", "/queue/%s?secret=%s" % [q0["body"]["ticket"], a["secret"]])
	_check(int(in_url.get("status", 0)) == 404, "a secret in the URL is ignored")

	var resume := await b.active_matches(a["player_id"], a["secret"])
	var list: Array = resume["body"].get("matches", [])
	_check(list.size() == 1 and str(list[0]["token"]) == str(polled["body"]["token"]), "a player can recover their running match")
	var forged := await b.active_matches(a["player_id"], c["secret"])
	_check(int(forged.get("status", 0)) == 403, "resume needs the account's own secret")
	var again := await b.queue_ranked(a["player_id"], a["secret"], squad, "live")
	_check(int(again.get("status", 0)) == 409 and str(again["body"].get("active", {}).get("match_id", "")) == str(polled["body"]["match_id"]),
		"queueing while in a live match returns that match")


func _test_limits() -> void:
	var ip := "203.0.113.77"
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var last := 200
	for i in MatchServer.LIMIT_REGISTER[0] + 1:
		last = int(_server._handle_request("POST", "/account/register", { "name": "Bot%d" % i }, { "ip": ip })["status"])
	_check(last == 429, "mass account creation from one address is throttled")
	_check(int(_server._handle_request("POST", "/account/register", { "name": "Ok" }, { "ip": "203.0.113.78" })["status"]) == 200,
		"other addresses are unaffected")

	ip = "203.0.113.90"
	for i in MatchServer.LIMIT_AUTH_FAIL[0]:
		_server._handle_request("POST", "/queue", { "player_id": "nobody", "secret": "x", "squad": squad }, { "ip": ip })
	_check(int(_server._handle_request("GET", "/leaderboard", {}, { "ip": ip })["status"]) == 429,
		"repeated failed logins lock the address out for a while")

	_server.admin_key = "k".repeat(32)
	_check(int(_server._handle_request("POST", "/admin/season/reset", { "admin_key": "wrong" }, {})["status"]) == 403,
		"admin endpoint rejects a wrong key")
	_check(int(_server._handle_request("POST", "/admin/season/reset", {}, { "bearer": "k".repeat(32) })["status"]) == 200,
		"admin endpoint accepts the key as a bearer token")
	_server.admin_key = ""
	_check(int(_server._handle_request("POST", "/admin/season/reset", { "admin_key": "" }, {})["status"]) == 403,
		"admin endpoint is off without a key")


## Clients that open connections and never finish their request must not
## slow anyone else down (the server loop is single-threaded and also runs
## every match clock).
func _test_slow_reader() -> void:
	var b := _backend()
	var stalled: Array = []
	for i in 24:
		var p := StreamPeerTCP.new()
		p.connect_to_host("127.0.0.1", PORT)
		stalled.append(p)
	await get_tree().create_timer(0.3).timeout
	for p in stalled:
		(p as StreamPeerTCP).poll()
		(p as StreamPeerTCP).put_data("POST /account/register HTTP/1.1
Host: x
Content-Length: 5000

{".to_utf8_buffer())
	var started := Time.get_ticks_msec()
	var health := await b.health()
	_check(health.get("success", false) and Time.get_ticks_msec() - started < 2000,
		"the server keeps answering while other clients stall")
	for p in stalled:
		(p as StreamPeerTCP).disconnect_from_host()


# --- Helpers ------------------------------------------------------------------

func _backend() -> HttpBackend:
	var b := HttpBackend.new()
	b.server_url = URL
	add_child(b)
	return b


## Sends raw bytes and returns the response text.
func _raw(request: String) -> String:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", PORT)
	var end := Time.get_ticks_msec() + 3000
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < end:
		peer.poll()
		await get_tree().process_frame
	peer.put_data(request.to_utf8_buffer())
	var out := PackedByteArray()
	while Time.get_ticks_msec() < end:
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			out.append_array(peer.get_data(n)[1])
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		await get_tree().process_frame
	return out.get_string_from_utf8()


func _attack(ms: MatchState, card_name: String, target: Vector2i, p1: TurnPlan = null) -> Array[CombatEvent]:
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card(card_name))
	p0.set_target(0, 0, target)
	var engine := TickEngine.new()
	engine.always_hit = true
	return engine.resolve_tick(ms, p0, p1 if p1 != null else _plan(ms, 1), 0)


func _messages(events: Array[CombatEvent]) -> Array:
	var out: Array = []
	for ev in events:
		if ev.actor != null and ev.actor.team == 0:
			out.append(ev.message)
	return out


func _no_enemy_named(events: Array[CombatEvent]) -> bool:
	for ev in events:
		if ev.actor != null and ev.actor.team == 0 and (ev.target != null or ev.message.contains("T1.")):
			return false
	return true


func _match(specs: Array) -> MatchState:
	var ms := MatchState.new(1)
	var teams: Array = [[], []]
	var data := TestUnits.legacy()
	for i in specs.size():
		var spec: Array = specs[i]
		var unit_data: UnitData = data[spec[3]] if spec.size() > 3 else data[i]
		teams[spec[0]].append(UnitState.new(unit_data, spec[0], spec[1], spec[2]))
	for team in 2:
		var typed: Array[UnitState] = []
		typed.assign(teams[team])
		ms.setup_team(team, typed)
	return ms


func _plan(ms: MatchState, team: int) -> TurnPlan:
	var units: Array[UnitData] = []
	for u in ms.teams[team]:
		units.append((u as UnitState).unit_data)
	return TurnPlan.new(units)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
