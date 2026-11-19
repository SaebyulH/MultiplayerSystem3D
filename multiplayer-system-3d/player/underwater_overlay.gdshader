// Full-screen tint while the viewed player's head is below a water surface.
//
// Deliberately does NOT read `SCREEN_TEXTURE`: a screen-space refraction pass
// costs a copy of the framebuffer for an effect the player sees for a few
// seconds, and it makes the overlay order against the ADS scope harder to
// reason about.  Two screen-space sine bands and an elliptical vignette read as
// water and stay cheap.
shader_type canvas_item;
render_mode blend_mix;

uniform vec4 water_tint : source_color = vec4(0.10, 0.35, 0.45, 0.42);
uniform float band_strength : hint_range(0.0, 1.0) = 0.10;
uniform float vignette_strength : hint_range(0.0, 2.0) = 0.55;
uniform float band_speed = 0.35;

void fragment() {
	vec2 uv = UV;
	float bands = sin((uv.x * 9.0 + TIME * band_speed) * 3.14159)
		* sin((uv.y * 7.0 - TIME * band_speed * 0.7) * 3.14159);
	vec2 centred = uv - vec2(0.5);
	// Elliptical so a 16:9 screen darkens evenly at the edges.
	float vignette = smoothstep(0.35, 0.85, length(centred * vec2(1.0, 0.8)) * 1.4);
	vec3 colour = water_tint.rgb * (1.0 + bands * band_strength);
	float alpha = water_tint.a * (1.0 + vignette * vignette_strength);
	COLOR = vec4(colour, clamp(alpha, 0.0, 0.92));
}
