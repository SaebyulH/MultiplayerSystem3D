shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, shadows_disabled, fog_disabled;

varying vec4 tint;
uniform float saturation = 1.0;
uniform vec3 color_tint = vec3(1.0);

void vertex() {
	tint = COLOR;
}

void fragment() {
	float r = abs(UV.y * 2.0 - 1.0);
	float edge = 0.83 + 0.09 * sin(UV.x * 18.0) + 0.04 * sin(UV.x * 37.0);
	float along = UV2.x;
	float cap = smoothstep(0.0, 0.23, along) * (1.0 - smoothstep(0.72, 1.0, along));
	float width = edge * (0.40 + 0.60 * sqrt(cap));
	float cover = (1.0 - smoothstep(width * 0.33, width, r)) * cap;
	vec3 color = tint.rgb * color_tint * mix(1.08, 0.72, r);
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = max(mix(vec3(luma), color, saturation), vec3(0.0));
	ALPHA = cover * tint.a * 0.78;
}
