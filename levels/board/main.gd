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


## Dusk over the city: a gradient sky that also lights the scene, filmic
## tone mapping, glow so lit windows and street lamps bloom, ambient
## occlusion to seat buildings on the ground, and a light blue haze.
func _setup_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.09, 0.12, 0.25)
	sky_mat.sky_horizon_color = Color(0.85, 0.5, 0.36)
	sky_mat.ground_horizon_color = Color(0.3, 0.22, 0.24)
	sky_mat.ground_bottom_color = Color(0.04, 0.05, 0.08)
	sky_mat.sun_angle_max = 25.0
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 0.9
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.36, 0.42, 0.58)
	env.fog_density = 0.004
	env.fog_sky_affect = 0.3

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


## A low, warm setting sun casting long soft shadows down the streets, plus
## a cool fill from the opposite sky.
func _setup_lights() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-32.0, -58.0, 0.0)
	sun.light_color = Color(1.0, 0.78, 0.58)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "SkyFill"
	fill.rotation_degrees = Vector3(-50.0, 125.0, 0.0)
	fill.light_color = Color(0.55, 0.65, 1.0)
	fill.light_energy = 0.35
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
