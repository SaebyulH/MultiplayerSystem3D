// Swimmable-water surface.  Used by `trenchbroom/textures/Material-LIB/Nature/
// Water/Water[swim].tres`, so every TrenchBroom face painted with that texture
// gets it at map build time.
//
// Two scrolling samples of the same normal map at different speeds and scales
// give the ripples motion without a second texture.  The material is
// transparent and cull-disabled on purpose: a water brush is a closed volume,
// and the player must still see the top surface while swimming underneath it.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_burley,
		specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;

uniform vec4 water_tint : source_color = vec4(0.55, 0.85, 0.95, 1.0);
uniform float alpha : hint_range(0.0, 1.0) = 0.72;
uniform float uv_scale = 0.5;
uniform vec2 scroll_a = vec2(0.012, 0.007);
uniform vec2 scroll_b = vec2(-0.009, 0.014);
uniform float normal_strength : hint_range(0.0, 1.0) = 0.65;
uniform float caustic_strength : hint_range(0.0, 0.5) = 0.12;

void fragment() {
	vec2 uv = UV * uv_scale;
	vec3 base = texture(albedo_texture, uv).rgb;
	vec3 n_a = texture(normal_texture, uv + TIME * scroll_a).rgb * 2.0 - 1.0;
	vec3 n_b = texture(normal_texture, uv * 1.63 + TIME * scroll_b).rgb * 2.0 - 1.0;

	ALBEDO = base * water_tint.rgb;
	ALPHA = alpha;
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.5;

	NORMAL_MAP = normalize(mix(n_a, n_b, 0.5));
	NORMAL_MAP_DEPTH = normal_strength;

	// Cheap moving caustic sheen on the peaks of the two normal samples.
	float shimmer = clamp((n_a.x - n_b.y) * 0.5 + 0.5, 0.0, 1.0);
	EMISSION = water_tint.rgb * shimmer * caustic_strength;
}
