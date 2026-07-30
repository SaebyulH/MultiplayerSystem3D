shader_type canvas_item;

// Shared border-effect shader for status effects.
// Each effect type gets its own .tres material with different uniform presets.
//
//  poison  – purple, slow organic pulse, high noise
//  bleed    – red, medium pulse with drip feel
//  stun     – yellow, fast flicker, electric feel

uniform vec4 effect_color : source_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform float pulse_speed : hint_range(0.1, 10.0) = 2.0;
uniform float noise_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float noise_scale : hint_range(1.0, 100.0) = 25.0;
uniform float u_time : hint_range(0.0, 3600.0) = 0.0;

// Quick hash for per-pixel variation.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	// Distance from UV to nearest screen edge, in 0..0.5 range.
	float d = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));

	// Border band:  0 = edge, 1 = inner boundary, >1 = beyond border.
	float edge = d / 0.055;

	// Smooth falloff so the border fades inward.
	float falloff = 1.0 - smoothstep(0.0, 1.0, edge);

	// Base pulse: slow sine that varies along the perimeter.
	float pulse = sin(u_time * pulse_speed + d * 18.0) * 0.25 + 0.85;

	// Noise adds organic / electric variation.
	float n = hash(floor(UV * noise_scale + u_time * pulse_speed * 0.15)) * noise_intensity;

	float alpha = falloff * (pulse + n);
	alpha = clamp(alpha, 0.0, 1.0);

	// Fade out fully beyond the border band.
	if (edge > 1.0) {
		alpha = 0.0;
	}

	COLOR = vec4(effect_color.rgb, effect_color.a * alpha);
}
