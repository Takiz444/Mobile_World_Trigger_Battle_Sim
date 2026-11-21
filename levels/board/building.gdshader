shader_type spatial;
// City building facade: concrete walls with a window grid per floor (some
// rooms lit at dusk, the rest dark reflective glass), floor slab lines, a
// darker street-level band, and a flat roof finish. Each building sets its
// own `tint` via set_instance_shader_parameter().
//
// All edges are anti-aliased analytically (fwidth), so windows stay crisp
// without shimmering when the camera zooms out.

instance uniform vec3 tint : source_color = vec3(0.8, 0.8, 0.82);
uniform vec3 glass_color : source_color = vec3(0.32, 0.52, 0.72);
uniform vec3 roof_color : source_color = vec3(0.36, 0.38, 0.42);
uniform vec3 rim_color : source_color = vec3(0.55, 0.68, 1.0);
uniform float floor_height = 1.0;
uniform float ground_y = 0.175;
uniform float window_spacing = 0.45;

varying vec3 world_pos;
varying vec3 world_normal;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 1 inside [lo, hi] of a repeating 0..1 coordinate, with edges softened by
// the pixel footprint `w`.
float band(float x, float lo, float hi, float w) {
	return smoothstep(lo - w, lo + w, x) * (1.0 - smoothstep(hi - w, hi + w, x));
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (world_normal.y > 0.5) {
		// Roof: flat membrane with a faint tile grid, a little grime, and a
		// darker margin where it meets the parapet.
		vec2 uv = world_pos.xz * 1.6;
		vec2 g = abs(fract(uv) - 0.5);
		vec2 w = fwidth(uv);
		float seam = 1.0 - min(smoothstep(0.46 - w.x, 0.46 + w.x, g.x) + smoothstep(0.46 - w.y, 0.46 + w.y, g.y), 1.0);
		float grime = hash(floor(world_pos.xz * 0.8)) * 0.08;
		ALBEDO = roof_color * mix(0.88, 1.0, seam) * (1.0 - grime);
		ROUGHNESS = 0.9;
	} else {
		float h = world_pos.y - ground_y;
		float fyc = h / floor_height;
		float fy = fract(fyc);
		float along = abs(world_normal.x) > 0.5 ? world_pos.z : world_pos.x;
		float fxc = along / window_spacing;
		float fx = fract(fxc);
		float wy = fwidth(fyc) * 1.2;
		float wx = fwidth(fxc) * 1.2;
		float street_level = 1.0 - step(floor_height, h);

		// Taller storefront glazing at street level, punched windows above.
		float win_upper = band(fy, 0.3, 0.75, wy) * band(fx, 0.2, 0.8, wx);
		float win_street = band(fy, 0.25, 0.8, wy) * band(fx, 0.08, 0.92, wx);
		float window = mix(win_upper, win_street, street_level);
		// Thin mullion splitting each upper window in two.
		window *= 1.0 - (1.0 - street_level) * band(fx, 0.485, 0.515, wx);

		vec3 wall = tint * mix(1.0, 0.8, street_level);
		// Floor slab line and a soft sill shadow under each window row.
		wall *= mix(1.0, 0.8, 1.0 - smoothstep(0.07 - wy, 0.07 + wy, fy));
		wall *= mix(1.0, 0.93, band(fy, 0.2, 0.3, wy) * (1.0 - street_level));
		// Grounding: darken toward the street, lighten slightly toward the roof.
		wall *= mix(0.72, 1.0, smoothstep(0.0, 0.9, h));
		wall *= 1.0 + 0.03 * clamp(h / (floor_height * 4.0), 0.0, 1.0);

		// At dusk some rooms have their lights on; the rest are dark glass
		// reflecting the sky. Lit rooms vary in warmth and brightness, and a
		// few have the cold flicker-free glow of a screen.
		vec2 cell = vec2(floor(fxc) + world_normal.x * 37.0 + world_normal.z * 91.0, floor(fyc));
		float r = hash(cell + tint.rg * 13.0);
		float r2 = hash(cell * 1.7 + 4.2);
		float lit = step(0.6, r);
		vec3 warm = mix(vec3(1.0, 0.72, 0.42), vec3(1.0, 0.9, 0.7), r2);
		warm = mix(warm, vec3(0.62, 0.8, 1.0), step(0.9, r2));
		float brightness = mix(0.45, 1.0, hash(cell + 9.1));
		// Light falls off toward the top of the room (ceiling lamp glow below).
		float room = mix(0.7, 1.0, smoothstep(0.75, 0.3, fy));
		vec3 glass_albedo = mix(glass_color * 0.55, warm * 0.8, lit);
		vec3 glass_emit = mix(glass_color * 0.1, warm * brightness * room, lit);

		ALBEDO = mix(wall, glass_albedo, window);
		EMISSION = glass_emit * window;
		ROUGHNESS = mix(0.85, mix(0.08, 0.4, lit), window);
		METALLIC = mix(0.0, mix(0.6, 0.0, lit), window);
		// Cool sky rim on wall silhouettes keeps blocks readable in shadow.
		float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
		EMISSION += rim_color * fres * 0.05 * (1.0 - window);
	}
}
