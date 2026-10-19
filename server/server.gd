class_name MatchServer
extends Node
## Headless backend: JSON REST API + server-authoritative deterministic turn
## resolution (GDD Phase 3).
##
## Run:
##   godot --headless --path . res://server/server.tscn
## Env vars:
##   TT_PORT              port to listen on (default 8080)
##   TT_TURN_TIMEOUT_SEC  turn timer before auto-fill (default 12h, GDD 3.1)
##
## Endpoints:
##   GET  /health
##   POST /match/create      {seed, squad}            -> {match_id, team, token}
##   POST /match/{id}/join   {squad}                  -> {status, seed, team, token}
##   POST /match/{id}/submit {token, turn, plan}
##   GET  /match/{id}
##
## Each player receives a secret token on create/join; submissions are
## attributed to a team by token only, so nobody can play the other side.

const DEFAULT_PORT := 8080
const DEFAULT_TURN_TIMEOUT_SEC := 12 * 60 * 60  # auto-fill deadline (GDD 3.1)

var turn_timeout_msec := DEFAULT_TURN_TIMEOUT_SEC * 1000

var _http := HttpServer.new()
var _matches: Dictionary = {}     # id -> match dict
var _counter := 0
var _crypto := Crypto.new()


func _ready() -> void:
	var port := DEFAULT_PORT
	var env := OS.get_environment("TT_PORT")
	if env != "":
		port = int(env)
	var timeout_env := OS.get_environment("TT_TURN_TIMEOUT_SEC")
	if timeout_env != "":
		turn_timeout_msec = int(timeout_env) * 1000
	var ok := _http.start(port, _handle_request)
	print("Trion Tactics server listening on :%d (start=%s, turn timeout %ds)" % [port, ok, turn_timeout_msec / 1000])


func _process(_delta: float) -> void:
	_http.poll()
	_check_timeouts()


func _handle_request(method: String, path: String, body: Dictionary) -> Dictionary:
	if method == "GET" and path == "/health":
		return _ok({ "ok": true, "matches": _matches.size() })
	if method == "POST" and path == "/match/create":
		return _create_match(body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/join"):
		return _join_match(_path_id(path), body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/submit"):
		return _submit(_path_id(path), body)
	if method == "GET" and path.begins_with("/match/") and path.split("/", false).size() == 2:
		return _get_match(_path_id(path))
	return _err(404, "not found")


func _path_id(path: String) -> String:
	# split(..., false) drops the leading empty segment: "/match/<id>/join"
	# becomes ["match", "<id>", "join"].
	var parts := path.split("/", false)
	return parts[1] if parts.size() > 1 else ""


func _create_match(body: Dictionary) -> Dictionary:
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)
	var seed := int(body.get("seed", MatchRunner.DEFAULT_SEED))
	var id := _new_id()
	var token := _new_token()
	_matches[id] = {
		"id": id,
		"seed": seed,
		"turn": 1,
		"teams": [PlanCodec.decode_squad(squad), null],
		"tokens": [token, ""],
		"ms": null,
		"plans": [null, null],
		"submitted": [false, false],
		"turn_started": -1,
		"winner": -1,
		"result": null,
		"history": [],
	}
	return _ok({ "match_id": id, "team": 0, "token": token })


func _join_match(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	if m["teams"][1] != null:
		return _err(409, "match already full")
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)
	var token := _new_token()
	m["teams"][1] = PlanCodec.decode_squad(squad)
	m["tokens"][1] = token
	m["ms"] = MatchRunner.build_match(m["teams"][0], m["teams"][1], m["seed"])
	m["turn_started"] = Time.get_ticks_msec()
	return _ok({ "status": "ready", "seed": m["seed"], "team": 1, "token": token })


func _submit(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var team: int = m["tokens"].find(str(body.get("token", "")))
	if team == -1 or str(body.get("token", "")) == "":
		return _err(403, "invalid token")
	if m["winner"] != -1:
		return _err(409, "match over")
	if m["ms"] == null:
		return _err(409, "match not ready (waiting for opponent)")
	if body.get("turn") != null and int(body["turn"]) != int(m["turn"]):
		return _err(409, "stale turn (server is on turn %d)" % int(m["turn"]))
	if bool(m["submitted"][team]):
		return _ok({ "status": "pending" })
	var plan_dict: Variant = body.get("plan", {})
	if not (plan_dict is Dictionary):
		return _err(400, "plan required")
	var decoded := PlanCodec.decode_plan_checked(plan_dict, m["teams"][team])
	if str(decoded["error"]) != "":
		return _err(400, "invalid plan: %s" % decoded["error"])
	m["plans"][team] = decoded["plan"]
	m["submitted"][team] = true
	if bool(m["submitted"][0]) and bool(m["submitted"][1]):
		_resolve_turn(m)
		return _ok({ "status": "resolved", "result": m["result"] })
	return _ok({ "status": "pending" })


func _get_match(id: String) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var teams: Array = [
		PlanCodec.encode_squad(m["teams"][0]) if m["teams"][0] != null else null,
		PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
	]
	return _ok({
		"id": id,
		"seed": m["seed"],
		"turn": m["turn"],
		"ready": m["ms"] != null,
		"teams": teams,
		"submitted": m["submitted"],
		"winner": m["winner"],
		"result": m["result"],
		"history": m["history"],
		"state": PlanCodec.encode_state(m["ms"]) if m["ms"] != null else null,
	})


func _resolve_turn(m: Dictionary) -> void:
	var ms: MatchState = m["ms"]
	var events := MatchRunner.resolve_turn(ms, m["plans"][0], m["plans"][1])
	m["result"] = {
		"turn": m["turn"],
		"winner": MatchRunner.winner(ms),
		"plans": [PlanCodec.encode_plan(m["plans"][0]), PlanCodec.encode_plan(m["plans"][1])],
		"events": PlanCodec.encode_events(events),
		"state": PlanCodec.encode_state(ms),
	}
	m["history"].append(m["result"])
	if int(m["result"]["winner"]) != -1:
		m["winner"] = m["result"]["winner"]
	else:
		m["turn"] = int(m["turn"]) + 1
	m["plans"] = [null, null]
	m["submitted"] = [false, false]
	m["turn_started"] = Time.get_ticks_msec()


func _check_timeouts() -> void:
	var now := Time.get_ticks_msec()
	for id in _matches.keys():
		var m: Dictionary = _matches[id]
		if m["winner"] != -1 or m["ms"] == null or int(m["turn_started"]) == -1:
			continue
		if now - int(m["turn_started"]) < turn_timeout_msec:
			continue
		for team in 2:
			if not bool(m["submitted"][team]):
				m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
				m["submitted"][team] = true
		_resolve_turn(m)
		print("Timeout auto-resolved match %s" % id)


func _new_id() -> String:
	_counter += 1
	return "%d_%d" % [Time.get_ticks_msec(), _counter]


func _new_token() -> String:
	return _crypto.generate_random_bytes(16).hex_encode()


func _ok(body: Dictionary) -> Dictionary:
	return { "status": 200, "body": body }


func _err(status: int, msg: String) -> Dictionary:
	return { "status": status, "body": { "error": msg } }
