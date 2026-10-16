class_name SquadStore
extends RefCounted
## Session-scoped player squad (static). Survives scene changes without an
## Autoload, per the "static var over Autoload for pure data" guideline.

static var squad: Array[UnitData] = []


static func get_squad() -> Array[UnitData]:
	if squad.is_empty():
		reset_to_defaults()
	return squad


static func reset_to_defaults() -> void:
	squad = TriggerLibrary.sample_units()
	for u in squad:
		u.ensure_slot_arrays()
