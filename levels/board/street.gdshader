shader_type spatial;
// Continuous city ground (one surface under the whole map): asphalt roads,
// straight concrete sidewalks with a curb around every building, painted
// avenue markings (dashed center lines, zebra crossings), and manhole
// covers. Sidewalks/curbs come from `sidewalk_mask` (R = sidewalk, G = curb),
// baked from the building rectangles; markings are drawn analytically.

uniform sampler2D sidewalk_mask : filter_linear, repeat_disable;
uniform vec2 mask_origin = vec2(0.0);     // world XZ of the mask's corner
uniform vec2 mask_size = vec2(1.0);       // world XZ size covered by the mask
uniform vec4 map_rect = vec4(0.0, 0.0, 1.0, 1.0);  // playable area x0, z0, x1, z1
// Avenues (world space). Far away when unused.
uniform float avenue_z = -1000.0;
uniform vec2 avenue_z_span = vec2(-1000.0, -999.0);
uniform float avenue_x = -1000.0;
uniform vec2 avenue_x_span = vec2(-1000.0, -999.0);

varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 wp = world_pos.xz;
	vec2 m = texture(sidewalk_mask, (wp - mask_origin) / mask_size).rg;
	float sidewalk = step(0.5, m.r);
	float curb = step(0.5, m.g) * (1.0 - sidewalk);

	// Asphalt.
	float grain = noise(wp * 9.0) * 0.6 + noise(wp * 2.1) * 0.4;
	vec3 col = vec3(0.17, 0.18, 0.2) * (0.86 + 0.28 * grain);
	col += vec3(0.025) * step(0.975, hash(floor(wp * 38.0)));
	float rough = 0.72;

	// Avenue markings (road only, never on sidewalks).
	float dash_h = step(abs(wp.y - avenue_z), 0.045) * step(fract(wp.x / 1.3), 0.55);
	float dash_v = step(abs(wp.x - avenue_x), 0.045) * step(fract(wp.y / 1.3), 0.55);
	// Keep center lines out of the intersection box.
	float in_v = step(avenue_x_span.x, wp.x) * step(wp.x, avenue_x_span.y);
	float in_h = step(avenue_z_span.x, wp.y) * step(wp.y, avenue_z_span.y);
	dash_h *= 1.0 - in_v;
	dash_v *= 1.0 - in_h;
	// Zebra crossings squared to the intersection: across the vertical avenue
	// just north/south of the crossing street, and across the horizontal one
	// just west/east of it. Bars run along the traffic direction.
	float band = 0.36;
	float zebra_v = in_v * step(fract(wp.x / 0.3), 0.5) * max(
		step(abs(wp.y - (avenue_z_span.x - band - 0.12)), band),
		step(abs(wp.y - (avenue_z_span.y + band + 0.12)), band));
	float zebra_h = in_h * step(fract(wp.y / 0.3), 0.5) * max(
		step(abs(wp.x - (avenue_x_span.x - band - 0.12)), band),
		step(abs(wp.x - (avenue_x_span.y + band + 0.12)), band));
	float road = 1.0 - sidewalk - curb;
	col = mix(col, vec3(0.85, 0.72, 0.3), clamp(dash_h + dash_v, 0.0, 1.0) * road);
	col = mix(col, vec3(0.8, 0.81, 0.83), clamp(zebra_v + zebra_h, 0.0, 1.0) * road);

	// Manhole covers on a sparse grid (roads only).
	vec2 cell = floor(wp / 3.0);
	vec2 c = (cell + 0.25 + 0.5 * vec2(hash(cell), hash(cell + 7.0))) * 3.0;
	float d = length(wp - c);
	float has_hole = step(0.8, hash(cell + 3.1)) * road;
	col = mix(col, vec3(0.09, 0.09, 0.1), has_hole * step(d, 0.17) * (1.0 - step(d, 0.14)));
	col = mix(col, vec3(0.24, 0.24, 0.26), has_hole * step(d, 0.14));

	// Sidewalk pavers and curb.
	vec2 pg = fract(wp / 0.4);
	float grout = max(step(pg.x, 0.06), step(pg.y, 0.06));
	vec3 paver = vec3(0.5, 0.49, 0.47) * (0.9 + 0.12 * hash(floor(wp / 0.4))) * (1.0 - 0.28 * grout);
	col = mix(col, paver, sidewalk);
	col = mix(col, vec3(0.66, 0.66, 0.64), curb);
	rough = mix(rough, 0.92, max(sidewalk, curb));

	// Outside the playable map: darker, so the board edge reads clearly.
	float outside = 1.0 - step(map_rect.x, wp.x) * step(wp.x, map_rect.z) * step(map_rect.y, wp.y) * step(wp.y, map_rect.w);
	col *= mix(1.0, 0.45, outside);

	ALBEDO = col;
	ROUGHNESS = rough;
}
