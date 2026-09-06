shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled;

// X-ray outline used for the wallhack reveal.  Applied as a mesh's
// material_override, it inflates the silhouette along the surface normals and
// ignores the depth buffer so it draws over intervening walls.  The normal
// (base) material is restored when the reveal is turned off.
uniform vec4 outline_color : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform float outline_width = 0.05;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
