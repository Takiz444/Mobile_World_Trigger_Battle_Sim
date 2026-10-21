shader_type spatial;
// City building facade: concrete walls with a window grid per floor (some
// rooms lit warm at dusk, the rest dark reflective glass), floor slab lines, a darker
// street-level band, and a flat roof finish. Each building sets its own
// `tint` via set_instance_shader_parameter().

instance uniform vec3 tint : source_color = vec3(0.8, 0.8, 0.82);
uniform vec3 glass_color : source_color = vec3(0.32, 0.52, 0.72);
uniform vec3 roof_color : source_color = vec3(0.36, 0.38, 0.42);
uniform float floor_height = 1.0;
uniform float ground_y = 0.175;
uniform float window_spacing = 0.45;

varying vec3 world_pos;
varying vec3 world_normal;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (world_normal.y > 0.5) {
		// Roof: flat membrane with a faint tile grid.
		vec2 g = fract(world_pos.xz * 1.6);
		float seam = step(g.x, 0.04) + step(g.y, 0.04);
		ALBEDO = roof_color * (1.0 - 0.12 * clamp(seam, 0.0, 1.0));
		ROUGHNESS = 0.9;
	} else {
		float h = world_pos.y - ground_y;
		float fy = fract(h / floor_height);
		float along = abs(world_normal.x) > 0.5 ? world_pos.z : world_pos.x;
		float fx = fract(along / window_spacing);
		bool street_level = h < floor_height;
		// Taller storefront glazing at street level, punched windows above.
		bool window = street_level
			? (fy > 0.25 && fy < 0.8 && fx > 0.08 && fx < 0.92)
			: (fy > 0.3 && fy < 0.75 && fx > 0.2 && fx < 0.8);
		vec3 wall = tint * (street_level ? 0.82 : 1.0);
		if (fy < 0.07) {
			wall *= 0.8;  // floor slab line
		}
		if (window) {
			// At dusk some rooms have their lights on (warm), the rest are
			// dark glass reflecting the sky.
			vec2 cell = vec2(floor(along / window_spacing) + world_normal.x * 37.0 + world_normal.z * 91.0,
				floor(h / floor_height));
			float lit = step(0.6, hash(cell + tint.rg * 13.0));
			vec3 warm = vec3(1.0, 0.82, 0.55);
			ALBEDO = mix(glass_color * 0.6, warm * 0.8, lit);
			EMISSION = mix(glass_color * 0.12, warm * 0.9, lit);
			ROUGHNESS = mix(0.08, 0.4, lit);
			METALLIC = mix(0.6, 0.0, lit);
		} else {
			ALBEDO = wall;
			ROUGHNESS = 0.85;
		}
	}
}
