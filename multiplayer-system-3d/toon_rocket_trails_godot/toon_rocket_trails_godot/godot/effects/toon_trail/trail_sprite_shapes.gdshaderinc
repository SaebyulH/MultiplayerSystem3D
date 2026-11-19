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

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float kind = floor(particle_data.r * 10.0 + 0.5);
	float age = particle_data.g;
	float seed = particle_data.b;
	float r = length(p);
	float a = atan(p.y, p.x);
	float aa = max(0.012, fwidth(r));
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
			ink = mix(ink, mix(vec3(1.0, 0.48, 0.04), vec3(1.0, 0.94, 0.52), 1.0 - age), core);
			tone = mix(1.0, 1.42, core);
		}
	} else if (kind == 3.0) {
		// Thin tapered streak with a bright leading tip.
		float span = clamp((p.y + 0.91) / 1.82, 0.0, 1.0);
		float d = max(abs(p.y) - 0.91, abs(p.x - 0.06 * sin(span * 3.14159)) - mix(0.06, 0.75, span));
		shape = (1.0 - smoothstep(-aa, aa, d)) * smoothstep(0.0, 0.43, span);
		tone = mix(0.74, 1.65, span);
	} else if (kind == 4.0) {
		// Flat, irregular shard rather than a shaded rock model.
		float edge = 0.70 + 0.12 * cos(a * 3.0 + seed * 13.0) + 0.09 * sin(a * 5.0 - seed * 9.0);
		float d = length(p * vec2(1.0, 1.23)) - edge;
		shape = 1.0 - smoothstep(-aa, aa, d);
		tone = mix(1.18, 0.58, smoothstep(-0.05, 0.05, p.x + p.y * 0.5));
	} else if (kind == 5.0) {
		float arms = pow(0.5 + 0.5 * cos((a + 0.2 * sin(a * 2.0)) * 6.0 + seed), 7.0);
		float d = r - (0.23 + 0.73 * arms);
		shape = 1.0 - smoothstep(-aa, aa, d);
		ink = mix(ink, vec3(1.0, 0.93, 0.57), 1.0 - smoothstep(0.05, 0.49, r));
		tone = 1.35;
	} else if (kind == 7.0) {
		float shell = 1.0 - smoothstep(0.055, 0.055 + aa, abs(r - 0.68));
		float glint = 1.0 - smoothstep(0.07, 0.13, length(p - vec2(-0.28, -0.35)));
		shape = max(shell * 0.65, glint);
		ink = mix(ink, vec3(0.58, 0.87, 1.0), 0.55);
	} else if (kind == 8.0) {
		float bend = 0.26 * sin(p.y * 13.0 + seed * 7.0) + 0.12 * sin(p.y * 24.0);
		float stroke = abs(p.x - bend);
		float ends = 1.0 - smoothstep(0.50, 0.94, abs(p.y));
		shape = (1.0 - smoothstep(0.038, 0.10 + aa, stroke)) * ends;
		tone = 1.42;
	} else {
		shape = pow(max(1.0 - r, 0.0), 2.7);
		tone = 1.15;
	}

	ALBEDO = ink * tone;
	ALPHA = shape * particle_color.a;
}
