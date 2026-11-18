shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// Transparent reference grid for the character-select preview floor.
// Keeps the agent visually grounded and the orbit readable without adding
// visual weight.  Anti-aliased with fwidth, faded out towards the edge.

uniform vec4 line_color : source_color = vec4(0.62, 0.70, 0.80, 0.28);
uniform float plane_size = 24.0;
uniform float cell = 0.5;
uniform float fade_radius = 7.0;

void fragment() {
	vec2 metres = (UV - vec2(0.5)) * plane_size;
	float dist = length(metres);

	vec2 coord = UV * plane_size / cell;
	vec2 grid = abs(fract(coord - vec2(0.5)) - vec2(0.5)) / fwidth(coord);
	float minor = 1.0 - clamp(min(grid.x, grid.y), 0.0, 1.0);

	vec2 major_coord = UV * plane_size / (cell * 4.0);
	vec2 major_grid = abs(fract(major_coord - vec2(0.5)) - vec2(0.5)) / fwidth(major_coord);
	float major = 1.0 - clamp(min(major_grid.x, major_grid.y), 0.0, 1.0);

	float fade = 1.0 - smoothstep(fade_radius * 0.5, fade_radius, dist);
	ALBEDO = line_color.rgb;
	ALPHA = line_color.a * max(minor * 0.55, major) * fade;
}
