shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Billboarded Trion (HP) bar above a unit: a dark rounded track, a
// team-colored fill that turns amber then red as it empties, and a brief
// white "chip" segment showing damage just taken.

instance uniform float fill = 1.0;      // current HP fraction
instance uniform float chip = 1.0;      // HP fraction before the last hit
instance uniform vec3 team_color : source_color = vec3(0.2, 0.6, 1.0);
instance uniform float opacity = 1.0;

void vertex() {
	// Face the camera, keep the node's world position and scale.
	vec3 s = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * s.x, INV_VIEW_MATRIX[1] * s.y, INV_VIEW_MATRIX[2] * s.z, MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	// Rounded-rectangle mask (bar aspect 8:1).
	vec2 p = (UV - 0.5) * vec2(8.0, 1.0);
	vec2 d = abs(p) - vec2(4.0 - 0.5, 0.0);
	float dist = length(max(d, 0.0)) - 0.5;
	float aa = fwidth(dist);
	float mask = 1.0 - smoothstep(-aa, aa, dist);
	float inner = 1.0 - smoothstep(-aa, aa, dist + 0.17);

	float x = clamp((UV.x - 0.035) / 0.93, 0.0, 1.0);
	float xw = fwidth(x);
	float filled = 1.0 - smoothstep(fill - xw, fill + xw, x);
	float chipped = (1.0 - smoothstep(chip - xw, chip + xw, x)) * (1.0 - filled);

	vec3 health = mix(vec3(1.0, 0.25, 0.2), vec3(1.0, 0.75, 0.2), smoothstep(0.15, 0.4, fill));
	health = mix(health, team_color, smoothstep(0.4, 0.6, fill));
	// Glossy top half.
	health *= mix(0.85, 1.25, smoothstep(0.65, 0.2, UV.y));
	vec3 track = vec3(0.03, 0.04, 0.07);
	vec3 col = mix(track, vec3(1.0), chipped * inner);
	col = mix(col, health, filled * inner);
	ALBEDO = col;
	ALPHA = mask * opacity * mix(0.8, 1.0, inner);
}
