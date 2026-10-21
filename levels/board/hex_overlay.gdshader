shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// Gameplay hex overlay drawn over the continuous street: a faint glowing hex
// outline (keeps the board readable) and, for tiles outside the team's
// sight, a dark fog tint. Highlights use separate flat materials.

uniform float hex_size = 1.0;
uniform vec3 grid_color : source_color = vec3(0.45, 0.8, 1.0);
uniform float grid_alpha = 0.32;
uniform float fog_amount = 0.0;   // 1 = outside sight

varying vec3 local_pos;
varying float up;

void vertex() {
	local_pos = VERTEX;
	up = NORMAL.y;
}

void fragment() {
	if (up < 0.5) {
		discard;  // only the top face draws
	}
	vec2 q = abs(local_pos.xz);
	float apothem = hex_size * 0.8660254;
	float e = apothem - max(q.y, dot(q, vec2(0.8660254, 0.5)));
	float line = 1.0 - smoothstep(0.0, 0.035, e);
	vec3 fog_col = vec3(0.03, 0.04, 0.08);
	ALBEDO = mix(fog_col, grid_color, line);
	ALPHA = max(line * grid_alpha, fog_amount * 0.5);
}
