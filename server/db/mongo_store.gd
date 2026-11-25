class_name MongoStore
extends GameStore
## MongoDB through the Trion Mongo gateway (deploy/mongo-gateway): Godot has
## no MongoDB driver, so a small Node service with the official driver turns
## the store's few operations into HTTP. Each kind is a collection and each
## record a document {_id: <id>, ...record}, so the data is easy to query in
## the Mongo shell or Atlas (e.g. db.accounts.find({email: "..."})).
##
## Gateway API (all with "Authorization: Bearer <token>"):
##   GET  /health                                       -> {ok}  (pings the database)
##   GET  /records/<kind>?limit=N&after=<id>[&ended_after=<unix>]
##                                                      -> {records: [{id, doc}], next: <id> | null}
##   POST /batch  {ops: [{op: "put" | "delete", kind, id, doc?}]}
##                                                      -> {ok, failed: [{index, error}]}
##
## Writes are write-behind like PostgrestStore: put()/remove() coalesce per
## record, flush() sends one batch at a time (so writes to a record stay in
## order), and a failed batch is retried with backoff through database
## outages. A document the database refuses (reported in `failed`) is logged
## and dropped instead of blocking every later write.
##
## The gateway must only be reachable from the game server (bind it to
## 127.0.0.1, or keep it on the compose network).

const BATCH_MAX := 200
const PAGE_SIZE := 500
const RETRY_DELAYS := [0.5, 1.0, 2.0, 5.0, 10.0]
const TIMEOUT_SEC := 15.0

var base_url: String
var token: String

var _queue: Dictionary = {}       # "kind/id" -> {op, kind, id, doc?}
var _in_flight: Dictionary = {}   # the batch being sent
var _failures := 0
var _retry_at := 0.0


func _init(p_base_url: String, p_token := "") -> void:
	base_url = p_base_url.rstrip("/")
	token = p_token


func describe() -> String:
	return "mongo via %s" % base_url


func open() -> bool:
	if base_url == "":
		push_error("TT_MONGO_GATEWAY_URL is not set")
		return false
	var res := await _http(HTTPClient.METHOD_GET, "/health")
	if not res["ok"]:
		push_error("Mongo gateway at %s is not usable: %s" % [base_url, res["error"]])
	return res["ok"]


func load_all(match_cutoff: float) -> Dictionary:
	var out := GameStore._empty()
	for kind in GameStore.KINDS:
		var filter := "&ended_after=%f" % match_cutoff if kind == "matches" else ""
		var after := ""
		while true:
			var path := "/records/%s?limit=%d%s" % [kind, PAGE_SIZE, filter]
			if after != "":
				path += "&after=%s" % after.uri_encode()
			var res := await _http(HTTPClient.METHOD_GET, path)
			var body: Variant = res["body"]
			if not res["ok"] or not (body is Dictionary) or not (body.get("records") is Array):
				push_error("Loading %s failed: %s" % [kind, res.get("error", "bad response")])
				break
			for row in body["records"]:
				if row is Dictionary and row.get("doc") is Dictionary:
					out[kind][str(row["id"])] = row["doc"]
			var next: Variant = body.get("next")
			if not (next is String) or next == "":
				break
			after = next
	return out


func put(kind: String, id: String, record: Dictionary) -> void:
	if GameStore.valid_id(id):
		_queue["%s/%s" % [kind, id]] = { "op": "put", "kind": kind, "id": id, "doc": record.duplicate(true) }


func remove(kind: String, id: String) -> void:
	if GameStore.valid_id(id):
		_queue["%s/%s" % [kind, id]] = { "op": "delete", "kind": kind, "id": id }


func flush() -> void:
	if not _in_flight.is_empty() or _queue.is_empty():
		return
	if Time.get_ticks_msec() / 1000.0 < _retry_at:
		return
	for key in _queue.keys():
		if _in_flight.size() >= BATCH_MAX:
			break
		_in_flight[key] = _queue[key]
		_queue.erase(key)
	_send_batch()


func pending() -> int:
	return _queue.size() + _in_flight.size()


func _process(_delta: float) -> void:
	# Keep draining between server flushes (retries, batches over BATCH_MAX).
	if not _queue.is_empty():
		flush()


func _send_batch() -> void:
	var keys := _in_flight.keys()
	var ops: Array = []
	for key in keys:
		ops.append(_in_flight[key])
	var res := await _http(HTTPClient.METHOD_POST, "/batch", { "ops": ops })
	if res["ok"]:
		_failures = 0
		var failed: Variant = res["body"].get("failed", []) if res["body"] is Dictionary else []
		for f in (failed if failed is Array else []):
			var i := int(f.get("index", -1)) if f is Dictionary else -1
			if i >= 0 and i < keys.size():
				push_error("Mongo refused %s: %s (dropped)" % [keys[i], str(f.get("error", "?"))])
		_in_flight.clear()
		return
	# Requeue the whole batch, except records with a newer version queued.
	for key in keys:
		if not _queue.has(key):
			_queue[key] = _in_flight[key]
	_in_flight.clear()
	var delay: float = RETRY_DELAYS[mini(_failures, RETRY_DELAYS.size() - 1)]
	_failures += 1
	_retry_at = Time.get_ticks_msec() / 1000.0 + delay
	push_warning("Mongo batch of %d failed (%s); retrying in %.1fs" % [keys.size(), res["error"], delay])


## One HTTP request -> {ok, status, body, error}.
func _http(method: int, path: String, body: Variant = null) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT_SEC
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if token != "":
		headers.append("Authorization: Bearer %s" % token)
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
