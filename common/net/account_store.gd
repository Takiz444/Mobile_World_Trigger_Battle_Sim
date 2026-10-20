class_name AccountStore
extends RefCounted
## Remembers the local player's ranked account per server URL in
## user://account.json, so the Hangar can queue without re-registering.

const PATH := "user://account.json"


## Returns {player_id, secret, name} for `server_url`, or {} if none saved.
static func load_for(server_url: String) -> Dictionary:
	var all := _read()
	var entry: Variant = all.get(server_url.rstrip("/"))
	return entry if entry is Dictionary else {}


static func save_for(server_url: String, account: Dictionary) -> void:
	var all := _read()
	all[server_url.rstrip("/")] = {
		"player_id": str(account.get("player_id", "")),
		"secret": str(account.get("secret", "")),
		"name": str(account.get("name", "")),
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(all))


static func clear_for(server_url: String) -> void:
	var all := _read()
	all.erase(server_url.rstrip("/"))
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(all))


static func _read() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return parsed if parsed is Dictionary else {}
