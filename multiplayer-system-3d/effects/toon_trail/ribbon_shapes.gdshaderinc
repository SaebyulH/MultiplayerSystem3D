uniform float outline_amount = 0.62;
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	float edge = abs(UV.y * 2.0 - 1.0);
	float t = UV.x;
	float folds = sin(t * 19.0) * 0.048 + cos(t * 37.0 + 0.4) * 0.032;
	float along = UV2.x;
	float cap = smoothstep(0.0, 0.13, along) * (1.0 - smoothstep(0.88, 1.0, along));
	float rim = (0.85 + outline_amount * folds) * (0.45 + 0.55 * sqrt(cap));
	float feather = clamp(fwidth(edge), 0.022, 0.10);
	float outer = 1.0 - smoothstep(rim - feather, rim + feather, edge);
	float inner = 1.0 - smoothstep(rim - 0.22, rim - 0.10, edge);
	float lighting = mix(0.76, 1.12, smoothstep(-0.18, 0.83, UV.y));
	float line = mix(1.0, 0.68 + inner * (lighting - 0.68), outline_amount);
	ALBEDO = tint.rgb * line;
	ALPHA = tint.a * outer * cap;
}
