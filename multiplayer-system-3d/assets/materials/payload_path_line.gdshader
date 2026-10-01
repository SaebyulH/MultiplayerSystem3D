shader_type spatial;

// The payload route's glowing line.  Drawn as one static tube mesh by
// `world/payload/payload_path_line.gd`; the only thing that changes at runtime is the
// `progress` uniform, which erases everything the cart has already rolled over.
//
// `unshaded` because this is a light source, not a lit surface — an unlit emissive red is
// what the map's `glow_enabled` bloom picks up.  `cull_disabled` so the tube reads the same
// from inside a bend, where the camera can end up.
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform vec4 line_color : source_color = vec4(1.0, 0.1, 0.1, 1.0);

// Above 1.0 on purpose: the HDR buffer is what the environment's glow pass thresholds,
// and a plain 1.0 red does not bloom.
uniform float emission_strength : hint_range(0.0, 32.0) = 5.0;

// Fraction of the curve already behind the cart.  Everything below it is cut away, so the
// line visibly shortens as the payload advances.
uniform float progress : hint_range(0.0, 1.0) = 0.0;

// How much of the curve ahead of `progress` gets the brighter leading edge, as a fraction
// of total length.  Small — this is a highlight on the cut face, not a gradient.
uniform float head_glow : hint_range(0.0, 0.2) = 0.015;

void fragment() {
	// `UV.x` is the normalised distance along the curve, written per-vertex by the mesh
	// builder — see `PayloadPathLine.rebuild()`.  The comparison is on our own attribute,
	// so it costs no per-frame CPU work however long the route is.
	if (UV.x < progress) {
		discard;
	}

	float head = 1.0 - smoothstep(0.0, head_glow, UV.x - progress);
	ALBEDO = line_color.rgb * emission_strength * (1.0 + head * 2.5);
}
