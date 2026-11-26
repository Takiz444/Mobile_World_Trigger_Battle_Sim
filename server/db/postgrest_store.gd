class_name PostgrestStore
extends GameStore
## Postgres through a PostgREST HTTP API (deploy/db/schema.sql). Godot has
## no Postgres driver, but PostgREST turns each table into a REST endpoint:
##   upsert  POST   /<kind>?on_conflict=id   {id, doc}   Prefer: resolution=merge-duplicates
##   delete  DELETE /<kind>?id=eq.<id>
##   load    GET    /<kind>?select=id,doc&order=id&limit=N&offset=M
##
## Writes are write-behind: put()/remove() coalesce per record (a hot match
## updated every turn only sends its latest version), flush() starts up to
## MAX_IN_FLIGHT requests, and failures are retried with backoff. A crash can
## lose writes still in flight (normally < 1 s); every match is resumable
## from its last written turn.
##
## PostgREST must only be reachable from the game server (deploy compose
## keeps it on the internal network). Set TT_DB_TOKEN when PostgREST is
## configured with a JWT secret; it is sent as a Bearer token.

const MAX_IN_FLIGHT := 8
const PAGE_SIZE := 500
const RETRY_DELAYS := [0.5, 1.0, 2.0, 5.0, 10.0]
const TIMEOUT_SEC := 10.0

var base_url: String
var token: String

var _queue: Dictionary = {}       # "kind/id" -> {kind, id, record (null = delete)}
var _in_flight: Dictionary = {}   # "kind/id" -> op being sent
var _failures := 0
var _retry_at := 0.0


func _init(p_base_url: String, p_token := "") -> void:
	base_url = p_base_url.rstrip("/")
	token = p_token


func describe() -> String:
	return "postgrest %s" % base_url


func open() -> bool:
	if base_url == "":
		push_error("TT_DB_URL is not set")
		return false
	var res := await _http(HTTPClient.METHOD_GET, "/meta?select=id&limit=1")
	if not res["ok"]:
		push_error("PostgREST at %s is not reachable: %s" % [base_url, res["error"]])
	return res["ok"]


func load_all(match_cutoff: float) -> Dictionary:
	var out := GameStore._empty()
	for kind in GameStore.KINDS:
		var filter := ""
		if kind == "matches":
			# Unfinished matches, plus ones that ended inside the retention window.
			filter = "&or=(winner.eq.-1,ended_at.gte.%f)" % match_cutoff
		var offset := 0
		while true:
			var res := await _http(HTTPClient.METHOD_GET,
				"/%s?select=id,doc&order=id&limit=%d&offset=%d%s" % [kind, PAGE_SIZE, offset, filter])
			if not res["ok"] or not (res["body"] is Array):
				push_error("Loading %s failed: %s" % [kind, res.get("error", "bad response")])
				break
			for row in res["body"]:
				if row is Dictionary and row.get("doc") is Dictionary:
					out[kind][str(row["id"])] = row["doc"]
			if (res["body"] as Array).size() < PAGE_SIZE:
				break
			offset += PAGE_SIZE
	return out


func put(kind: String, id: String, record: Dictionary) -> void:
	if GameStore.valid_id(id):
		_queue["%s/%s" % [kind, id]] = { "kind": kind, "id": id, "record": record.duplicate(true) }


func remove(kind: String, id: String) -> void:
	if GameStore.valid_id(id):
		_queue["%s/%s" % [kind, id]] = { "kind": kind, "id": id, "record": null }


func flush() -> void:
	if Time.get_ticks_msec() / 1000.0 < _retry_at:
		return
	for key in _queue.keys():
		if _in_flight.size() >= MAX_IN_FLIGHT:
			break
		# One request per record at a time keeps writes to it in order.
		if _in_flight.has(key):
			continue
		var op: Dictionary = _queue[key]
		_queue.erase(key)
		_in_flight[key] = op
		_send(key, op)


func pending() -> int:
	return _queue.size() + _in_flight.size()


func _process(_delta: float) -> void:
	# Keep draining between server flushes (retries, MAX_IN_FLIGHT overflow).
	if not _queue.is_empty():
		flush()


func _send(key: String, op: Dictionary) -> void:
	var res: Dictionary
	if op["record"] == null:
		res = await _http(HTTPClient.METHOD_DELETE, "/%s?id=eq.%s" % [op["kind"], op["id"]])
	else:
		res = await _http(HTTPClient.METHOD_POST, "/%s?on_conflict=id" % op["kind"],
			{ "id": op["id"], "doc": op["record"] },
			["Prefer: resolution=merge-duplicates,return=minimal"])
	_in_flight.erase(key)
	if res["ok"]:
		_failures = 0
		return
	# Requeue unless a newer version of the record was queued meanwhile.
	if not _queue.has(key):
		_queue[key] = op
	var delay: float = RETRY_DELAYS[mini(_failures, RETRY_DELAYS.size() - 1)]
	_failures += 1
	_retry_at = Time.get_ticks_msec() / 1000.0 + delay
	push_warning("Store write %s failed (%s); retrying in %.1fs" % [key, res["error"], delay])


## One HTTP request -> {ok, status, body, error}. Uses a fresh HTTPRequest so
## requests run concurrently.
func _http(method: int, path: String, body: Variant = null, extra_headers: Array = []) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT_SEC
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if token != "":
		headers.append("Authorization: Bearer %s" % token)
	for h in extra_headers:
		headers.append(h)
	var data := JSON.stringify(body) if body != null else ""
	var err := req.request(base_url + path, headers, method, data)
	if err != OK:
		req.queue_free()
		return { "ok": false, "status": 0, "body": null, "error": "request failed (%d)" % err }
	var resp: Array = await req.request_completed
	req.queue_free()
	var code: int = resp[1]
	var text: String = (resp[3] as PackedByteArray).get_string_from_utf8()
	if resp[0] != HTTPRequest.RESULT_SUCCESS:
		return { "ok": false, "status": 0, "body": null, "error": "transport error %d" % resp[0] }
	var parsed: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
	if code < 200 or code >= 300:
		return { "ok": false, "status": code, "body": parsed, "error": "HTTP %d %s" % [code, text.left(200)] }
	return { "ok": true, "status": code, "body": parsed, "error": "" }
