shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded, shadows_disabled;

// Hand-painted-looking explosion sprite.
//
//   * Billboards with the particle's own rotation (INSTANCE_CUSTOM.x).
//   * Alpha blended: every sprite is under 100 % opacity, so overlapping puffs
//     build the painterly layering the reference uses.
//   * Five flat tones sampled by a radial + noise field, so the bright core sits
//     in front and the tan/red rim behind it.  No smooth gradient.
//   * Torn shell: a noise threshold rises over the particle's lifetime
//     (INSTANCE_CUSTOM.y), so jagged holes open and reveal what is behind.
//   * Soft depth fade + near-camera fade, so nothing clips into walls or fills
//     the player's face.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

uniform vec4 col0 : source_color = vec4(0.35, 0.16, 0.09, 1.0);
uniform vec4 col1 : source_color = vec4(0.62, 0.14, 0.02, 1.0);
uniform vec4 col2 : source_color = vec4(1.20, 0.30, 0.02, 1.0);
uniform vec4 col3 : source_color = vec4(2.10, 0.72, 0.05, 1.0);
uniform vec4 col4 : source_color = vec4(3.10, 1.75, 0.30, 1.0);
uniform vec4 late_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float late_mix : hint_range(0.0, 1.0) = 0.0;

uniform float opacity : hint_range(0.0, 1.0) = 0.7;
uniform float fade_start : hint_range(0.0, 1.0) = 0.55;
uniform float dissolve_amount : hint_range(0.0, 1.0) = 0.55;
uniform float noise_scale = 1.5;
uniform float soft_distance : hint_range(0.01, 2.0) = 0.35;
uniform float near_fade_distance : hint_range(0.0, 6.0) = 0.0;

varying float v_life;
varying float v_seed;

void vertex() {
	v_life = INSTANCE_CUSTOM.y;
	v_seed = INSTANCE_CUSTOM.x;

	float a = INSTANCE_CUSTOM.x;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 face = INV_VIEW_MATRIX[2].xyz;
	vec3 r = right * cos(a) + up * sin(a);
	vec3 u = -right * sin(a) + up * cos(a);
	vec3 s = vec3(
		length(MODEL_MATRIX[0].xyz),
		length(MODEL_MATRIX[1].xyz),
		length(MODEL_MATRIX[2].xyz)
	);

	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(r * s.x, 0.0),
		vec4(u * s.y, 0.0),
		vec4(face * s.z, 0.0),
		MODEL_MATRIX[3]
	);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	vec2 noise_uv = UV * noise_scale + vec2(cos(v_seed), sin(v_seed)) * 0.5;
	float n = texture(noise_tex, noise_uv).r;

	// Torn shell: threshold climbs to dissolve_amount over the lifetime.
	float dissolve = smoothstep(0.0, 1.0, v_life) * dissolve_amount;
	if (n < dissolve) {
		discard;
	}

	// Five painted tones. Radial centre is hottest; noise breaks the bands.
	float radial = clamp(1.0 - length(UV - vec2(0.5)) * 2.0, 0.0, 1.0);
	float t = clamp(radial * 0.7 + (n - 0.5) * 0.55, 0.0, 1.0);
	vec3 c = mix(col0.rgb, col1.rgb, smoothstep(0.0, 0.25, t));
	c = mix(c, col2.rgb, smoothstep(0.25, 0.5, t));
	c = mix(c, col3.rgb, smoothstep(0.5, 0.75, t));
	c = mix(c, col4.rgb, smoothstep(0.75, 1.0, t));
	c = mix(c, late_color.rgb, v_life * late_mix);

	// Soft particle depth fade + near-camera fade, applied as alpha.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float scene_distance = -view.z;
	float particle_distance = -VERTEX.z;
	float soft = smoothstep(0.0, soft_distance, scene_distance - particle_distance);
	float near_fade = near_fade_distance > 0.0
			? smoothstep(0.0, near_fade_distance, particle_distance)
			: 1.0;

	// Each sprite stays under 100 % opacity; overlapping sprites build the
	// layered hand-painted look. Alpha also fades with particle age.
	float life_fade = 1.0 - smoothstep(fade_start, 1.0, v_life);
	ALBEDO = c;
	ALPHA = tex.a * opacity * life_fade * soft * near_fade;
}
