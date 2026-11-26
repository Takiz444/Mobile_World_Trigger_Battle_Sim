class_name DirStore
extends GameStore
## One JSON file per record: <root>/<kind>/<id>.json. A flush writes only the
## records that changed, each atomically, so cost scales with activity rather
## than with the number of players. The production default for a single
## server (mount <root> on a persistent volume and back it up).

var root: String
var _pending: Dictionary = {}   # "kind/id" -> record, or null to delete


func _init(p_root: String) -> void:
	root = p_root.rstrip("/")


func describe() -> String:
	return "directory %s" % root


func open() -> bool:
	for kind in GameStore.KINDS:
		var err := DirAccess.make_dir_recursive_absolute("%s/%s" % [root, kind])
		if err != OK and err != ERR_ALREADY_EXISTS:
			push_error("Cannot create %s/%s (error %d)" % [root, kind, err])
			return false
	return true


func load_all(match_cutoff: float) -> Dictionary:
	var out := GameStore._empty()
	for kind in GameStore.KINDS:
		var dir := "%s/%s" % [root, kind]
		for file in DirAccess.get_files_at(dir):
			if not file.ends_with(".json"):
				continue
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [dir, file]))
			if not (parsed is Dictionary):
				push_warning("Skipping unreadable record %s/%s" % [dir, file])
				continue
			if kind == "matches" and int(parsed.get("winner", -1)) != -1 \
					and float(parsed.get("ended_at", 0.0)) < match_cutoff:
				continue
			out[kind][file.get_basename()] = parsed
	return out


func put(kind: String, id: String, record: Dictionary) -> void:
	if GameStore.valid_id(id):
		_pending["%s/%s" % [kind, id]] = record


func remove(kind: String, id: String) -> void:
	if GameStore.valid_id(id):
		_pending["%s/%s" % [kind, id]] = null


func flush() -> void:
	for key in _pending.keys():
		var path := "%s/%s.json" % [root, key]
		var record: Variant = _pending[key]
		var ok := true
		if record == null:
			if FileAccess.file_exists(path):
				ok = DirAccess.remove_absolute(path) == OK
		else:
			ok = GameStore.write_atomic(path, JSON.stringify(record))
		if ok:
			_pending.erase(key)


func pending() -> int:
	return _pending.size()
