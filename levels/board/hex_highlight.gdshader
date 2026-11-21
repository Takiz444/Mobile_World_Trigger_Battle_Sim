shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// Gameplay highlight for a hex (hover, selection, move range, effect area,
// wires): a translucent fill that brightens toward a crisp outline, with a
// slow pulse. `style` adds a pattern so states don't rely on hue alone:
//   0 = plain fill, 1 = inner ring (selection / hover), 2 = diagonal stripes
//   (effect / danger area), 3 = dotted center (wires).

uniform float hex_size = 1.0;
uniform vec3 color : source_color = vec3(0.3, 1.0, 0.5);
uniform float fill_alpha = 0.3;
uniform float pulse = 0.12;
uniform int style = 0;

varying vec3 local_pos;
varying float up;

void vertex() {
	local_pos = VERTEX;
	up = NORMAL.y;
}

void fragment() {
	if (up < 0.5) {
		discard;
	}
	vec2 q = abs(local_pos.xz);
	float apothem = hex_size * 0.8660254;
	float e = apothem - max(q.y, dot(q, vec2(0.8660254, 0.5)));
	float w = max(fwidth(e), 0.0005);
	float edge = 1.0 - smoothstep(0.05 - w, 0.05 + w, e);
	float inner = 1.0 - smoothstep(0.0, 0.32, e);
	float beat = 1.0 + pulse * sin(TIME * 3.2);
	float a = fill_alpha * (0.55 + 0.6 * inner) * beat;
	if (style == 1) {
		float ring = smoothstep(0.13 - w, 0.13 + w, e) * (1.0 - smoothstep(0.17 - w, 0.17 + w, e));
		a = max(a, ring * 0.85);
	} else if (style == 2) {
		float c = (local_pos.x - local_pos.z) * 4.5;
		float cw = fwidth(c);
		float stripe = smoothstep(0.3 - cw, 0.3 + cw, abs(fract(c) - 0.5));
		a *= mix(0.55, 1.25, stripe);
	} else if (style == 3) {
		float d = length(local_pos.xz);
		float dot_ = 1.0 - smoothstep(0.1 - w, 0.1 + w, d);
		a = max(a, dot_ * 0.8);
	}
	a = max(a, edge * 0.95);
	// Slightly over-bright so outlines pick up a soft bloom.
	ALBEDO = color * (1.0 + 0.9 * edge);
	ALPHA = clamp(a, 0.0, 1.0);
}
