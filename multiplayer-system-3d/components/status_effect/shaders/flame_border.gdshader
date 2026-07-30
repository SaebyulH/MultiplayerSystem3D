shader_type canvas_item;

// Flame border shader — animated fire at screen edges.
// Uses layered noise to create flame-tongue shapes, warmer near the bottom,
// rising upward with flicker.

uniform float u_time : hint_range(0.0, 3600.0) = 0.0;

// Simple random hash.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 2D value noise.
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

// Fractal noise — multiple octaves for flame detail.
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 3; i++) {
		v += a * noise(p * freq);
		freq *= 2.1;
		a *= 0.55;
	}
	return v;
}

void fragment() {
	// Distance to nearest edge (0 at edge, ~0.5 at center).
	float d = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	float band = d / 0.07;  // border width

	// Falloff — sharp at inner edge, soft at outer.
	float falloff = 1.0 - smoothstep(0.0, 1.0, band);

	// Flame shape: use noise modulated by vertical position.
	// Y=0 is top, Y=1 is bottom.  "flame_y" = 1 at bottom, 0 at top edge.
	float flame_y = 0.0;
	if (d == UV.y) {
		// Bottom edge: full flame height.
		flame_y = 1.0 - band;  // 1 at edge, 0 at inner boundary
	} else if (d == 1.0 - UV.y) {
		// Top edge: shorter flames.
		flame_y = (1.0 - band) * 0.3;
	} else {
		// Side edges: flames taper as they go up.
		float side_h = UV.y; // 0 at top, 1 at bottom
		flame_y = (1.0 - band) * (0.3 + side_h * 0.7);
	}

	// Noise for flame tongues — moves upward over time.
	vec2 noise_uv = UV * vec2(12.0, 18.0) + vec2(0.0, u_time * 1.5);
	float tongue = fbm(noise_uv);
	tongue = tongue * 0.6 + 0.4; // 0.4 .. 1.0

	// Flame shape: band intensity modulated by noise.
	float flame = falloff * flame_y * tongue;

	// Flicker: fast small-amplitude variation.
	float flicker = 1.0 + sin(u_time * 25.0 + UV.x * 40.0) * 0.08 + sin(u_time * 37.0 + UV.y * 50.0) * 0.06;

	// Color: gradient from yellow (hottest, at edge) to orange to red (cooler, inner).
	// t=0 at edge (yellow), t=1 at inner boundary (dark red/transparent).
	float t = band;  // 0=edge, 1=inner-boundary, >1=transparent
	vec3 fire_color = mix(
		vec3(1.0, 0.85, 0.1),   // yellow-orange at edge
		vec3(0.9, 0.25, 0.02),  // deep orange-red inner
		clamp(t, 0.0, 1.0)
	);
	// Add some variation based on noise for richer color.
	fire_color = mix(fire_color, vec3(1.0, 0.55, 0.05), tongue * 0.4);

	float alpha = flame * flicker;
	alpha = clamp(alpha, 0.0, 1.0);

	// Fade to transparent beyond the band.
	if (band > 1.0) {
		alpha = 0.0;
	}

	COLOR = vec4(fire_color, alpha * 0.75);
}
