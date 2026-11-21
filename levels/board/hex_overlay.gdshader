shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// Gameplay hex overlay drawn over the continuous street: a faint glowing hex
// outline (keeps the board readable) and, for tiles outside the team's
// sight, a dark fog tint with a fine diagonal hatch (so fog reads by pattern,
// not only by brightness). Highlights use hex_highlight.gdshader.

uniform float hex_size = 1.0;
uniform vec3 grid_color : source_color = vec3(0.45, 0.8, 1.0);
uniform float grid_alpha = 0.3;
uniform float fog_amount = 0.0;   // 1 = outside sight

varying vec3 local_pos;
varying vec3 world_pos;
varying float up;

void vertex() {
	local_pos = VERTEX;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	up = NORMAL.y;
}

void fragment() {
	if (up < 0.5) {
		discard;  // only the top face draws
	}
	vec2 q = abs(local_pos.xz);
	float apothem = hex_size * 0.8660254;
	float e = apothem - max(q.y, dot(q, vec2(0.8660254, 0.5)));
	// Constant ~1.5 px line regardless of zoom, with a soft inner glow.
	float w = max(fwidth(e), 0.0005);
	float line = 1.0 - smoothstep(w * 0.5, w * 2.0, e);
	float glow = (1.0 - smoothstep(0.0, 0.09, e)) * 0.25;
	float hatch_c = (world_pos.x + world_pos.z) * 5.0;
	float hw = fwidth(hatch_c);
	float hatch = smoothstep(0.35 - hw, 0.35 + hw, abs(fract(hatch_c) - 0.5));
	vec3 fog_col = vec3(0.03, 0.04, 0.08);
	float fog_a = fog_amount * (0.46 + 0.1 * hatch);
	float grid_a = max(line, glow) * grid_alpha * mix(1.0, 0.45, fog_amount);
	ALBEDO = mix(fog_col, grid_color, clamp(grid_a / max(grid_a + fog_a, 0.001), 0.0, 1.0));
	ALPHA = max(grid_a, fog_a);
}
