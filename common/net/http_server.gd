class_name HttpServer
extends RefCounted
## Minimal HTTP/1.1 server for the headless backend. Accepts connections via a
## TCPServer, buffers each request, and dispatches (method, path, body) to a
## handler Callable that returns {"status": int, "body": Dictionary}.

var _tcp := TCPServer.new()
var _handler: Callable
var _conns: Dictionary = {}   # StreamPeerTCP -> PackedByteArray


func start(port: int, handler: Callable) -> bool:
	_handler = handler
	return _tcp.listen(port) == OK


func poll() -> void:
	while _tcp.is_connection_available():
		var peer: StreamPeerTCP = _tcp.take_connection()
		if peer != null:
			_conns[peer] = PackedByteArray()

	var dead: Array = []
	for key in _conns.keys():
		var peer: StreamPeerTCP = key
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(peer)
			continue
		var avail: int = peer.get_available_bytes()
		if avail <= 0:
			continue
		var read: Array = peer.get_data(avail)
		var chunk: PackedByteArray = read[1]
		var buf: PackedByteArray = _conns[peer]
		buf.append_array(chunk)
		_conns[peer] = buf
		var request: Variant = _try_parse(buf)
		if request != null:
			var response: Dictionary = _route(request)
			_write(peer, response)
			dead.append(peer)

	for peer in dead:
		_conns.erase(peer)
		peer.disconnect_from_host()


func _route(request: Dictionary) -> Dictionary:
	if _handler == null or not _handler.is_valid():
		return _json(500, { "error": "no handler" })
	var result: Variant = _handler.call(request.method, request.path, request.body)
	if result is Dictionary:
		return result
	return _json(500, { "error": "handler returned invalid response" })


func _json(status: int, body: Dictionary) -> Dictionary:
	return { "status": status, "body": body }


func _try_parse(buf: PackedByteArray) -> Variant:
	var text := buf.get_string_from_utf8()
	var header_end := text.find("\r\n\r\n")
	if header_end == -1:
		return null
	var header_text := text.substr(0, header_end)
	var body_start := header_end + 4
	var content_length := 0
	var lines := header_text.split("\r\n")
	for line in lines:
		var lower := line.to_lower()
		if lower.begins_with("content-length:"):
			content_length = int(line.get_slice(":", 1).strip_edges())
	if buf.size() < body_start + content_length:
		return null
	var request_line := lines[0].split(" ", false)
	if request_line.size() < 2:
		return null
	var method := request_line[0]
	var path := request_line[1]
	var body := {}
	var body_text := buf.slice(body_start, body_start + content_length).get_string_from_utf8()
	if body_text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string(body_text)
		if parsed is Dictionary:
			body = parsed
	return { "method": method, "path": path, "body": body }


func _write(peer: StreamPeerTCP, response: Dictionary) -> void:
	var body_text := JSON.stringify(response.get("body", {}))
	var status := int(response.get("status", 200))
	var reason := _reason(status)
	var payload := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [
		status, reason, body_text.to_utf8_buffer().size(), body_text,
	]
	peer.put_data(payload.to_utf8_buffer())


func _reason(status: int) -> String:
	match status:
		200:
			return "OK"
		201:
			return "Created"
		400:
			return "Bad Request"
		404:
			return "Not Found"
		500:
			return "Internal Server Error"
		_:
			return "OK"
