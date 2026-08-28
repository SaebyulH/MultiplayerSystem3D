shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Slot A: used on flat surfaces (floors/ceilings)
uniform sampler2D texture_a : source_color, filter_linear_mipmap, repeat_enable;
// Slot B: used on wall surfaces
uniform sampler2D texture_b : source_color, filter_linear_mipmap, repeat_enable;

// Size of one tile in world-space meters
uniform float grid_size : hint_range(0.05, 10.0) = 1.0;

// How close to vertical the normal needs to be to count as "flat"
uniform float flat_threshold : hint_range(0.0, 1.0) = 0.7;

uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(world_normal);
	bool is_flat = abs(n.y) > flat_threshold;

	vec4 tex_color;

	if (is_flat) {
		// Floor / ceiling: tile across world XZ
		vec2 uv = world_pos.xz / grid_size;
		tex_color = texture(texture_a, uv);
	} else {
		// Wall: pick the horizontal axis that isn't facing the wall,
		// so the tile doesn't stretch along the wall's thin axis
		vec2 uv;
		if (abs(n.x) > abs(n.z)) {
			uv = vec2(world_pos.z, world_pos.y) / grid_size;
		} else {
			uv = vec2(world_pos.x, world_pos.y) / grid_size;
		}
		tex_color = texture(texture_b, uv);
	}

	ALBEDO = tex_color.rgb;
	ROUGHNESS = roughness_value;
}
