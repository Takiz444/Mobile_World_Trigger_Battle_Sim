class_name HttpBackend
extends Node
## Godot HTTP client for the match backend (the transport under
## GameConnection). All request helpers are awaitable and return
## {success: bool, status: int, body: Dictionary, error?: String}.
## status 0 means the server was never reached (offline, DNS, timeout).
##
## Each call uses its own HTTPRequest, so calls may overlap. GETs are retried
## on transport failures and 5xx/429 (mobile networks blip); POSTs are not,
## since the server may have applied them.

const TIMEOUT_SEC := 10.0
const GET_RETRY_DELAYS := [0.5, 1.5]

var server_url: String = "http://127.0.0.1:8080"
## Emitted after every request: whether the server answered at all.
signal reachability_changed(reachable: bool)
var _reachable := true


func request(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var out := await _request_once(method, path, body)
	if method == "GET":
		for delay in GET_RETRY_DELAYS:
			var status := int(out.get("status", 0))
			if status != 0 and status != 429 and status < 500:
				break
			await get_tree().create_timer(delay).timeout
			out = await _request_once(method, path, body)
	var reachable := int(out.get("status", 0)) != 0
	if reachable != _reachable:
		_reachable = reachable
		reachability_changed.emit(reachable)
	return out


func _request_once(method: String, path: String, body: Dictionary) -> Dictionary:
	var url := server_url.rstrip("/") + path
	var http_method := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var data := JSON.stringify(body) if not body.is_empty() else ""
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SEC
	add_child(http)
	var err := http.request(url, ["Content-Type: application/json"], http_method, data)
	if err != OK:
		http.queue_free()
		return { "success": false, "status": 0, "body": {}, "error": "request failed (%d)" % err }
	var resp: Array = await http.request_completed
	http.queue_free()
	var result: int = resp[0]
	var code: int = resp[1]
	var resp_body: PackedByteArray = resp[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return { "success": false, "status": 0, "body": {}, "error": "can't reach server (%d)" % result }
	var parsed: Variant = JSON.parse_string(resp_body.get_string_from_utf8())
	var body_out: Dictionary = parsed if parsed is Dictionary else {}
	var out := { "success": code >= 200 and code < 300, "status": code, "body": body_out }
	if not out["success"]:
		out["error"] = str(body_out.get("error", "HTTP %d" % code))
	return out


func health() -> Dictionary:
	return await request("GET", "/health")


func create_match(seed: int, squad: Array) -> Dictionary:
	return await request("POST", "/match/create", { "seed": seed, "squad": squad })


func join_match(match_id: String, squad: Array) -> Dictionary:
	return await request("POST", "/match/%s/join" % match_id, { "squad": squad })


## `token` is the secret returned by create/join; it identifies the team.
func submit_plan(match_id: String, token: String, turn: int, plan: Dictionary) -> Dictionary:
	return await request("POST", "/match/%s/submit" % match_id, { "token": token, "turn": turn, "plan": plan })


# --- Accounts & ranked matchmaking -------------------------------------------

func register_account(player_name: String) -> Dictionary:
	return await request("POST", "/account/register", { "name": player_name })


func get_account(player_id: String) -> Dictionary:
	return await request("GET", "/account/%s" % player_id)


## Permanently deletes the account (required in-app by the App Store).
func delete_account(player_id: String, secret: String) -> Dictionary:
	return await request("POST", "/account/delete", { "player_id": player_id, "secret": secret })


func forfeit(match_id: String, token: String) -> Dictionary:
	return await request("POST", "/match/%s/forfeit" % match_id, { "token": token })


func leaderboard() -> Dictionary:
	return await request("GET", "/leaderboard")


## Joins the ranked queue; the response is either matched or a ticket to poll.
## `mode` is "async" (correspondence) or "live" (trophy ladder).
func queue_ranked(player_id: String, secret: String, squad: Array, mode := "async") -> Dictionary:
	return await request("POST", "/queue", { "player_id": player_id, "secret": secret, "squad": squad, "mode": mode })


func poll_queue(ticket: String, secret: String) -> Dictionary:
	return await request("GET", "/queue/%s?secret=%s" % [ticket, secret.uri_encode()])


func cancel_queue(ticket: String, secret: String) -> Dictionary:
	return await request("POST", "/queue/%s/cancel" % ticket, { "secret": secret })


## With a player token the response includes that team's fogged view,
## replay frames, and own plans; without one only public match info.
func get_match(match_id: String, token: String = "") -> Dictionary:
	var path := "/match/%s" % match_id
	if token != "":
		path += "?token=%s" % token.uri_encode()
	return await request("GET", path)
