shader_type spatial;
render_mode unshaded;
// Bright, unshaded vertex colors (neon signs, lamp heads, screens, vending
// panels): colors above 1 bloom. Dimmed outside the play area.

#include "res://levels/board/tokyo_common.gdshaderinc"

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 c = COLOR.rgb;
	float o = outside_amount(wpos);
	c = mix(c, c * 0.3, o);
	ALBEDO = to_linear(mix(c, fog_color, data_fog(wpos)));
}
