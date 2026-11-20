varying vec4 particle_data;
varying vec4 particle_color;

void vertex() {
	particle_data = INSTANCE_CUSTOM;
	particle_color = COLOR;
}

float disk(vec2 p, float r) {
	return length(p) - r;
}

float cloud(vec2 p, float seed) {
	float shape = disk(p * vec2(1.0, 1.12), 0.62);
	for (int i = 0; i < 6; i++) {
		float a = float(i) * 1.047198 + seed * 6.283185;
		float scatter = fract(sin(float(i) * 891.37 + seed * 91.71) * 471.17);
		vec2 center = vec2(cos(a), sin(a)) * mix(0.36, 0.58, scatter);
		shape = min(shape, disk(p - center, mix(0.25, 0.40, scatter)));
	}
	return shape;
}

uniform bool self_add = false;
uniform bool preserve_tint = false;
// Multiplied into the final radiance so the legacy fallback can tint one scene
// per weapon (green heal, purple poison) without duplicating the particle graph.
uniform vec3 tint = vec3(1.0);
// Scales colour away from its luminance. Filmic tonemapping desaturates the
// bright additive layers toward white; >1 restores the authored hue without
// changing the procedural shapes or the layer weights.
uniform float saturation = 1.0;

// Original procedural bolt: disconnected branches and sharp, irregular bends.
float bolt_segment(vec2 p, vec2 a, vec2 b) {
	vec2 d = b - a;
	return length(p - a - d * clamp(dot(p - a, d) / dot(d, d), 0.0, 1.0));
}

float bolt(vec2 p, float seed) {
	vec2 prev = vec2(0.04 * sin(seed * 43.0), -0.91);
	float d = 3.0;
	for (int i = 1; i <= 7; i++) {
		float j = float(i);
		vec2 next = vec2(sin(seed * 39.0 + j * 9.1) * 0.23, -0.91 + j * 0.26);
		d = min(d, bolt_segment(p, prev, next));
		if (i == 2 || i == 5) {
			vec2 fork = next + vec2(i == 2 ? 0.42 : -0.34, 0.23);
			d = min(d, bolt_segment(p, next, fork) + 0.018);
		}
		prev = next;
	}
	return d;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float kind = floor(particle_data.r * 16.0 + 0.5);
	float age = particle_data.g;
	float seed = particle_data.b;
	float r = length(p);
	float a = atan(p.y, p.x);
	float aa = clamp(fwidth(r), 0.012, 0.075);
	float shape = 0.0;
	vec3 ink = particle_color.rgb;
	float tone = 1.0;

	if (kind == 0.0) {
		// Broken, uneven ring, seen edge-on when the impact plane turns away.
		float rim = 0.69 + 0.032 * sin(a * 9.0 + seed * 17.0) + 0.022 * sin(a * 17.0);
		float width = mix(0.13, 0.070, age) * (0.75 + 0.25 * cos(a * 6.0 + seed * 12.0));
		float breaks = smoothstep(-0.82, -0.42, sin(a * 4.0 + seed * 24.0) + 0.30 * cos(a * 11.0));
		shape = (1.0 - smoothstep(width - aa, width + aa, abs(r - rim))) * breaks;
		tone = 0.82 + 0.18 * smoothstep(rim - width, rim + width, r);
	} else if (kind == 1.0 || kind == 2.0) {
		// Smoke and flame share a silhouette but use different fill and ink.
		float d = cloud(p, seed);
		shape = 1.0 - smoothstep(-aa, aa, d);
		if (kind == 1.0) {
			float inset = smoothstep(-0.02, 0.04, cloud(p + vec2(-0.11, 0.17), seed));
			tone = mix(1.16, 0.55, inset) * mix(0.67, 1.03, smoothstep(-0.62, 0.56, p.x - p.y));
		} else {
			float core = 1.0 - smoothstep(-0.11, -0.02, cloud(p * 1.23 + vec2(0.06, 0.12), seed));
			ink = mix(ink, vec3(1.0), core * mix(0.17, 0.55, 1.0 - age) * (preserve_tint ? 0.0 : 1.0));
			tone = mix(1.0, 1.42, core);
		}
	} else if (kind == 3.0) {
		// Limit screen-space smoothing to an interior silhouette even on
		// a highly stretched card. Both tips have zero coverage.
		float span = clamp((p.y + 0.93) / 1.86, 0.0, 1.0);
		float nose = sqrt(max(0.0, 1.0 - pow(max(0.0, (span - 0.76) / 0.24), 2.0)));
		float width = mix(0.035, 0.66, pow(span, 0.78)) * nose;
		float wall = abs(p.x - 0.035 * sin(span * 3.14159)) - width;
		float feather = clamp(fwidth(wall), 0.024, 0.090);
		float cap = smoothstep(0.0, 0.27, span) * (1.0 - smoothstep(0.86, 1.0, span));
		shape = (1.0 - smoothstep(-feather, feather, wall)) * cap;
		tone = mix(0.78, 1.42, span);
	} else if (kind == 4.0) {
		// Flat, irregular shard rather than a shaded rock model.
		float edge = 0.70 + 0.12 * cos(a * 3.0 + seed * 13.0) + 0.09 * sin(a * 5.0 - seed * 9.0);
		float d = length(p * vec2(1.0, 1.23)) - edge;
		shape = 1.0 - smoothstep(-aa, aa, d);
		tone = mix(1.18, 0.58, smoothstep(-0.05, 0.05, p.x + p.y * 0.5));
	} else if (kind == 5.0) {
		float arms = pow(0.5 + 0.5 * cos((a + 0.12 * sin(a * 2.0)) * 6.0 + seed), 11.0);
		float core = 1.0 - smoothstep(0.10, 0.41, r);
		float ray = (1.0 - smoothstep(0.22, 0.99, r)) * arms;
		float outer = (1.0 - smoothstep(0.27, 0.98, r)) * exp(-5.0 * r);
		shape = max(core, ray * ray * 0.44) + outer * 0.26;
		ink = mix(ink, vec3(1.0), core * (preserve_tint ? 0.0 : 0.54));
		tone = 1.12 + 0.23 * core;
	} else if (kind == 7.0) {
		float outline = 1.0 - smoothstep(0.036, 0.036 + aa, abs(r - 0.68));
		float glint = (1.0 - smoothstep(0.08, 0.13, length(p - vec2(-0.30, -0.36))));
		shape = max(outline * 0.72, glint) + 0.12 * (1.0 - smoothstep(0.62, 0.70, r));
		ink = mix(ink, vec3(0.63, 0.87, 1.0), 0.6);
	} else if (kind == 8.0 || kind == 9.0) {
		float d = bolt(p, seed);
		float thickness = kind == 9.0 ? 0.033 : 0.041;
		float core = 1.0 - smoothstep(thickness, thickness + 0.026, d);
		float halo = 1.0 - smoothstep(thickness, thickness + 0.105, d);
		shape = max(core, halo * 0.42);
		ink = mix(ink, vec3(1.0), core * 0.31);
		tone = 1.08 + 0.24 * core;
	} else if (kind == 10.0) {
		float d = cloud(vec2(p.x * 1.15, p.y * 0.96), seed);
		shape = (1.0 - smoothstep(-aa, aa, d)) * smoothstep(-1.0, -0.23, p.y);
		tone = 0.78 + 0.22 * smoothstep(-0.75, 0.6, p.y);
	} else if (kind == 11.0) {
		shape = 1.0 - smoothstep(0.48, 0.62 + aa, r);
		tone = 1.07;
	} else {
		shape = pow(max(1.0 - r, 0.0), 2.7);
		tone = 1.15;
	}

	float gain = max(1.0, particle_data.a * 8.0);
	float brightness = 1.0 + 0.29 * log2(gain);
	float card_edge = max(abs(p.x), abs(p.y));
	float opacity = shape * particle_color.a * (1.0 - smoothstep(0.972, 1.0, card_edge));
	vec3 radiance = ink * tone * brightness;
	if (preserve_tint) {
		radiance /= max(1.0, max(radiance.r, max(radiance.g, radiance.b)));
		if (kind == 5.0 || kind == 6.0) {
			opacity *= 0.82;
		}
	}
	radiance *= tint;
	float luma = dot(radiance, vec3(0.2126, 0.7152, 0.0722));
	radiance = max(mix(vec3(luma), radiance, saturation), vec3(0.0));
	if (self_add) {
		ALBEDO = radiance * opacity;
		ALPHA = opacity * 0.63;
	} else {
		ALBEDO = radiance;
		ALPHA = opacity;
	}
}
