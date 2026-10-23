class_name HttpBackend
extends Node
## Godot HTTP client for the async match backend. All request helpers are
## awaitable and return {success: bool, status: int, body: Dictionary}.

var server_url: String = "http://127.0.0.1:8080"
var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)


func request(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var url := server_url.rstrip("/") + path
	var http_method := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var data := JSON.stringify(body) if not body.is_empty() else ""
	var err := _http.request(url, ["Content-Type: application/json"], http_method, data)
	if err != OK:
		return { "success": false, "error": "request failed (%d)" % err }
	var resp: Array = await _http.request_completed
	var result: int = resp[0]
	var code: int = resp[1]
	var resp_body: PackedByteArray = resp[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return { "success": false, "error": "HTTP error %d" % result }
	var parsed: Variant = JSON.parse_string(resp_body.get_string_from_utf8())
	var body_out: Dictionary = parsed if parsed is Dictionary else {}
	var out := { "success": code >= 200 and code < 300, "status": code, "body": body_out }
	if not out["success"]:
		out["error"] = str(body_out.get("error", "HTTP %d" % code))
	return out


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
