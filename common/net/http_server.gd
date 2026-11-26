class_name HttpServer
extends RefCounted
## Minimal HTTP/1.1 server for the headless backend. Accepts connections via a
## TCPServer, buffers each request, and dispatches (method, path, body, ctx)
## to a handler Callable that returns {"status": int, "body": Variant}.
## `ctx` is {ip, headers, bearer}: the client address (for per-client limits)
## and the "Authorization: Bearer" token, if any.
##
## Public-internet hardening:
##   - request size caps (headers MAX_HEADER_BYTES, body MAX_BODY_BYTES)
##   - connections that don't finish a request in REQUEST_TIMEOUT_MS are dropped
##   - per-client token-bucket rate limit (429) and connection cap. Behind a
##     reverse proxy set trust_proxy so the client IP comes from
##     X-Forwarded-For; otherwise every player would share the proxy's bucket.
##   - responses are written without blocking: a client that stops reading
##     can only stall its own connection (dropped after WRITE_TIMEOUT_MS),
##     never the server loop that also runs every match clock.
##   - credentials are never read from the URL (URLs end up in proxy and
##     access logs): SECRET_KEYS in a query string are ignored. Clients send
##     them in the JSON body or as "Authorization: Bearer <token>".
##
## Slow work (password hashing on a worker thread) can answer later: the
## handler returns {"status": 0, "deferred": Deferred} and calls
## Deferred.resolve(response) when done. The connection waits up to
## DEFERRED_TIMEOUT_MS, without blocking anyone else.

const MAX_HEADER_BYTES := 16 * 1024
const MAX_BODY_BYTES := 256 * 1024
const REQUEST_TIMEOUT_MS := 10000
const MAX_CONNECTIONS := 1024
## Oversized bodies up to this size are read and discarded so the client
## gets a clean 413 (closing mid-upload looks like a network error); larger
## ones are cut off.
const MAX_DRAIN_BYTES := 4 * 1024 * 1024
## A response must be fully read by the client within this long.
const WRITE_TIMEOUT_MS := 15000
## Open connections allowed per client address (not applied when trust_proxy
## is set: every player arrives through the proxy's address).
const MAX_CONNECTIONS_PER_IP := 32
## Never accepted from a query string.
const SECRET_KEYS: Array[String] = ["token", "secret", "admin_key", "password", "email"]
## A deferred response must be ready this long after the request arrived.
const DEFERRED_TIMEOUT_MS := 28000


## A response the handler will produce later (see the header).
class Deferred extends RefCounted:
	var done := false
	var response: Dictionary = {}

	func resolve(p_response: Dictionary) -> void:
		if not done:
			response = p_response
			done = true

## Requests per second per client, and the burst allowed above that.
var rate_per_sec := 20.0
var rate_burst := 60.0
## Loopback clients (local dev, tests) skip the rate limit.
var exempt_loopback := true
## Read the client IP from X-Forwarded-For (only behind a trusted proxy).
var trust_proxy := false
## Anything else is answered with 405 before it reaches the handler.
var allowed_methods: Array[String] = ["GET", "POST"]

var _tcp := TCPServer.new()
var _handler: Callable
var _conns: Dictionary = {}     # StreamPeerTCP -> {buf, since, host, out?, sent?, out_since?}
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
		var host := peer.get_connected_host()
		if _conns.size() >= MAX_CONNECTIONS or (not trust_proxy and not is_loopback(host)
				and _open_from(host) >= MAX_CONNECTIONS_PER_IP):
			peer.disconnect_from_host()
			continue
		_conns[peer] = { "buf": PackedByteArray(), "since": now, "host": host }

	var dead: Array = []
	for key in _conns.keys():
		var peer: StreamPeerTCP = key
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(peer)
			continue
		var conn: Dictionary = _conns[peer]
		if conn.has("wait"):
			var wait: Deferred = conn["wait"]
			if wait.done:
				conn.erase("wait")
				_respond(peer, conn, wait.response, now, dead)
			elif now - int(conn["since"]) > DEFERRED_TIMEOUT_MS:
				conn.erase("wait")
				_respond(peer, conn, _json(503, { "error": "server busy; try again" }), now, dead)
			continue
		if conn.has("out"):
			# Response in progress: push what the socket accepts.
			if _pump(peer, conn) or now - int(conn["out_since"]) > WRITE_TIMEOUT_MS:
				dead.append(peer)
			continue
		if now - int(conn["since"]) > REQUEST_TIMEOUT_MS:
			_respond(peer, conn, _json(408, { "error": "request timeout" }), now, dead)
			continue
		var avail: int = peer.get_available_bytes()
		if avail <= 0:
			continue
		var read: Array = peer.get_data(avail)
		if conn.has("draining"):
			# Rejected oversized request: discard the rest, then answer.
			conn["draining"] = int(conn["draining"]) - (read[1] as PackedByteArray).size()
			if int(conn["draining"]) <= 0:
				_respond(peer, conn, conn["reject"], now, dead)
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
		else:
			var ip := _client_ip(peer, request)
			if not _allow(ip):
				response = _json(429, { "error": "too many requests" })
			else:
				response = _route(request, ip)
		conn["buf"] = PackedByteArray()
		if response.get("deferred") is Deferred:
			conn["wait"] = response["deferred"]
			continue
		_respond(peer, conn, response, now, dead)

	for peer in dead:
		_conns.erase(peer)
		peer.disconnect_from_host()

	if _buckets.size() > 50000:
		_buckets.clear()   # crude cap; buckets refill quickly anyway


func _route(request: Dictionary, ip: String) -> Dictionary:
	if _handler == null or not _handler.is_valid():
		return _json(500, { "error": "no handler" })
	var headers: Dictionary = request["headers"]
	var bearer := ""
	var auth := str(headers.get("authorization", ""))
	if auth.to_lower().begins_with("bearer "):
		bearer = auth.substr(7).strip_edges()
	var ctx := { "ip": ip, "headers": headers, "bearer": bearer }
	var result: Variant = _handler.call(request["method"], request["path"], request["body"], ctx)
	if result is Dictionary and result.has("status"):
		return result
	# A handler that hit a script error returns null: answer without details.
	return _json(500, { "error": "internal error" })


func _json(status: int, body: Variant) -> Dictionary:
	return { "status": status, "body": body }


func _client_ip(peer: StreamPeerTCP, request: Dictionary) -> String:
	if trust_proxy:
		var fwd := str(request["headers"].get("x-forwarded-for", ""))
		if fwd != "":
			# The last entry is the one our own proxy appended; anything
			# before it is whatever the client claimed.
			var hops := fwd.split(",", false)
			return hops[hops.size() - 1].strip_edges()
	return peer.get_connected_host()


static func is_loopback(ip: String) -> bool:
	return ip == "127.0.0.1" or ip == "::1" or ip == "0:0:0:0:0:0:0:1" or ip.begins_with("::ffff:127.")


func _open_from(host: String) -> int:
	var n := 0
	for c in _conns.values():
		if c["host"] == host:
			n += 1
	return n


## Token bucket per client: true if this request may proceed.
func _allow(ip: String) -> bool:
	if exempt_loopback and is_loopback(ip):
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
	# Only the header block is decoded as text; one character per byte, so
	# offsets into `text` are byte offsets into `buf`.
	var head_bytes := buf if buf.size() <= MAX_HEADER_BYTES else buf.slice(0, MAX_HEADER_BYTES)
	var text := head_bytes.get_string_from_ascii()
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
	var request_line := lines[0].split(" ", false)
	if request_line.size() < 2 or not request_line[1].begins_with("/"):
		return { "reject": _json(400, { "error": "bad request line" }) }
	if not (request_line[0] in allowed_methods):
		return { "reject": _json(405, { "error": "method not allowed" }) }
	if headers.has("transfer-encoding"):
		return { "reject": _json(411, { "error": "content-length required" }) }
	var length_text := str(headers.get("content-length", "0"))
	if not length_text.is_valid_int():
		return { "reject": _json(400, { "error": "bad content-length" }) }
	var content_length := int(length_text)
	var body_start := header_end + 4
	if content_length < 0 or content_length > MAX_BODY_BYTES:
		return { "reject": _json(413, { "error": "body too large" }), "drain": body_start + maxi(0, content_length) }
	if buf.size() < body_start + content_length:
		return {}
	var path := request_line[1]
	var body := {}
	var body_text := buf.slice(body_start, body_start + content_length).get_string_from_utf8()
	if body_text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string(body_text)
		if not (parsed is Dictionary):
			return { "reject": _json(400, { "error": "body must be a JSON object" }) }
		body = parsed
	# Query-string parameters (e.g. GET /match/<id>?since=3) are merged into
	# the body so handlers read them the same way. Credentials are not.
	var q := path.find("?")
	if q != -1:
		for pair in path.substr(q + 1).split("&", false):
			var kv := pair.split("=", true, 1)
			var key := kv[0].uri_decode()
			if key in SECRET_KEYS:
				continue
			body[key] = kv[1].uri_decode() if kv.size() > 1 else ""
		path = path.substr(0, q)
	return { "method": request_line[0], "path": path, "headers": headers, "body": body }


## Queues `response` on the connection and starts sending it. The connection
## closes once everything is written (or WRITE_TIMEOUT_MS passes).
func _respond(peer: StreamPeerTCP, conn: Dictionary, response: Dictionary, now: int, dead: Array) -> void:
	var body_bytes := JSON.stringify(response.get("body", {})).to_utf8_buffer()
	var status := int(response.get("status", 200))
	var head := ("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
		+ "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n") % [
		status, _reason(status), body_bytes.size(),
	]
	var out := head.to_ascii_buffer()
	out.append_array(body_bytes)
	conn["out"] = out
	conn["sent"] = 0
	conn["out_since"] = now
	if _pump(peer, conn):
		dead.append(peer)


## Writes as much of the pending response as the socket takes right now.
## Returns true when the connection is finished (all sent, or broken).
func _pump(peer: StreamPeerTCP, conn: Dictionary) -> bool:
	var out: PackedByteArray = conn["out"]
	var sent: int = conn["sent"]
	while sent < out.size():
		var res: Array = peer.put_partial_data(out.slice(sent, mini(out.size(), sent + 65536)))
		if int(res[0]) != OK:
			return true
		if int(res[1]) <= 0:
			break   # socket buffer full: continue on the next poll
		sent += int(res[1])
	conn["sent"] = sent
	return sent >= out.size()


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
		401:
			return "Unauthorized"
		403:
			return "Forbidden"
		404:
			return "Not Found"
		405:
			return "Method Not Allowed"
		408:
			return "Request Timeout"
		409:
			return "Conflict"
		411:
			return "Length Required"
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
		503:
			return "Service Unavailable"
		_:
			return "OK"
