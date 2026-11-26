// Shared by the Tokyo city shaders.
//
// Three rings around a match:
//  * the battle zone (zone_pts, the zone polygon): drawn in full;
//  * the rest of the district's map data: "out of the simulation". Buildings
//    there are plain grey boxes (the building shader asks outside_amount),
//    and everything darkens in a gradient with distance from the zone;
//  * beyond the map data (data_rect, the district's extent): fog. It thickens
//    over the last stretch of data, along a wavy (never straight) front, so
//    the city never visibly ends.

const int ZONE_MAX = 64;
uniform vec2 zone_pts[64];
uniform int zone_n = 0;
uniform vec4 data_rect = vec4(-100000.0, -100000.0, 200000.0, 200000.0);
uniform vec3 outside_tone = vec3(0.08, 0.09, 0.15);
// How far outside the zone the shade reaches its darkest.
uniform float shade_reach = 30.0;
// Fog: sRGB color; starts fog_in inside the data edge, opaque fog_full inside.
uniform vec3 fog_color = vec3(0.27, 0.3, 0.4);
uniform float fog_in = 20.0;
uniform float fog_full = 3.0;

// Signed distance to the zone polygon (> 0 outside).
float zone_distance(vec2 p) {
	if (zone_n < 3) {
		return -1.0;
	}
	float d = 1e9;
	bool inside = false;
	vec2 a = zone_pts[zone_n - 1];
	for (int i = 0; i < ZONE_MAX; i++) {
		if (i >= zone_n) {
			break;
		}
		vec2 b = zone_pts[i];
		vec2 e = b - a;
		vec2 w = p - a;
		float t = clamp(dot(w, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
		d = min(d, length(w - e * t));
		if ((a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) / (b.y - a.y) * e.x) {
			inside = !inside;
		}
		a = b;
	}
	return inside ? -d : d;
}

// 1 outside the zone, 0 inside, with a crisp anti-aliased edge.
float outside_amount(vec3 wpos) {
	return smoothstep(-0.03, 0.03, zone_distance(wpos.xz));
}

// The gradient shade outside the zone: 0 at its edge, 1 at shade_reach.
float outside_depth(vec3 wpos) {
	return smoothstep(0.0, shade_reach, zone_distance(wpos.xz));
}

float fog_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float h00 = fract(sin(dot(i, vec2(127.1, 311.7))) * 43758.5453);
	float h10 = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
	float h01 = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	float h11 = fract(sin(dot(i + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

// 0 well inside the map data, 1 at (and past) its edge.
float data_fog(vec3 wpos) {
	vec2 lo = wpos.xz - data_rect.xy;
	vec2 hi = data_rect.xy + data_rect.zw - wpos.xz;
	float inside = min(min(lo.x, lo.y), min(hi.x, hi.y));
	// A wavy front: billows of a few units, so no edge reads as a line.
	float n = fog_noise(wpos.xz * 0.07) * 0.65 + fog_noise(wpos.xz * 0.19 + 17.0) * 0.35;
	inside += (n - 0.5) * 9.0;
	// Tall things fade a little sooner (their tops stand out of the fog).
	inside -= max(wpos.y, 0.0) * 0.25;
	return 1.0 - smoothstep(fog_full, fog_in, inside);
}

// Colors are authored in sRGB; this works in sRGB and leaves the conversion
// to the caller. Outside the zone: greyed and darkened in a gradient.
vec3 outside_shade(vec3 srgb, vec3 wpos) {
	float o = outside_amount(wpos);
	float g = outside_depth(wpos);
	float grey = dot(srgb, vec3(0.3, 0.59, 0.11));
	vec3 dim = mix(vec3(grey), outside_tone, 0.15) * mix(0.85, 0.4, g);
	return mix(srgb, dim, o);
}

vec3 to_linear(vec3 srgb) {
	return pow(max(srgb, vec3(0.0)), vec3(2.2));
}

// Final output for lit shaders: fog replaces the surface (as emission, so it
// is one flat veil whatever the lighting).
void fog_out(vec3 srgb, vec3 emit, vec3 wpos, out vec3 albedo, out vec3 emission) {
	float f = data_fog(wpos);
	albedo = to_linear(srgb) * (1.0 - f);
	emission = emit * (1.0 - f) + to_linear(fog_color) * f;
}
