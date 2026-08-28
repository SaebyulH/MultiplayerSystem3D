shader_type spatial;

// Screen-space Panini projection.
//
// Applied to a full-screen ColorRect layered over the 3D world (and under the
// HUD). It re-projects the already-rendered frame so the stretching at the
// edges of a wide field of view is reduced — the "Panini" projection used by// Hugin and several games for wide-FOV shots.
//
// Tuning:
//   panini_d  0 = off (rectilinear), 1 = full (stereographic). 0.5 is a good
//             middle ground for a ~90° vertical FOV.
//   fill      1 auto-zooms just enough that Panini's wider horizontal coverage
//             stays inside the source frame (no empty corners). Lower it to
//             trade empty corners for a wider view.
//   fov_deg / aspect are kept in sync with the camera and viewport by code.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

uniform float fov_deg : hint_range(1.0, 179.0) = 90.0;
uniform float aspect : hint_range(0.1, 4.0) = 1.777778;
uniform float panini_d : hint_range(0.0, 1.0) = 0.5;
uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform bool enabled = true;

vec3 ray_rectilinear(vec2 p) {
	return normalize(vec3(p, 1.0));
}

// Panini forward: (lat, lon) view direction -> projected screen point.
// d = 0 gives rectilinear (tan), d = 1 gives stereographic (2 * tan(theta / 2)).
vec2 panini_forward(vec2 latlon, float d) {
	float denom = d + cos(latlon.y);
	float k = (d + 1.0) / denom;
	return vec2(k * sin(latlon.y), k * tan(latlon.x));
}

// Panini inverse: projected screen point -> view ray.
vec3 panini_inverse(vec2 p, float d) {
	float dp1 = d + 1.0;
	float k = (p.x * p.x) / (dp1 * dp1);
	float disc = k * k * d * d - (k + 1.0) * (k * d * d - 1.0);
	if (disc <= 0.0) {
		return ray_rectilinear(p);
	}
	float c_lon = (-k * d + sqrt(disc)) / (k + 1.0);
	float s = dp1 / (d + c_lon);
	vec2 ang = vec2(atan(p.y, s), atan(p.x, s * c_lon)); // (lat, lon)
	float cos_lat = cos(ang.x);
	return vec3(cos_lat * sin(ang.y), sin(ang.x), cos_lat * cos(ang.y));
}

void fragment() {
	if (!enabled) {
		COLOR = textureLod(screen_tex, SCREEN_UV, 0.0);
		return;
	}

	float half_tan = tan(0.5 * radians(clamp(fov_deg, 1.0, 179.0)));
	vec2 max_rect = vec2(half_tan) * vec2(aspect, 1.0);

	// Auto-fill: zoom in until Panini's horizontal coverage fits the source frame.
	float zoom = 1.0;
	if (fill > 0.0 && panini_d > 0.0) {
		float lon_max = atan(max_rect.x);
		float x_edge = abs(panini_forward(vec2(0.0, lon_max), panini_d).x);
		if (x_edge > 0.0) {
			zoom = mix(1.0, max_rect.x / x_edge, fill);
		}
	}

	// Output pixel -> NDC, y flipped to camera convention (+y up).
	vec2 ndc = (SCREEN_UV * 2.0 - 1.0) / zoom;
	ndc.y = -ndc.y;

	vec3 ray = panini_inverse(ndc * max_rect, panini_d);
	if (ray.z <= 0.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}

	// Back to the source rectilinear UV (screen convention, +y down).
	vec2 src_ndc = ray.xy / ray.z / max_rect;
	vec2 src_uv = src_ndc * 0.5 + 0.5;
	src_uv.y = 1.0 - src_uv.y;

	if (src_uv.x < 0.0 || src_uv.x > 1.0 || src_uv.y < 0.0 || src_uv.y > 1.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		COLOR = textureLod(screen_tex, src_uv, 0.0);
	}
}
