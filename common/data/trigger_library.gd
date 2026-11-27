class_name TriggerLibrary
extends RefCounted
## Static sample trigger/action card and unit definitions for prototyping.
## Later these will be replaced by .tres Resource files authored in the editor.

## Standard unit stats. Every unit uses these; the server rejects squads that
## claim anything else (loadouts are the only customization).
const STANDARD_TRION_HP := 100
const STANDARD_RATING := 5
const STANDARD_TRION_CAPACITY := 100
## One old hex spacing in metres (ranges below are written in hexes for
## readability and converted).
const HEX := 1.7320508075688772

static var _basic: Dictionary = {}
static var _catalog: Dictionary = {}


static func get_move_card() -> TriggerCard:
	return _basic_card("Move", TriggerCard.CardType.MOVE, 0.0, false)


## Look: keep watching a point (sets the vision cone and shield arc).
static func get_look_card() -> TriggerCard:
	return _basic_card("Look", TriggerCard.CardType.UTILITY, 0.3, true)


## Wait: pause a lane (both lanes have it).
static func get_wait_card() -> TriggerCard:
	return _basic_card("Wait", TriggerCard.CardType.UTILITY, 0.0, true)


static func _basic_card(card_name: String, type: int, time: float, dual: bool) -> TriggerCard:
	if not _basic.has(card_name):
		var c := TriggerCard.new()
		c.card_name = card_name
		c.action_time = time
		c.card_type = type
		c.is_dual_slot_compatible = dual
		c.free_action = true
		_basic[card_name] = c
	return _basic[card_name]


static func make_card(card_name: String, time: float, trion_cost: int, type: int, dual_slot: bool, power: int = 0) -> TriggerCard:
	var c := TriggerCard.new()
	c.card_name = card_name
	c.action_time = time
	c.trion_equip_cost = trion_cost
	c.card_type = type
	c.is_dual_slot_compatible = dual_slot
	c.power = power
	return c


## The trigger catalog, built once (cards are compared by identity).
static func sample_cards() -> Dictionary:
	if _catalog.is_empty():
		var melee := TriggerCard.CardType.MELEE
		var ranged := TriggerCard.CardType.RANGED
		_catalog = {
			# Attacker triggers (melee).
			"Kogetsu": make_card("Kogetsu", 1.8, 20, melee, false, 6),
			"Scorpion": _traits(make_card("Scorpion", 1.6, 15, melee, true, 4), { "flexible": true }),
			"Raygust": _traits(make_card("Raygust", 1.2, 15, melee, true, 3), { "guard": true }),
			# Shooter / gunner bullets.
			"Asteroid": _traits(make_card("Asteroid", 1.8, 20, ranged, false, 5), { "attack_range": 5 * HEX }),
			"Viper": _traits(make_card("Viper", 1.8, 20, ranged, true, 4), { "attack_range": 5 * HEX, "curved": true }),
			"Hound": _traits(make_card("Hound", 1.8, 20, ranged, true, 4), { "attack_range": 6 * HEX, "homing": true, "accuracy_bonus": 0.15 }),
			"Lead Bullet": _traits(make_card("Lead Bullet", 1.2, 10, ranged, true, 0), { "attack_range": 5 * HEX, "piercing": true, "effect": "weight" }),
			# Sniper rifles.
			"Egret": _traits(make_card("Egret", 1.8, 20, ranged, false, 5), { "attack_range": 10 * HEX, "accuracy_bonus": 0.05 }),
			"Ibis": _traits(make_card("Ibis", 2.4, 25, ranged, false, 8), { "attack_range": 9 * HEX, "piercing": true, "demolish": true }),
			# Defense / utility.
			"Shield": make_card("Shield", 0.0, 10, TriggerCard.CardType.SHIELD, true, 0),
			"Bagworm": make_card("Bagworm", 0.6, 10, TriggerCard.CardType.STEALTH, true, 0),
			"Grasshopper": _traits(make_card("Grasshopper", CityGeometry.JUMP_TIME, 15, TriggerCard.CardType.UTILITY, true, 0), { "jump": true }),
			"Spider": make_card("Spider", 1.2, 15, TriggerCard.CardType.UTILITY, true, 0),
		}
	return _catalog


static func _traits(c: TriggerCard, props: Dictionary) -> TriggerCard:
	for key in props:
		c.set(key, props[key])
	return c


## Resolves a card by name (network serialization). Null for unknown names.
static func get_card(card_name: String) -> TriggerCard:
	match card_name:
		"Move":
			return get_move_card()
		"Look":
			return get_look_card()
		"Wait":
			return get_wait_card()
	return sample_cards().get(card_name)


## Full trigger catalog (the Hangar's available-cards palette).
static func all_cards() -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	for c in sample_cards().values():
		result.append(c)
	return result


## The three playable characters, with default loadouts and a default
## talent spread that uses the whole pool (Talents.POINTS).
const ROSTER: Array[String] = ["Assassin", "Sniper", "Scout"]


static func sample_units() -> Array[UnitData]:
	var c := sample_cards()
	var result: Array[UnitData] = []
	# Close-range striker: blades, stealth to get close, a jump to engage.
	result.append(_make_unit(
		"Assassin",
		[c["Kogetsu"], c["Scorpion"], c["Shield"], c["Bagworm"]],
		[c["Shield"], c["Grasshopper"]],
		[1, 1, 1]
	))
	# Long-range damage from cover and rooftops.
	result.append(_make_unit(
		"Sniper",
		[c["Egret"], c["Ibis"], c["Shield"], c["Bagworm"]],
		[c["Shield"], c["Grasshopper"]],
		[0, 1, 2]
	))
	# Mid-range support: homing shots, wires, and Lead Bullet to pin targets.
	result.append(_make_unit(
		"Scout",
		[c["Asteroid"], c["Hound"], c["Shield"], c["Spider"]],
		[c["Shield"], c["Lead Bullet"], c["Grasshopper"]],
		[2, 1, 0]
	))
	return result


## `talents` = [stamina, hp, atk].
static func _make_unit(unit_name: String, main: Array, sub: Array, talents: Array = [0, 0, 0]) -> UnitData:
	var u := UnitData.new()
	u.unit_name = unit_name
	u.main_trigger_slots = _to_cards(main)
	u.sub_trigger_slots = _to_cards(sub)
	u.talent_stamina = int(talents[0])
	u.talent_hp = int(talents[1])
	u.talent_atk = int(talents[2])
	Talents.apply(u)
	return u


static func _to_cards(source: Array) -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	for item in source:
		result.append(item as TriggerCard)
	return result
