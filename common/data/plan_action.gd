class_name PlanAction
extends RefCounted
## One planned action on a character's timeline.
##
##   Move / Grasshopper   point + level: where to go (Movement lane)
##   Look / Spider        point: where to watch / string the wire
##   Melee / Ranged       target_unit: which enemy (index in their squad)
##   Shield / Wait        hold: how many seconds
##   Bagworm              nothing

var card: TriggerCard
var point: Vector2 = Vector2.ZERO
var level: int = 0
var has_point: bool = false
var target_unit: int = -1
var hold: float = 0.0


func _init(p_card: TriggerCard = null) -> void:
	card = p_card
	if card != null:
		if card.card_name == "Wait":
			hold = TurnPlan.DEFAULT_WAIT
		elif card.card_type == TriggerCard.CardType.SHIELD:
			hold = TurnPlan.DEFAULT_SHIELD_HOLD


func set_point(p: Vector2, p_level: int = 0) -> void:
	# Plans travel as JSON: keep coordinates to the centimetre so the client's
	# preview and the server's check compute the same route.
	point = Vector2(snappedf(p.x, 0.01), snappedf(p.y, 0.01))
	level = p_level
	has_point = true


func is_attack() -> bool:
	return card != null and (card.card_type == TriggerCard.CardType.MELEE or card.card_type == TriggerCard.CardType.RANGED)


func uses_hold() -> bool:
	return card != null and (card.card_name == "Wait" or card.card_type == TriggerCard.CardType.SHIELD)


## Whether this action still needs a target picked on the board.
func needs_target() -> bool:
	if card == null:
		return false
	if is_attack():
		return target_unit < 0
	if TurnPlan.is_move_card(card) or card.card_name == "Look" or card.card_name == "Spider":
		return not has_point
	return false


func duplicate_action() -> PlanAction:
	var a := PlanAction.new(card)
	a.point = point
	a.level = level
	a.has_point = has_point
	a.target_unit = target_unit
	a.hold = hold
	return a
