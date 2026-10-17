class_name MatchServer
extends Node
## Headless backend: JSON REST API + server-authoritative deterministic turn
## resolution (GDD Phase 3).
##
## Run:
##   godot --headless --path . res://server/server.tscn
## (optional: set TT_PORT env var to override the port)
##
## Endpoints:
##   GET  /health
##   POST /match/create      {seed, squad}
##   POST /match/{id}/join   {squad}
##   POST /match/{id}/submit {team, plan}
##   GET  /match/{id}

const DEFAULT_PORT := 8080
const TURN_TIMEOUT_MSEC := 60000  # auto-fill deadline (GDD 3.1)

var _http := HttpServer.new()
var _matches: Dictionary = {}     # id -> match dict
var _counter := 0


func _ready() -> void:
	var port := DEFAULT_PORT
	var env := OS.get_environment("TT_PORT")
	if env != "":
		port = int(env)
	var ok := _http.start(port, _handle_request)
	print("Trion Tactics server listening on :%d (start=%s)" % [port, ok])


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
	if method == "GET" and path.begins_with("/match/"):
		return _get_match(_path_id(path))
	return _err(404, "not found")


func _path_id(path: String) -> String:
	# split(..., false) drops the leading empty segment: "/match/<id>/join"
	# becomes ["match", "<id>", "join"].
	var parts := path.split("/", false)
	return parts[1] if parts.size() > 1 else ""


func _create_match(body: Dictionary) -> Dictionary:
	var squad: Array = body.get("squad", [])
	if squad.is_empty():
		return _err(400, "squad required")
	var seed := int(body.get("seed", MatchRunner.DEFAULT_SEED))
	var id := _new_id()
	_matches[id] = {
		"id": id,
		"seed": seed,
		"turn": 1,
		"teams": [PlanCodec.decode_squad(squad), null],
		"ms": null,
		"plans": [null, null],
		"submitted": [false, false],
		"pending_since": -1,
		"winner": -1,
		"result": null,
	}
	return _ok({ "match_id": id, "team": 0 })


func _join_match(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	if m["teams"][1] != null:
		return _err(400, "match already full")
	var squad: Array = body.get("squad", [])
	if squad.is_empty():
		return _err(400, "squad required")
	m["teams"][1] = PlanCodec.decode_squad(squad)
	m["ms"] = MatchRunner.build_match(m["teams"][0], m["teams"][1], m["seed"])
	return _ok({ "status": "ready", "seed": m["seed"] })


func _submit(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	if m["winner"] != -1:
		return _err(400, "match over")
	if m["ms"] == null:
		return _err(400, "match not ready (waiting for opponent)")
	var team := int(body.get("team", -1))
	if team != 0 and team != 1:
		return _err(400, "invalid team")
	if bool(m["submitted"][team]):
		return _ok({ "status": "pending" })
	var plan_dict: Dictionary = body.get("plan", {})
	m["plans"][team] = PlanCodec.decode_plan(plan_dict, m["teams"][team])
	m["submitted"][team] = true
	if int(m["pending_since"]) == -1:
		m["pending_since"] = Time.get_ticks_msec()
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
	})


func _resolve_turn(m: Dictionary) -> void:
	var ms: MatchState = m["ms"]
	var events := MatchRunner.resolve_turn(ms, m["plans"][0], m["plans"][1])
	m["result"] = {
		"turn": m["turn"],
		"winner": MatchRunner.winner(ms),
		"plans": [PlanCodec.encode_plan(m["plans"][0]), PlanCodec.encode_plan(m["plans"][1])],
		"events": PlanCodec.encode_events(events),
	}
	if int(m["result"]["winner"]) != -1:
		m["winner"] = m["result"]["winner"]
	else:
		m["turn"] = int(m["turn"]) + 1
	m["plans"] = [null, null]
	m["submitted"] = [false, false]
	m["pending_since"] = -1


func _check_timeouts() -> void:
	var now := Time.get_ticks_msec()
	for id in _matches.keys():
		var m: Dictionary = _matches[id]
		if m["winner"] != -1 or m["ms"] == null or int(m["pending_since"]) == -1:
			continue
		if now - int(m["pending_since"]) < TURN_TIMEOUT_MSEC:
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


func _ok(body: Dictionary) -> Dictionary:
	return { "status": 200, "body": body }


func _err(status: int, msg: String) -> Dictionary:
	return { "status": status, "body": { "error": msg } }
