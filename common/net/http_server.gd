class_name HttpServer
extends RefCounted
## Minimal HTTP/1.1 server for the headless backend. Accepts connections via a
## TCPServer, buffers each request, and dispatches (method, path, body) to a
## handler Callable that returns {"status": int, "body": Variant}.
##
## Public-internet hardening:
##   - request size caps (headers MAX_HEADER_BYTES, body MAX_BODY_BYTES)
##   - connections that don't finish a request in REQUEST_TIMEOUT_MS are dropped
##   - per-client token-bucket rate limit (429). Behind a reverse proxy set
##     trust_proxy so the client IP comes from X-Forwarded-For; otherwise every
##     player would share the proxy's bucket.

const MAX_HEADER_BYTES := 16 * 1024
const MAX_BODY_BYTES := 256 * 1024
const REQUEST_TIMEOUT_MS := 10000
const MAX_CONNECTIONS := 1024
## Oversized bodies up to this size are read and discarded so the client
## gets a clean 413 (closing mid-upload looks like a network error); larger
## ones are cut off.
const MAX_DRAIN_BYTES := 4 * 1024 * 1024

## Requests per second per client, and the burst allowed above that.
var rate_per_sec := 20.0
var rate_burst := 60.0
## Loopback clients (local dev, tests) skip the rate limit.
var exempt_loopback := true
## Read the client IP from X-Forwarded-For (only behind a trusted proxy).
var trust_proxy := false

var _tcp := TCPServer.new()
var _handler: Callable
var _conns: Dictionary = {}     # StreamPeerTCP -> {buf: PackedByteArray, since: int}
var _buckets: Dictionary = {}   # client ip -> {tokens: float, at: int}


func start(port: int, handler: Callable) -> bool:
	_handler = handler
	return _tcp.listen(port) == OK


func stop() -> void:
	for peer in _conns:
		(peer as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	_tcp.stop()


func poll() -> void:
	var now := Time.get_ticks_msec()
	while _tcp.is_connection_available():
		var peer: StreamPeerTCP = _tcp.take_connection()
		if peer == null:
			continue
		if _conns.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
			continue
		_conns[peer] = { "buf": PackedByteArray(), "since": now }

	var dead: Array = []
	for key in _conns.keys():
		var peer: StreamPeerTCP = key
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(peer)
			continue
		var conn: Dictionary = _conns[peer]
		if now - int(conn["since"]) > REQUEST_TIMEOUT_MS:
			_write(peer, _json(408, { "error": "request timeout" }))
			dead.append(peer)
			continue
		var avail: int = peer.get_available_bytes()
		if avail <= 0:
			continue
		var read: Array = peer.get_data(avail)
		if conn.has("draining"):
			# Rejected oversized request: discard the rest, then answer.
			conn["draining"] = int(conn["draining"]) - (read[1] as PackedByteArray).size()
			if int(conn["draining"]) <= 0:
				_write(peer, conn["reject"])
				dead.append(peer)
			continue
		var buf: PackedByteArray = conn["buf"]
		buf.append_array(read[1])
		conn["buf"] = buf
		var request: Dictionary = _try_parse(buf)
		if request.is_empty():
			continue
		var response: Dictionary
		if request.has("reject"):
			var remaining := int(request.get("drain", 0)) - buf.size()
			if remaining > 0 and int(request["drain"]) <= MAX_DRAIN_BYTES:
				conn["draining"] = remaining
				conn["reject"] = request["reject"]
				conn["buf"] = PackedByteArray()
				continue
			response = request["reject"]
		elif not _allow(_client_ip(peer, request)):
			response = _json(429, { "error": "too many requests" })
		else:
			response = _route(request)
		_write(peer, response)
		dead.append(peer)

	for peer in dead:
		_conns.erase(peer)
		peer.disconnect_from_host()

	if _buckets.size() > 50000:
		_buckets.clear()   # crude cap; buckets refill quickly anyway


func _route(request: Dictionary) -> Dictionary:
	if _handler == null or not _handler.is_valid():
		return _json(500, { "error": "no handler" })
	var result: Variant = _handler.call(request.method, request.path, request.body)
	if result is Dictionary:
		return result
	return _json(500, { "error": "handler returned invalid response" })


func _json(status: int, body: Variant) -> Dictionary:
	return { "status": status, "body": body }


func _client_ip(peer: StreamPeerTCP, request: Dictionary) -> String:
	if trust_proxy:
		var fwd := str(request["headers"].get("x-forwarded-for", ""))
		if fwd != "":
			return fwd.get_slice(",", 0).strip_edges()
	return peer.get_connected_host()


## Token bucket per client: true if this request may proceed.
func _allow(ip: String) -> bool:
	if exempt_loopback and (ip == "127.0.0.1" or ip == "::1" or ip.begins_with("::ffff:127.")):
		return true
	var now := Time.get_ticks_msec()
	var b: Dictionary = _buckets.get(ip, { "tokens": rate_burst, "at": now })
	b["tokens"] = minf(rate_burst, float(b["tokens"]) + (now - int(b["at"])) / 1000.0 * rate_per_sec)
	b["at"] = now
	_buckets[ip] = b
	if float(b["tokens"]) < 1.0:
		return false
	b["tokens"] = float(b["tokens"]) - 1.0
	return true


## {} while the request is incomplete; {"reject": response} if it must be
## refused; otherwise {method, path, headers, body}.
func _try_parse(buf: PackedByteArray) -> Dictionary:
	var text := buf.get_string_from_ascii() if buf.size() <= MAX_HEADER_BYTES else buf.slice(0, MAX_HEADER_BYTES).get_string_from_ascii()
	var header_end := text.find("\r\n\r\n")
	if header_end == -1:
		if buf.size() > MAX_HEADER_BYTES:
			return { "reject": _json(431, { "error": "headers too large" }) }
		return {}
	var lines := text.substr(0, header_end).split("\r\n")
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0:
			headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
	var content_length := int(headers.get("content-length", "0"))
	var body_start := header_end + 4
	if content_length < 0 or content_length > MAX_BODY_BYTES:
		return { "reject": _json(413, { "error": "body too large" }), "drain": body_start + maxi(0, content_length) }
	if buf.size() < body_start + content_length:
		return {}
	var request_line := lines[0].split(" ", false)
	if request_line.size() < 2:
		return { "reject": _json(400, { "error": "bad request line" }) }
	var path := request_line[1]
	var body := {}
	var body_text := buf.slice(body_start, body_start + content_length).get_string_from_utf8()
	if body_text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string(body_text)
		if parsed is Dictionary:
			body = parsed
	# Query-string parameters (e.g. GET /match/<id>?token=...) are merged into
	# the body so handlers read them the same way.
	var q := path.find("?")
	if q != -1:
		for pair in path.substr(q + 1).split("&", false):
			var kv := pair.split("=", true, 1)
			body[kv[0].uri_decode()] = kv[1].uri_decode() if kv.size() > 1 else ""
		path = path.substr(0, q)
	return { "method": request_line[0], "path": path, "headers": headers, "body": body }


func _write(peer: StreamPeerTCP, response: Dictionary) -> void:
	var body_bytes := JSON.stringify(response.get("body", {})).to_utf8_buffer()
	var status := int(response.get("status", 200))
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
		status, _reason(status), body_bytes.size(),
	]
	peer.put_data(head.to_ascii_buffer())
	peer.put_data(body_bytes)


func _reason(status: int) -> String:
	match status:
		200:
			return "OK"
		201:
			return "Created"
		204:
			return "No Content"
		400:
			return "Bad Request"
		403:
			return "Forbidden"
		404:
			return "Not Found"
		408:
			return "Request Timeout"
		409:
			return "Conflict"
		413:
			return "Payload Too Large"
		429:
			return "Too Many Requests"
		431:
			return "Request Header Fields Too Large"
		500:
			return "Internal Server Error"
		501:
			return "Not Implemented"
		_:
			return "OK"
