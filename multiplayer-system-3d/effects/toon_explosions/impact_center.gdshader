shader_type spatial;
render_mode blend_premul_alpha, unshaded, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D frame_palette : filter_linear, repeat_disable;
// Same intent as the sprite path: the palette's highlight band and the Filmic
// tonemap pull bright cards toward neutral, so >1 restores the authored hue.
uniform float saturation = 1.0;
// Per-weapon tint (heal green, poison purple).  Separate from the varying
// `tint`, which is the per-instance particle colour.
uniform vec3 color_tint = vec3(1.0);

varying vec4 card;
varying vec4 tint;

void vertex() {
	card = INSTANCE_CUSTOM;
	tint = COLOR;
}

float soft_union(float a, float b, float k) {
	float h = max(k - abs(a - b), 0.0) / k;
	return min(a, b) - h * h * k * 0.25;
}

// Original sprite masks. Source atlas measurements drive their color,
// covered area and footprint over time. The silhouettes are generated here.
float smoke_mask(vec2 p, float seed) {
	float shape = length(p * vec2(1.0, 1.10)) - 0.49;
	for (int i = 0; i < 6; i++) {
		float j = float(i);
		float theta = j * 1.0472 + seed * 6.2832;
		float jitter = sin(j * 15.9 + seed * 21.3) * 0.5 + 0.5;
		vec2 lob = vec2(cos(theta), sin(theta)) * mix(0.32, 0.55, jitter);
		float radius = mix(0.25, 0.42, 0.5 + 0.5 * cos(j * 5.2 + seed * 30.0));
		shape = soft_union(shape, length(p - lob) - radius, 0.18);
	}
	return shape;
}

void fragment() {
	float encoded = card.r * 12.0;
	float mode = floor(encoded);
	float overbright = clamp((fract(encoded) - 0.125) / 0.75, 0.0, 1.0);
	float style = floor(mode / 3.0);
	float blend = mod(mode, 3.0);
	float age = card.g;
	float seed = card.b;
	vec2 p = UV * 2.0 - 1.0;
	float jitter = sin(p.x * 13.0 + seed * 12.0) * sin(p.y * 11.0 - seed * 10.0);
	float edge = smoke_mask(p, seed);
	float soft = 0.026 + clamp(fwidth(edge), 0.0, 0.055);
	float silhouette = 1.0 - smoothstep(-soft, soft, edge);
	vec3 shadow = texture(frame_palette, vec2(card.a, 1.0 / 6.0)).rgb;
	vec3 middle = texture(frame_palette, vec2(card.a, 0.5)).rgb;
	vec3 highlight = texture(frame_palette, vec2(card.a, 5.0 / 6.0)).rgb;
	vec3 color;
	float alpha = silhouette;
	float glow = 0.0;
	if (style < 2.0) {
		float fold = smoothstep(-0.18, -0.03, smoke_mask(p + vec2(0.09, -0.13), seed));
		color = mix(middle, shadow, 0.68 * fold);
		color = mix(color, highlight, 0.27 * smoothstep(-0.65, 0.55, p.x - p.y));
		color *= 1.0 - 0.16 * fold;
		alpha *= 1.0 - 0.11 * fold;
	} else {
		float pockets = 0.0;
		for (int i = 0; i < 5; i++) {
			float j = float(i);
			float theta = j * 2.39996 + seed * 4.0;
			float s = 0.24 + 0.30 * fract(j * 0.382 + seed);
			vec2 center = vec2(cos(theta), sin(theta)) * s;
			float falloff = length(p - center) + jitter * 0.035;
			pockets = max(pockets, 1.0 - smoothstep(0.09, 0.25, falloff));
		}
		vec2 q = p * 3.5;
		q += vec2(sin(q.y * 2.1 + seed * 6.0), cos(q.x * 2.3 - age * 2.0)) * 0.55;
		float flow = sin(q.x * 1.35 + q.y * 0.82 + sin(q.y * 1.9) * 0.72 - age * 3.0);
		float body = smoothstep(0.06, 0.67, flow - pockets * 0.55);
		float hot = smoothstep(0.38, 0.88, flow) * (1.0 - pockets);
		glow = smoothstep(0.18, 0.82, hot);
		color = mix(shadow, middle, body);
		color = mix(color, highlight, hot);
		// Flame interiors thin as they age, exposing the independently
		// blended smoke behind them. The hot ridges hang on a little longer.
		float holes = smoothstep(0.42, 0.84, pockets + 0.23 * (1.0 - flow));
		float opening = mix(0.28, 0.79, age) * (style > 2.5 ? 1.0 : 0.82);
		alpha *= 1.0 - holes * opening;
		alpha *= mix(0.59, 1.0, max(body, hot));
	}
	// Bound peak RGB without adding an achromatic highlight. Apply coverage
	// as premultiplied color so overlapping cards preserve local contrast.
	color *= tint.rgb;
	color *= color_tint;
	// Convert the VMT overbright factor to display-space gain for hot bands.
	// Saturation follows the actual channels, so orange tints can reach
	// yellow as the red channel clips without introducing neutral white.
	color = min(color * (1.0 + glow * (0.66 + overbright * 1.65)), vec3(1.0));
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	color = max(mix(vec3(luma), color, saturation), vec3(0.0));
	float margin = 1.0 - smoothstep(0.96, 1.0, max(abs(p.x), abs(p.y)));
	float coverage = clamp(alpha * tint.a * margin, 0.0, 1.0);
	float occlusion = (blend == 1.0) ? 0.0 : ((blend == 2.0) ? 0.73 : 1.0);
	ALBEDO = color * coverage * (1.0 + 0.25 * glow * step(0.5, blend));
	ALPHA = coverage * occlusion;
}
