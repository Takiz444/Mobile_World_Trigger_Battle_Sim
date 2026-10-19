extends Node3D
## Root scene for the board/diorama prototype (GDD Phase 1, step 1).
## Builds the hologram tabletop board, lighting, environment, and camera.

const BOARD_RADIUS := 6
const HEX_SIZE := 1.0

var _board: HexBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _ui_layer: CanvasLayer
var _camera: BoardCamera


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
	cam.start_size = 24.0
	# Look straight up the map (from team 0's side) so the squads face each
	# other vertically, like the reference map sheet.
	cam.yaw = 0.0
	cam.pitch = deg_to_rad(50.0)
	# Center the board in the area left free by the UI: the combat log covers
	# ~380 px on the right, the top bar 44 px, the timeline ~250 px at the bottom.
	cam.screen_offset_px = Vector2(-190.0, -103.0)
	add_child(cam)
	_camera = cam


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
	controller.setup(_board, _timeline, _event_log, _ui_layer, _camera)
