class_name SquadStore
extends RefCounted
## The player's squad (static, survives scene changes without an Autoload).
## Saved to user://squad.json whenever the Hangar changes it, so loadouts and
## talent points survive restarts. A saved squad that no longer passes the
## server's rules (e.g. after a balance update) is replaced by the defaults.

const PATH := "user://squad.json"

## Tests set this false so they never read or write the player's save.
static var persist := true
static var squad: Array[UnitData] = []


static func get_squad() -> Array[UnitData]:
	if squad.is_empty():
		if not _load():
			reset_to_defaults()
	return squad


static func reset_to_defaults() -> void:
	squad = TriggerLibrary.sample_units()
	for u in squad:
		u.ensure_slot_arrays()
	save()


static func save() -> void:
	if not persist or squad.is_empty():
		return
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({ "squad": PlanCodec.encode_squad(squad) }))


static func _load() -> bool:
	if not persist or not FileAccess.file_exists(PATH):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (parsed is Dictionary) or not (parsed.get("squad") is Array):
		return false
	var data: Array = parsed["squad"]
	if PlanCodec.validate_squad(data) != "":
		return false
	squad = PlanCodec.decode_squad(data)
	for u in squad:
		u.ensure_slot_arrays()
	return true
