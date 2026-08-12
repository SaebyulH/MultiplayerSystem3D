shader_type spatial;
render_mode cull_back;

uniform vec4 grid_color : source_color = vec4(0.38, 0.38, 0.38, 1.0);
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float grid_scale = 1.0;
uniform float line_width : hint_range(0.0, 0.5) = 0.05;
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float depth_offset : hint_range(0.0, 0.05) = 0.002;

varying vec3 world_pos;

void vertex() {
	// Nudge along the normal to avoid z-fighting with coincident geometry.
	VERTEX += NORMAL * depth_offset;
	// Compute world position here, where VERTEX is still in local/model space.
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// World-space UVs so the grid aligns across objects, independent of camera or transform.
	vec2 uv = world_pos.xz * grid_scale;
	vec2 grid = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);
	float line = min(grid.x, grid.y);

	// Fade lines by distance from the camera so they don't alias into noise at range.
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float dist_fade = 1.0 - smoothstep(50.0, 200.0, dist);

	// Line mask: 1 = line, 0 = cell interior.
	float line_mask = 1.0 - smoothstep(line_width, line_width + 0.5, line);
	line_mask *= dist_fade;

	ALBEDO = mix(grid_color.rgb, line_color.rgb, line_mask);
	ROUGHNESS = roughness;
	METALLIC = metallic;
}