class_name TriggerLibrary
extends RefCounted
## Static sample trigger/action card and unit definitions for prototyping.
## Later these will be replaced by .tres Resource files authored in the editor.

## Standard unit stats. Every unit uses these; the server rejects squads that
## claim anything else (loadouts are the only customization).
const STANDARD_TRION_HP := 100
const STANDARD_AT_POOL := 8
const STANDARD_RATING := 5
const STANDARD_TRION_CAPACITY := 100

static var _move_card: TriggerCard


static func get_move_card() -> TriggerCard:
	if _move_card == null:
		var c := TriggerCard.new()
		c.card_name = "Move"
		c.action_at_cost = 1
		c.trion_equip_cost = 0
		c.is_dual_slot_compatible = false
		c.card_type = TriggerCard.CardType.MOVE
		_move_card = c
	return _move_card



static func make_card(card_name: String, at_cost: int, trion_cost: int, type: int, dual_slot: bool, power: int = 0) -> TriggerCard:
	var c := TriggerCard.new()
	c.card_name = card_name
	c.action_at_cost = at_cost
	c.trion_equip_cost = trion_cost
	c.card_type = type
	c.is_dual_slot_compatible = dual_slot
	c.power = power
	return c


static func sample_cards() -> Dictionary:
	var melee := TriggerCard.CardType.MELEE
	var ranged := TriggerCard.CardType.RANGED
	return {
		# Attacker triggers (melee).
		"Kogetsu": make_card("Kogetsu", 3, 20, melee, false, 6),
		"Scorpion": _traits(make_card("Scorpion", 3, 15, melee, true, 4), { "flexible": true }),
		"Raygust": _traits(make_card("Raygust", 2, 15, melee, true, 3), { "guard": true }),
		# Shooter / gunner bullets.
		"Asteroid": _traits(make_card("Asteroid", 3, 20, ranged, false, 5), { "attack_range": 5 }),
		"Viper": _traits(make_card("Viper", 3, 20, ranged, true, 4), { "attack_range": 5, "curved": true }),
		"Hound": _traits(make_card("Hound", 3, 20, ranged, true, 4), { "attack_range": 6, "homing": true, "accuracy_bonus": 0.15 }),
		"Lead Bullet": _traits(make_card("Lead Bullet", 2, 10, ranged, true, 0), { "attack_range": 5, "piercing": true, "effect": "weight" }),
		# Sniper rifles.
		"Egret": _traits(make_card("Egret", 3, 20, ranged, false, 5), { "attack_range": 10, "accuracy_bonus": 0.05 }),
		"Ibis": _traits(make_card("Ibis", 4, 25, ranged, false, 8), { "attack_range": 9, "piercing": true }),
		# Defense / utility.
		"Shield": make_card("Shield", 2, 10, TriggerCard.CardType.SHIELD, true, 0),
		"Bagworm": make_card("Bagworm", 1, 10, TriggerCard.CardType.STEALTH, true, 0),
		"Grasshopper": _traits(make_card("Grasshopper", 1, 15, TriggerCard.CardType.UTILITY, true, 0), { "jump": true }),
		"Spider": make_card("Spider", 2, 15, TriggerCard.CardType.UTILITY, true, 0),
	}


static func _traits(c: TriggerCard, props: Dictionary) -> TriggerCard:
	for key in props:
		c.set(key, props[key])
	return c


## Resolves a card by name (used by network serialization). Returns null for
## unknown names.
static func get_card(card_name: String) -> TriggerCard:
	if card_name == "Move":
		return get_move_card()
	var c: TriggerCard = sample_cards().get(card_name)
	return c


## Full trigger catalog (the Hangar's available-cards palette).
static func all_cards() -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	for c in sample_cards().values():
		result.append(c)
	return result


static func sample_units() -> Array[UnitData]:
	var c := sample_cards()
	var result: Array[UnitData] = []
	result.append(_make_unit(
		"Attacker",
		[c["Kogetsu"], c["Raygust"], c["Asteroid"], c["Shield"]],
		[c["Shield"], c["Bagworm"]]
	))
	result.append(_make_unit(
		"Shooter",
		[c["Asteroid"], c["Hound"], c["Shield"], c["Spider"]],
		[c["Shield"], c["Viper"]]
	))
	result.append(_make_unit(
		"Sniper",
		[c["Egret"], c["Ibis"], c["Shield"], c["Bagworm"]],
		[c["Shield"], c["Grasshopper"]]
	))
	result.append(_make_unit(
		"Scout",
		[c["Scorpion"], c["Spider"], c["Shield"], c["Bagworm"]],
		[c["Lead Bullet"], c["Grasshopper"]]
	))
	return result


static func _make_unit(unit_name: String, main: Array, sub: Array) -> UnitData:
	var u := UnitData.new()
	u.unit_name = unit_name
	u.base_trion_hp = STANDARD_TRION_HP
	u.base_at_pool = STANDARD_AT_POOL
	u.mobility_rating = STANDARD_RATING
	u.attack_rating = STANDARD_RATING
	u.defense_rating = STANDARD_RATING
	u.max_trion_capacity = STANDARD_TRION_CAPACITY
	u.main_trigger_slots = _to_cards(main)
	u.sub_trigger_slots = _to_cards(sub)
	return u


static func _to_cards(source: Array) -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	for item in source:
		result.append(item as TriggerCard)
	return result
