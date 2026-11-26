shader_type spatial;
// Lit, vertex-colored low-poly surfaces of the Tokyo city (ground, water,
// street furniture, landmarks). Vertex / MultiMesh instance colors are sRGB.
// Outside the play area everything is shaded out (tokyo_common).

#include "res://levels/board/tokyo_common.gdshaderinc"

uniform float roughness_value = 0.85;
uniform float specular_value = 0.3;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 alb;
	vec3 em;
	fog_out(outside_shade(COLOR.rgb, wpos), vec3(0.0), wpos, alb, em);
	ALBEDO = alb;
	EMISSION = em;
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;
}
