shader_type spatial;
// Low-poly Tokyo: every box of the city (buildings, towers, pillars, decks)
// drawn from one MultiMesh of unit cubes. Flat colors, no textures: a
// facade pattern per building type (houses, balcony-banded apartments,
// office ribbon windows, lit shop fronts, glass towers, plain concrete),
// some rooms lit at dusk, and a parapet rim on the roofs.
//
// Per instance:
//   COLOR            base tint
//   INSTANCE_CUSTOM  x = style (TokyoCity.STYLE_*), y = seed (0..1),
//                    z = 1 for scenery outside the play area (unused:
//                    the play_rect test shades it),
//                    w = rows of windows per floor
// Edges are anti-aliased with fwidth so patterns stay clean when zoomed out.
// Colors (instance tints and the constants here) are authored in sRGB; the
// result is converted to linear at the end.
//
// Outside the battle zone buildings are plain grey boxes, shaded in a
// gradient; near the edge of the map data they fade into fog (tokyo_common). Around the
// selected character (`focus`: world position, w = radius), walls and roofs
// between it and the camera are cut away, so it and the street around it
// stay visible.

#include "res://levels/board/tokyo_common.gdshaderinc"

uniform vec4 focus = vec4(0.0, 0.0, 0.0, 0.0);
// The camera the cutaway is for (shadow passes render from the light and
// must not cut holes in the shadows).
uniform vec3 cut_camera = vec3(0.0);

uniform float floor_height = 1.0;
uniform float ground_y = 0.175;
uniform vec3 glass_color = vec3(0.16, 0.22, 0.31);
uniform vec3 lit_color : source_color = vec3(1.0, 0.8, 0.52);
uniform vec3 haze_color = vec3(0.5, 0.54, 0.64);
uniform float lit_share = 0.32;

const vec3 ROOFS[6] = vec3[6](vec3(0.62, 0.62, 0.6), vec3(0.42, 0.43, 0.45), vec3(0.47, 0.58, 0.5),
	vec3(0.5, 0.56, 0.64), vec3(0.72, 0.72, 0.7), vec3(0.6, 0.42, 0.36));

varying vec3 wpos;
varying vec3 wnorm;
varying vec3 lpos;
varying vec3 lnorm;
varying vec3 bsize;
varying flat vec4 info;
varying flat vec3 tint;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float band(float x, float lo, float hi, float w) {
	return smoothstep(lo - w, lo + w, x) * (1.0 - smoothstep(hi - w, hi + w, x));
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	bsize = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	lpos = VERTEX;
	lnorm = NORMAL;
	info = INSTANCE_CUSTOM;
	tint = COLOR.rgb;
}

void fragment() {
	int style = int(info.x + 0.5);
	float seed = info.y;
	vec3 col = tint;
	vec3 emit = vec3(0.0);
	float rough = 0.9;
	float spec = 0.3;
	float h = wpos.y - ground_y;
	float top = bsize.y;  // height of this box

	if (lnorm.y > 0.5) {
		// Roof: a darker membrane with a light parapet rim.
		vec2 e = (0.5 - abs(lpos.xz)) * bsize.xz;
		float rim = min(e.x, e.y);
		float w = fwidth(rim) + 0.001;
		int ri = int(fract(seed * 13.7) * 6.0);
		if (style != 0 && ri == 5) ri = 1;   // rust roofs on houses only
		col = ROOFS[ri];
		if (style >= 20) {
			// Deck top: road / track bed with barrier walls along the edges.
			col = style == 20 ? vec3(0.36, 0.33, 0.31) : vec3(0.27, 0.28, 0.30);
			float side = e.y;
			if (style == 20) {
				// Two rails down the middle of each track.
				float rail = band(abs(lpos.z * bsize.z), 0.26, 0.33, fwidth(lpos.z * bsize.z));
				col = mix(col, vec3(0.62, 0.62, 0.66), rail);
			} else {
				float lane = band(abs(lpos.z * bsize.z), 0.0, 0.03, fwidth(lpos.z * bsize.z));
				col = mix(col, vec3(0.85, 0.85, 0.8), lane * step(0.5, fract(lpos.x * bsize.x * 0.4)));
			}
			col = mix(col, vec3(0.66, 0.66, 0.64), 1.0 - smoothstep(0.08 - w, 0.08 + w, side));
		} else {
			col = mix(col, tint * 0.95, 1.0 - smoothstep(0.08 - w, 0.08 + w, rim));
			col = mix(col, col * 0.78, band(rim, 0.08, 0.13, w));
		}
	} else if (lnorm.y < -0.5) {
		col = tint * 0.45;
	} else {
		// Walls: u runs along the face (0 at one end), its width in units.
		bool along_x = abs(lnorm.z) > 0.5;
		float width = along_x ? bsize.x : bsize.z;
		float u = (along_x ? lpos.x : lpos.z) * width + width * 0.5;
		if (style == 10 || style >= 20) {
			// Concrete pillars and deck sides: plain, a darker foot.
			col = tint * mix(0.78, 1.0, smoothstep(0.0, 0.6, h));
			if (style >= 20) {
				float y = lpos.y + 0.5;
				col = mix(col, tint * 0.7, step(y, 0.35));
			}
		} else if (style == 12 || style == 13) {
			// Temple halls and gate posts: vermilion with dark wood bands.
			float y = h / max(top, 0.01);
			float n = max(1.0, floor(width / 0.6));
			float fx = fract(u / (width / n));
			col = mix(tint, tint * 0.55, band(fx, 0.0, 0.12, fwidth(fx)) + band(fx, 0.88, 1.0, fwidth(fx)));
			col = mix(col, vec3(0.16, 0.12, 0.1), band(y, 0.86, 1.0, fwidth(y)));
		} else {
			float rows = max(1.0, info.w);
			float fh = floor_height / rows;
			float fy = h / fh;
			float row = floor(fy);
			float ry = fract(fy);
			float cw = style == 0 ? 0.62 : style == 1 ? 0.5 : style == 2 ? 0.36 : style == 11 ? 0.26 : 0.55;
			float n = max(1.0, floor(width / cw));
			float cu = u / (width / n);
			float fx = fract(cu);
			float cx = floor(cu);
			float wy = fwidth(fy) + 0.001;
			float wx = fwidth(cu) + 0.001;
			// Keep a margin at the corners of the face.
			float edge = smoothstep(0.08, 0.16, min(u, width - u));
			float win = 0.0;
			float lit = step(hash(vec2(cx + seed * 97.0, row + seed * 31.0) + floor(wpos.xz * 0.05)), lit_share);
			if (style == 0) {
				// House: small square windows, one row per floor.
				win = band(fx, 0.28, 0.72, wx) * band(ry, 0.38, 0.78, wy);
				lit *= step(0.4, hash(vec2(cx, row) + seed));
			} else if (style == 1 || style == 7) {
				// Apartments / schools: balcony parapet band, glass above.
				float balcony = 1.0 - smoothstep(0.34 - wy, 0.34 + wy, ry);
				col = mix(col, mix(col, vec3(0.95, 0.94, 0.9), 0.55), balcony * edge);
				win = band(fx, 0.1, 0.9, wx) * band(ry, 0.42, 0.88, wy);
			} else if (style == 2 || style == 5) {
				// Offices / stations: ribbon windows with thin mullions.
				win = band(fx, 0.06, 0.94, wx) * band(ry, 0.3, 0.86, wy);
			} else if (style == 11) {
				// Glass towers: nearly all glass, slim spandrels.
				win = band(fx, 0.05, 0.95, wx) * band(ry, 0.14, 0.92, wy);
				lit *= 0.8;
			} else {
				// Shops: lit storefront at street level, windows above.
				if (h < floor_height * 0.92) {
					float sf = band(h, 0.08, 0.7, fwidth(h)) * band(fx, 0.04, 0.96, wx);
					win = sf;
					lit = 1.0;
				} else {
					win = band(fx, 0.15, 0.85, wx) * band(ry, 0.3, 0.8, wy);
				}
			}
			win *= edge;
			// Far away, windows blend into a flat facade tone (no shimmer).
			float detail = 1.0 - smoothstep(0.25, 0.6, max(wx, wy));
			vec3 glass = glass_color * mix(0.85, 1.2, hash(vec2(cx, row) + seed));
			vec3 flat_tone = mix(col, glass, 0.32);
			col = mix(flat_tone, mix(col, glass, win), detail);
			emit = lit_color * win * lit * 0.85 * detail + lit_color * lit_share * 0.12 * (1.0 - detail);
			rough = mix(rough, 0.25, win);
			spec = mix(spec, 0.6, win);
			// Cornice at the top and a darker street-level band.
			col = mix(col, col * 0.7, band(h, top - 0.07, top + 0.01, fwidth(h)));
			if (style != 3) {
				col = mix(col, col * 0.78, 1.0 - smoothstep(0.1, 0.12, h));
			}
		}
	}
	if (focus.w > 0.0 && distance(INV_VIEW_MATRIX[3].xyz, cut_camera) < 0.5) {
		// Cutaway: VERTEX is the fragment in view space (the camera looks
		// down -z); cut what is nearer the camera than the character and
		// within `focus.w` of it on screen, with a dithered rim.
		vec3 fv = (VIEW_MATRIX * vec4(focus.xyz, 1.0)).xyz;
		float d = length(VERTEX.xy - fv.xy);
		if (VERTEX.z > fv.z + 0.4 && d < focus.w) {
			float edge = smoothstep(focus.w * 0.7, focus.w, d);
			vec2 px = floor(FRAGCOORD.xy);
			float dither = fract(dot(px, vec2(0.5, 0.25)) + 0.125 * mod(px.y, 2.0));
			if (dither >= edge) {
				discard;
			}
		}
	}
	// Outside the zone: plain grey boxes, no windows or lights.
	float o = outside_amount(wpos);
	vec3 grey_box = vec3(0.6 + 0.08 * seed) * (lnorm.y > 0.5 ? 1.08 : lnorm.y < -0.5 ? 0.5 : 0.9);
	col = mix(col, grey_box, o);
	emit *= 1.0 - o;
	rough = mix(rough, 0.95, o);
	spec = mix(spec, 0.2, o);
	col = outside_shade(col, wpos);
	vec3 alb;
	vec3 em;
	fog_out(col, emit, wpos, alb, em);
	ALBEDO = alb;
	ROUGHNESS = rough;
	SPECULAR = spec;
	EMISSION = em;
}
