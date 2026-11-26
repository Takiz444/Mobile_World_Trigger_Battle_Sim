class_name GfxLite
## Lighter materials for the Compatibility renderer (the Web build).
##
## WebGL compiles every shader the first time it is drawn, on the page's only
## thread, and on Windows the browser goes through ANGLE/Direct3D, where one
## lit Godot shader takes seconds to compile (measured: 6-10 s each on an
## Intel Arc laptop; the full board took 50-75 s and Chrome showed "Page
## Unresponsive"). Each distinct lit material is its own shader, so here:
##   - glowing parts become unshaded (bright flat color; the bloom still
##     picks them up) instead of lit + emission,
##   - lit materials drop specular highlights and the toon/rim extras, so
##     bodies, trim and props all share ONE lit shader,
##   - custom lit shaders (buildings, street) get `specular_disabled`.
## Together with ShaderWarmup this took the board from ~100 s of shader work
## to ~24 s, spread over frames. Desktop and mobile builds are unchanged.

static var _state := -1
static var _shaders := {}


static func enabled() -> bool:
	if _state == -1:
		_state = 1 if RenderingServer.get_current_rendering_method() == "gl_compatibility" else 0
	return _state == 1


## A lit material: no specular highlight on the light path.
static func lit(mat: BaseMaterial3D) -> BaseMaterial3D:
	if enabled():
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


## A glowing material (lit + emission elsewhere): unshaded, over-bright
## color on the light path.
static func glow(mat: BaseMaterial3D, color: Color, energy: float) -> BaseMaterial3D:
	if enabled():
		mat.emission_enabled = false
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var k := clampf(0.6 + 0.3 * energy, 1.0, 1.8)
		mat.albedo_color = Color(color.r * k, color.g * k, color.b * k, mat.albedo_color.a)
	return mat


## A custom spatial shader, without specular highlights on the light path.
static func shader(path: String) -> Shader:
	var s: Shader = load(path)
	if not enabled() or not s.code.contains("shader_type spatial;") or s.code.contains("render_mode"):
		return s
	if not _shaders.has(path):
		var lite := Shader.new()
		lite.code = s.code.replace("shader_type spatial;", "shader_type spatial;\nrender_mode specular_disabled;")
		_shaders[path] = lite
	return _shaders[path]
