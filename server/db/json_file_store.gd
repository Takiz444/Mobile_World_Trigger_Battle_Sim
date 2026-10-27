class_name JsonFileStore
extends GameStore
## Everything in one JSON file ({matches, accounts, tickets, season}), the
## format the server has always used, rewritten on each flush. Fine for local
## development and tests; use DirStore or PostgrestStore for real players.

var path: String
var _doc := GameStore._empty()
var _dirty := false


func _init(p_path: String) -> void:
	path = p_path


func describe() -> String:
	return "json file %s" % path


func load_all(_match_cutoff: float) -> Dictionary:
	_doc = GameStore._empty()
	if not FileAccess.file_exists(path):
		return _doc.duplicate(true)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_warning("Ignoring unreadable store %s" % path)
		return _doc.duplicate(true)
	# Oldest stores were a bare {match_id: match} dictionary.
	_doc["matches"] = parsed["matches"] if parsed.has("matches") else parsed
	_doc["accounts"] = parsed.get("accounts", {})
	_doc["tickets"] = parsed.get("tickets", {})
	if parsed.has("season"):
		_doc["meta"] = { "server": { "season": parsed["season"] } }
	return _doc.duplicate(true)


func put(kind: String, id: String, record: Dictionary) -> void:
	_doc[kind][id] = record
	_dirty = true


func remove(kind: String, id: String) -> void:
	if _doc[kind].erase(id):
		_dirty = true


func flush() -> void:
	if not _dirty:
		return
	var out := { "matches": _doc["matches"], "accounts": _doc["accounts"], "tickets": _doc["tickets"],
		"season": _doc["meta"].get("server", {}).get("season", 1) }
	if GameStore.write_atomic(path, JSON.stringify(out)):
		_dirty = false


func pending() -> int:
	return 1 if _dirty else 0
