class_name TriggerLibrary
extends RefCounted
## Static sample trigger/action card and unit definitions for prototyping.
## Later these will be replaced by .tres Resource files authored in the editor.

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
	return {
		"Kogetsu": make_card("Kogetsu", 3, 20, TriggerCard.CardType.MELEE, false, 6),
		"Scorpion": make_card("Scorpion", 3, 15, TriggerCard.CardType.MELEE, true, 4),
		"Raygust": make_card("Raygust", 2, 15, TriggerCard.CardType.MELEE, true, 3),
		"Asteroid": make_card("Asteroid", 3, 20, TriggerCard.CardType.RANGED, false, 5),
		"Viper": make_card("Viper", 3, 20, TriggerCard.CardType.RANGED, true, 4),
		"Hound": make_card("Hound", 3, 20, TriggerCard.CardType.RANGED, true, 4),
		"Ibis": make_card("Ibis", 4, 25, TriggerCard.CardType.RANGED, false, 8),
		"Egret": make_card("Egret", 3, 20, TriggerCard.CardType.RANGED, false, 5),
		"Shield": make_card("Shield", 2, 10, TriggerCard.CardType.SHIELD, true, 0),
		"Bagworm": make_card("Bagworm", 1, 10, TriggerCard.CardType.STEALTH, true, 0),
		"Grasshopper": make_card("Grasshopper", 1, 15, TriggerCard.CardType.UTILITY, true, 0),
		"Spider": make_card("Spider", 2, 15, TriggerCard.CardType.UTILITY, true, 0),
		"Lead Bullet": make_card("Lead Bullet", 2, 10, TriggerCard.CardType.UTILITY, true, 0),
	}


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
		[c["Kogetsu"], c["Scorpion"], c["Asteroid"], c["Shield"]],
		[c["Shield"], c["Bagworm"]]
	))
	result.append(_make_unit(
		"Shooter",
		[c["Asteroid"], c["Viper"], c["Shield"], c["Spider"]],
		[c["Shield"], c["Grasshopper"]]
	))
	result.append(_make_unit(
		"Sniper",
		[c["Viper"], c["Asteroid"], c["Shield"], c["Bagworm"]],
		[c["Shield"], c["Grasshopper"]]
	))
	result.append(_make_unit(
		"Scout",
		[c["Scorpion"], c["Spider"], c["Shield"], c["Bagworm"]],
		[c["Bagworm"], c["Grasshopper"]]
	))
	return result


static func _make_unit(unit_name: String, main: Array, sub: Array) -> UnitData:
	var u := UnitData.new()
	u.unit_name = unit_name
	u.base_trion_hp = 100
	u.base_at_pool = 8
	u.mobility_rating = 5
	u.attack_rating = 5
	u.defense_rating = 5
	u.max_trion_capacity = 100
	u.main_trigger_slots = _to_cards(main)
	u.sub_trigger_slots = _to_cards(sub)
	return u


static func _to_cards(source: Array) -> Array[TriggerCard]:
	var result: Array[TriggerCard] = []
	for item in source:
		result.append(item as TriggerCard)
	return result
