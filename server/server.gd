class_name MatchServer
extends Node
## Headless backend: JSON REST API + server-authoritative deterministic turn
## resolution (GDD Phase 3) with server-enforced fog of war.
##
## Run:
##   godot --headless --path . res://server/server.tscn
## Env vars:
##   TT_PORT              port to listen on (default 8080)
##   TT_TURN_TIMEOUT_SEC  turn timer before auto-fill (default 12h, GDD 3.1)
##   TT_DATA_FILE         where matches are persisted (default user://matches.json)
##
## Endpoints:
##   GET  /health
##   POST /match/create      {seed, squad}            -> {match_id, team, token}
##   POST /match/{id}/join   {squad}                  -> {status, seed, team, token}
##   POST /match/{id}/submit {token, turn, plan}
##   GET  /match/{id}?token=<token>
##
## Each player receives a secret token on create/join. Submissions are
## attributed to a team by token only, and GET returns only what that team
## may know (Visibility): its own units, enemies in sight, radar pings for
## the rest, and per-tick replay frames filtered the same way. The opponent's
## plans and the full match state never leave the server.

const DEFAULT_PORT := 8080
const DEFAULT_TURN_TIMEOUT_SEC := 12 * 60 * 60  # auto-fill deadline (GDD 3.1)
const DEFAULT_DATA_FILE := "user://matches.json"

## Set false before adding to the tree to disable disk persistence (tests).
var persist := true
var turn_timeout_sec := DEFAULT_TURN_TIMEOUT_SEC
var data_file := DEFAULT_DATA_FILE

var _http := HttpServer.new()
var _matches: Dictionary = {}     # id -> match dict
var _crypto := Crypto.new()


func _ready() -> void:
	var port := DEFAULT_PORT
	var env := OS.get_environment("TT_PORT")
	if env != "":
		port = int(env)
	var timeout_env := OS.get_environment("TT_TURN_TIMEOUT_SEC")
	if timeout_env != "":
		turn_timeout_sec = int(timeout_env)
	var file_env := OS.get_environment("TT_DATA_FILE")
	if file_env != "":
		data_file = file_env
	if persist:
		_load()
	var ok := _http.start(port, _handle_request)
	print("Trion Tactics server listening on :%d (start=%s, turn timeout %ds, %d matches loaded)" % [
		port, ok, turn_timeout_sec, _matches.size()])


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
		return _get_match(_path_id(path), str(body.get("token", "")))
	return _err(404, "not found")


func _path_id(path: String) -> String:
	# split(..., false) drops the leading empty segment: "/match/<id>/join"
	# becomes ["match", "<id>", "join"].
	var parts := path.split("/", false)
	return parts[1] if parts.size() > 1 else ""


# --- Endpoints --------------------------------------------------------------

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
		"turn_started": -1.0,
		"winner": -1,
		"history": [],
	}
	_save()
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
	m["turn_started"] = Time.get_unix_time_from_system()
	_save()
	return _ok({ "status": "ready", "seed": m["seed"], "team": 1, "token": token })


func _submit(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var team := _team_for_token(m, str(body.get("token", "")))
	if team == -1:
		return _err(403, "invalid token")
	if int(m["winner"]) != -1:
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
		_save()
		return _ok({ "status": "resolved", "result": _result_for(m, team) })
	_save()
	return _ok({ "status": "pending" })


## Public info for anyone; the fogged board, replay frames, and own plans
## only for a valid player token.
func _get_match(id: String, token: String) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var body := {
		"id": id,
		"turn": m["turn"],
		"ready": m["ms"] != null,
		"submitted": m["submitted"],
		"winner": m["winner"],
	}
	var team := _team_for_token(m, token)
	if team == -1:
		return _ok(body)
	body["team"] = team
	body["seed"] = m["seed"]
	body["teams"] = [
		PlanCodec.encode_squad(m["teams"][0]) if m["teams"][0] != null else null,
		PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
	]
	if m["ms"] != null:
		body["view"] = Visibility.encode_view(m["ms"], team, _view_salt(int(m["turn"])))
	var history: Array = []
	for entry in m["history"]:
		history.append(_filter_entry(entry, team))
	body["history"] = history
	body["result"] = history.back() if not history.is_empty() else null
	return _ok(body)


# --- Resolution -------------------------------------------------------------

## Resolves the turn tick by tick, recording a fog-filtered replay frame per
## tick for each team.
func _resolve_turn(m: Dictionary) -> void:
	var ms: MatchState = m["ms"]
	var turn := int(m["turn"])
	var engine := TickEngine.new()
	var frames: Array = [[], []]
	for tick in TurnPlan.TICKS_PER_TURN:
		var events := engine.resolve_tick(ms, m["plans"][0], m["plans"][1], tick)
		for team in 2:
			var states := Visibility.enemy_states(ms, team)
			var seen: Array[CombatEvent] = []
			for ev in events:
				if Visibility.event_visible(ev, team, states):
					seen.append(ev)
			frames[team].append({
				"tick": tick,
				"events": PlanCodec.encode_events(seen),
				"view": Visibility.encode_view(ms, team, turn * 10 + tick),
			})
	var winner := MatchRunner.winner(ms)
	m["history"].append({
		"turn": turn,
		"winner": winner,
		"plans": [PlanCodec.encode_plan(m["plans"][0]), PlanCodec.encode_plan(m["plans"][1])],
		"frames": frames,
	})
	if winner != -1:
		m["winner"] = winner
	else:
		m["turn"] = turn + 1
	m["plans"] = [null, null]
	m["submitted"] = [false, false]
	m["turn_started"] = Time.get_unix_time_from_system()


## A history entry as `team` may see it: its own plan and its own frames.
func _filter_entry(entry: Dictionary, team: int) -> Dictionary:
	return {
		"turn": entry["turn"],
		"winner": entry["winner"],
		"plan": entry["plans"][team],
		"frames": entry["frames"][team],
	}


func _result_for(m: Dictionary, team: int) -> Variant:
	if m["history"].is_empty():
		return null
	return _filter_entry(m["history"].back(), team)


## Radar salt for the planning-phase view. Matches the last replay frame of
## the previous turn (turn * 10 + 5) so pings don't jump between the two.
func _view_salt(turn: int) -> int:
	return turn * 10 - 5


func _check_timeouts() -> void:
	var now := Time.get_unix_time_from_system()
	for id in _matches.keys():
		var m: Dictionary = _matches[id]
		if int(m["winner"]) != -1 or m["ms"] == null or float(m["turn_started"]) < 0.0:
			continue
		if now - float(m["turn_started"]) < turn_timeout_sec:
			continue
		for team in 2:
			if not bool(m["submitted"][team]):
				m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
				m["submitted"][team] = true
		_resolve_turn(m)
		_save()
		print("Timeout auto-resolved match %s" % id)


# --- Persistence ------------------------------------------------------------

func _save() -> void:
	if not persist:
		return
	var out := {}
	for id in _matches:
		out[id] = _serialize(_matches[id])
	var f := FileAccess.open(data_file, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [data_file, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(out))


func _load() -> void:
	if not FileAccess.file_exists(data_file):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(data_file))
	if not (parsed is Dictionary):
		push_warning("Ignoring unreadable match store %s" % data_file)
		return
	for id in parsed:
		_matches[id] = _deserialize(parsed[id])


func _serialize(m: Dictionary) -> Dictionary:
	var plans: Array = []
	for p in m["plans"]:
		plans.append(PlanCodec.encode_plan(p) if p != null else null)
	return {
		"id": m["id"],
		"seed": m["seed"],
		"turn": m["turn"],
		"squads": [
			PlanCodec.encode_squad(m["teams"][0]),
			PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
		],
		"tokens": m["tokens"],
		"plans": plans,
		"submitted": m["submitted"],
		"turn_started": m["turn_started"],
		"winner": m["winner"],
		"history": m["history"],
		"state": PlanCodec.encode_state(m["ms"]) if m["ms"] != null else null,
	}


func _deserialize(d: Dictionary) -> Dictionary:
	var squads: Array = d["squads"]
	var teams: Array = [
		PlanCodec.decode_squad(squads[0]),
		PlanCodec.decode_squad(squads[1]) if squads[1] != null else null,
	]
	var seed := int(d["seed"])
	var ms: MatchState = null
	if teams[1] != null:
		ms = MatchRunner.build_match(teams[0], teams[1], seed)
		if d.get("state") is Dictionary:
			PlanCodec.apply_state(ms, d["state"])
	var plans: Array = [null, null]
	for team in 2:
		var p: Variant = d["plans"][team]
		if p is Dictionary and teams[team] != null:
			plans[team] = PlanCodec.decode_plan(p, teams[team])
	return {
		"id": str(d["id"]),
		"seed": seed,
		"turn": int(d["turn"]),
		"teams": teams,
		"tokens": [str(d["tokens"][0]), str(d["tokens"][1])],
		"ms": ms,
		"plans": plans,
		"submitted": [bool(d["submitted"][0]), bool(d["submitted"][1])],
		"turn_started": float(d["turn_started"]),
		"winner": int(d["winner"]),
		"history": d["history"],
	}


# --- Helpers ----------------------------------------------------------------

func _team_for_token(m: Dictionary, token: String) -> int:
	if token == "":
		return -1
	return m["tokens"].find(token)


func _new_id() -> String:
	return _crypto.generate_random_bytes(6).hex_encode()


func _new_token() -> String:
	return _crypto.generate_random_bytes(16).hex_encode()


func _ok(body: Dictionary) -> Dictionary:
	return { "status": 200, "body": body }


func _err(status: int, msg: String) -> Dictionary:
	return { "status": status, "body": { "error": msg } }
