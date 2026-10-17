extends Node3D
## Root scene for the board/diorama prototype (GDD Phase 1, step 1).
## Builds the hologram tabletop board, lighting, environment, and camera.

const BOARD_RADIUS := 6
const HEX_SIZE := 1.0

var _board: HexBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _ui_layer: CanvasLayer


func _ready() -> void:
	_setup_environment()
	_setup_lights()
	_setup_board()
	_setup_ui()
	_setup_match()


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.05, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.55, 0.75)
	env.ambient_light_energy = 0.7

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _setup_lights() -> void:
	var key := DirectionalLight3D.new()
	key.name = "KeyLight"
	key.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	key.light_energy = 1.2
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-30.0, 130.0, 0.0)
	fill.light_color = Color(0.55, 0.65, 1.0)
	fill.light_energy = 0.4
	add_child(fill)


func _setup_board() -> void:
	var board := HexBoard.new()
	board.name = "HexBoard"
	board.board_radius = BOARD_RADIUS
	board.hex_size = HEX_SIZE
	add_child(board)
	_board = board

	var cam := BoardCamera.new()
	cam.name = "BoardCamera"
	cam.target = Vector3.ZERO
	cam.start_size = 16.0
	add_child(cam)


func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	add_child(layer)
	_ui_layer = layer

	var timeline := TimelineUI.new()
	timeline.name = "TimelineUI"
	layer.add_child(timeline)
	timeline.setup(SquadStore.get_squad())
	_timeline = timeline

	var event_log := EventLogUI.new()
	event_log.name = "EventLogUI"
	layer.add_child(event_log)
	event_log.set_turn(1)
	_event_log = event_log


func _setup_match() -> void:
	var controller := MatchController.new()
	controller.name = "MatchController"
	add_child(controller)
	controller.setup(_board, _timeline, _event_log, _ui_layer)
