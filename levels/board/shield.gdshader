shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
// Energy barrier flash: a hexagon-cell shell that is brightest at its rim
// (fresnel) and on the side facing the incoming hit. `facing` = vec3(0)
// lights the whole shell (full guard). `strength` fades it in and out.

uniform vec3 color : source_color = vec3(0.6, 0.85, 1.0);
uniform vec3 facing = vec3(0.0);
uniform float strength = 1.0;

varying vec3 local_pos;
varying vec3 world_dir;

void vertex() {
	local_pos = VERTEX;
	world_dir = normalize((MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz);
}

// Distance to the nearest hexagon cell edge (0 at edges, ~0.5 at centers).
float hex_edge(vec2 p) {
	const vec2 s = vec2(1.0, 1.7320508);
	vec4 hc = floor(vec4(p, p - vec2(0.5, 1.0)) / s.xyxy) + 0.5;
	vec4 h = vec4(p - hc.xy * s, p - (hc.zw + 0.5) * s);
	vec2 c = dot(h.xy, h.xy) < dot(h.zw, h.zw) ? h.xy : h.zw;
	c = abs(c);
	return 0.5 - max(dot(c, s * 0.5), c.x);
}

void fragment() {
	vec3 n = normalize(local_pos);
	// Hex cells mapped around the shell.
	vec2 uv = vec2(atan(n.x, n.z) * 2.4, n.y * 3.4);
	float e = hex_edge(uv * 2.0);
	float w = fwidth(e) * 1.5;
	float cells = 1.0 - smoothstep(0.03 - w, 0.03 + w, e);
	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	float side = length(facing) < 0.5 ? 1.0 : smoothstep(-0.1, 0.75, dot(world_dir, facing));
	// Nothing below the feet.
	float above = smoothstep(-0.55, -0.3, n.y);
	float a = (cells * 0.75 + fres * 0.55 + 0.07) * side * above * strength;
	ALBEDO = color * (1.4 + cells);
	ALPHA = clamp(a, 0.0, 1.0);
}
