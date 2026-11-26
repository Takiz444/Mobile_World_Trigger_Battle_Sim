class_name Talents
extends RefCounted
## Talent points: every squad gets the same fixed pool (POINTS) to spread over
## its characters. Each point raises one stat of one character:
##   Stamina  +TEMPO_PER_POINT tempo: every action takes less time and the
##            character moves faster, so more fits into a 6-second turn
##   HP       +HP_PER_POINT Trion (health)
##   ATK      +ATK_PER_POINT attack rating (added to every hit's damage)
## A stat takes at most MAX_PER_STAT points on one character.
##
## Talents are the only thing that changes a character's stats: the server
## derives every stat from the talents (apply()) and never trusts stats a
## client sends. Tune the numbers here; both sides share this file (bump
## NetProtocol.VERSION when you change them).

const POINTS := 9
const MAX_PER_STAT := 4
const TEMPO_PER_POINT := 0.1
const HP_PER_POINT := 15
const ATK_PER_POINT := 1

const STATS: Array[String] = ["stamina", "hp", "atk"]
const LABELS := { "stamina": "Stamina", "hp": "HP", "atk": "ATK" }
const HINTS := {
	"stamina": "+%d%% speed: every action and move takes less time" % roundi(TEMPO_PER_POINT * 100.0),
	"hp": "+%d Trion: survive more hits" % HP_PER_POINT,
	"atk": "+%d damage on every hit" % ATK_PER_POINT,
}


static func get_points(u: UnitData, stat: String) -> int:
	match stat:
		"stamina":
			return u.talent_stamina
		"hp":
			return u.talent_hp
		"atk":
			return u.talent_atk
	return 0


static func set_points(u: UnitData, stat: String, value: int) -> void:
	value = clampi(value, 0, MAX_PER_STAT)
	match stat:
		"stamina":
			u.talent_stamina = value
		"hp":
			u.talent_hp = value
		"atk":
			u.talent_atk = value
	apply(u)


static func unit_total(u: UnitData) -> int:
	return u.talent_stamina + u.talent_hp + u.talent_atk


static func squad_total(units: Array) -> int:
	var total := 0
	for u in units:
		total += unit_total(u)
	return total


static func remaining(units: Array) -> int:
	return POINTS - squad_total(units)


## Whether one more point may go into `stat` of `u` within `units`' pool.
static func can_add(units: Array, u: UnitData, stat: String) -> bool:
	return remaining(units) > 0 and get_points(u, stat) < MAX_PER_STAT


## Recomputes `u`'s stats from its talents (the base stats are the same for
## every character).
static func apply(u: UnitData) -> void:
	u.tempo = 1.0 + u.talent_stamina * TEMPO_PER_POINT
	u.base_trion_hp = TriggerLibrary.STANDARD_TRION_HP + u.talent_hp * HP_PER_POINT
	u.attack_rating = TriggerLibrary.STANDARD_RATING + u.talent_atk * ATK_PER_POINT
	u.mobility_rating = TriggerLibrary.STANDARD_RATING
	u.defense_rating = TriggerLibrary.STANDARD_RATING
	u.max_trion_capacity = TriggerLibrary.STANDARD_TRION_CAPACITY


## The stat a stat's talents produce (for UI labels; tempo as a percentage).
static func stat_value(u: UnitData, stat: String) -> int:
	match stat:
		"stamina":
			return roundi(u.tempo * 100.0)
		"hp":
			return u.base_trion_hp
		"atk":
			return u.attack_rating
	return 0
