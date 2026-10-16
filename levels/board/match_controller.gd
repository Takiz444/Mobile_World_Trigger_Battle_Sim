class_name MatchController
extends Node
## Orchestrates the vertical slice: places the 4v4 squads on the board, routes
## board clicks to timeline targeting, and runs Submit → TickEngine → replay.

const TICK_DELAY := 0.55
const MATCH_SEED := 12345

var _board: HexBoard
var _timeline: TimelineUI
var _units_view: BoardUnits
var _engine := TickEngine.new()

var _player_states: Array[UnitState] = []
var _enemy_states: Array[UnitState] = []
var _ms: MatchState
var _enemy_plan: TurnPlan
var _resolving := false


func setup(board: HexBoard, timeline: TimelineUI) -> void:
	_board = board
	_timeline = timeline

	_units_view = BoardUnits.new()
	_units_view.name = "BoardUnits"
	_board.add_child(_units_view)

	_build_squads()

	_board.tile_selected.connect(_on_tile_selected)
	_timeline.plan_submitted.connect(_on_plan_submitted)


## Places both squads and builds a fresh MatchState + enemy plan.
func _build_squads() -> void:
	var player_data := SquadStore.get_squad()
	var enemy_data := TriggerLibrary.sample_units()
	for u in enemy_data:
		u.ensure_slot_arrays()

	_player_states = []
	_enemy_states = []
	for i in player_data.size():
		_player_states.append(UnitState.new(player_data[i], 0, Vector2i(-3 + i * 2, -2), 5))
	for i in enemy_data.size():
		_enemy_states.append(UnitState.new(enemy_data[i], 1, Vector2i(-3 + i * 2, 2), 2))

	_ms = MatchState.new(MATCH_SEED)
	_ms.setup_team(0, _player_states)
	_ms.setup_team(1, _enemy_states)

	_enemy_plan = TurnPlan.new(enemy_data)

	var all: Array[UnitState] = []
	all.append_array(_player_states)
	all.append_array(_enemy_states)
	_units_view.setup(all, _board.hex_size)


func _on_tile_selected(hex: Vector2i) -> void:
	_timeline.set_target_for_selected_slot(hex)


func _on_plan_submitted() -> void:
	if _resolving:
		return
	_resolving = true

	_build_squads()  # reset match, enemy plan, and unit markers
	_build_enemy_plan()

	var player_plan := _timeline.get_plan()
	print("--- Resolving turn ---")
	for tick in TurnPlan.TICKS_PER_TURN:
		var events := _engine.resolve_tick(_ms, player_plan, _enemy_plan, tick)
		for ev in events:
			print(ev.summary())
		_units_view.refresh()
		await get_tree().create_timer(TICK_DELAY).timeout

	print("--- Resolution complete ---")
	_resolving = false


## Simple enemy AI: attack the nearest player unit while in range and budget
## allows; otherwise fall back to Shield.
func _build_enemy_plan() -> void:
	for i in _enemy_states.size():
		var actions := _enemy_plan.get_available_actions(i)
		var offensive: TriggerCard = null
		var shield_card: TriggerCard = null
		for a in actions:
			if offensive == null and (a.card_type == TriggerCard.CardType.MELEE or a.card_type == TriggerCard.CardType.RANGED):
				offensive = a
			if shield_card == null and a.card_type == TriggerCard.CardType.SHIELD:
				shield_card = a

		for tick in TurnPlan.TICKS_PER_TURN:
			var acted := false
			if offensive != null:
				var target := _nearest_player(_enemy_states[i])
				if target != null:
					var dist := HexCoord.distance(_enemy_states[i].hex, target.hex)
					var in_range := (offensive.card_type == TriggerCard.CardType.MELEE and dist == 1) \
						or (offensive.card_type == TriggerCard.CardType.RANGED and dist <= TickEngine.DEFAULT_RANGED_RANGE)
					if in_range and _enemy_plan.assign(i, tick, 0, offensive):
						_enemy_plan.set_target(i, tick, target.hex)
						acted = true
			if not acted and shield_card != null:
				_enemy_plan.assign(i, tick, 0, shield_card)


func _nearest_player(from: UnitState) -> UnitState:
	var best: UnitState = null
	var best_dist := 0x7FFFFFFF
	for p in _player_states:
		if p.is_bailed:
			continue
		var d := HexCoord.distance(from.hex, p.hex)
		if d < best_dist:
			best_dist = d
			best = p
	return best
