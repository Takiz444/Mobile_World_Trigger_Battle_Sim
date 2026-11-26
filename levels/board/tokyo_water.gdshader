shader_type spatial;
// Rivers, canals and ponds, low-poly: a faceted surface with slow flow
// streaks drifting along `flow`, light ripple bands, and glints of the
// sky. Shaded out beyond the battle zone (tokyo_common).

#include "res://levels/board/tokyo_common.gdshaderinc"

uniform vec3 deep_color = vec3(0.12, 0.31, 0.43);
uniform vec3 light_color = vec3(0.3, 0.55, 0.66);
uniform vec2 flow = vec2(0.35, 0.12);

varying vec3 wpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz - flow * TIME;
	// Two crossing wave trains, quantised into flat facets.
	float a = sin(p.x * 1.3 + p.y * 0.45) * sin(p.y * 1.9 - p.x * 0.35 + TIME * 0.6);
	float b = sin(p.x * 2.7 - p.y * 2.1 + TIME * 1.1);
	float w = a * 0.65 + b * 0.35;
	float facet = floor(w * 3.0 + 0.5) / 3.0;
	vec3 col = mix(deep_color, light_color, 0.3 + 0.22 * facet);
	// Long pale streaks along the flow.
	vec2 f = normalize(flow);
	float along = dot(p, f);
	float across = dot(p, vec2(-f.y, f.x));
	float streak = smoothstep(0.82, 1.0, sin(across * 3.2 + sin(along * 0.4) * 1.5)) * (0.5 + 0.5 * sin(along * 0.9));
	col = mix(col, vec3(0.55, 0.72, 0.8), streak * 0.16);
	// Sparkles where the facets catch the light.
	vec2 cell = floor(wpos.xz * 2.0);
	float sparkle = step(0.994, hash(cell + floor(TIME * 1.5))) * step(0.4, facet);
	col += vec3(0.4, 0.45, 0.48) * sparkle;
	// Tilted facet normals for the specular highlights.
	vec3 n = normalize(vec3(-0.25 * a, 1.0, -0.25 * b));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	vec3 alb;
	vec3 em;
	fog_out(outside_shade(col, wpos), vec3(0.0), wpos, alb, em);
	ALBEDO = alb;
	EMISSION = em;
	ROUGHNESS = 0.12;
	SPECULAR = 0.65;
}
