shader_type spatial;

// Painted Toon — World  (painterly rework)
// ============================================================================
// Stylised surface shader for *map* geometry.  Direct light is replaced by a
// banded ramp with a brushed terminator; there is no back rim (a wall has no
// silhouette to separate), and highlights come only from real lights.
//
// What changed vs. the previous version:
//
//   * BRUSH FIELD.  The 3-sine pattern is replaced by a stretched, domain-
//     warped value-noise field (`brush_hardness` slides it from soft blended
//     strokes to hard faceted planes, like gouache blocking).  It is computed
//     ONCE in fragment() and handed to light() through a varying (Godot allows
//     fragment() -> light() varyings), so it costs the same with 1 light or 8.
//
//   * NORMAL WARP.  Each brush cell tilts the shading normal along the surface,
//     so bands break into stroke-shaped planes instead of following the mesh's
//     smooth curvature.  Normal-map sampling is done by hand (not NORMAL_MAP)
//     so the warp composes with it instead of being overwritten.
//
//   * UV WARP.  Albedo/normal/ORM lookups are smeared by the same field, which
//     breaks up texture tiling and reads as dragged paint.
//
//   * COLOUR VARIATION per stroke (value + a small warm/cool shift).
//
//   * SPECULAR rebuilt.  Previously: a threshold blob, white, full strength,
//     per light, over big smooth areas.  Now: low default strength, hard
//     energy cap, tinted toward the albedo, and broken up by the brush field so
//     it reads as a few dry-brush dabs, not glossy blobs.
//
//   * SATURATION MAX.  Any colour whose HSV saturation is above
//     `saturation_max` is pulled down to it; colours below are untouched.
//     Value (brightness) is preserved.  Applied to albedo, each light's diffuse
//     and specular contribution, and emission.  See the note at the bottom for
//     the one thing it cannot reach (ambient tint).

// ---------------------------------------------------------------------------
// Albedo
// ---------------------------------------------------------------------------
group_uniforms Albedo;
uniform bool use_albedo_texture = false;
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_vertex_color = false;
uniform vec2 uv_scale = vec2(1.0, 1.0);
// Lifts albedo to compensate for losing PBR ambient sheen; see
// 05-known-issues.md #53.  Much past 2 starts clipping bright textures.
uniform float albedo_gain : hint_range(0.0, 4.0) = 2.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Saturation limit
// ---------------------------------------------------------------------------
group_uniforms SaturationLimit;
// HSV saturation ceiling.  1.0 = off.  Pixels at or below are untouched.
uniform float saturation_max : hint_range(0.0, 1.0) = 0.7;
// How hard the excess is removed.  1.0 = hard clamp to the max, 0.0 = no
// effect.  ~0.7-0.9 keeps a little of the original punch above the ceiling.
uniform float saturation_compress : hint_range(0.0, 1.0) = 0.85;
group_uniforms;

// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------
group_uniforms Surface;
uniform bool use_normal_map = false;
uniform sampler2D normal_texture : hint_normal;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// Packed ORM, glTF convention: G = roughness, B = metallic.
uniform bool use_orm_texture = false;
uniform sampler2D orm_texture : hint_default_white;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
// Ambient/IBL sheen only (does not affect the painted highlight).
uniform float specular : hint_range(0.0, 1.0) = 0.0;

uniform bool use_ao_texture = false;
uniform sampler2D ao_texture : hint_default_white;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Toon ramp
// ---------------------------------------------------------------------------
group_uniforms Toon;
uniform int toon_steps : hint_range(1, 8) = 3;
uniform float toon_softness : hint_range(0.0, 1.0) = 0.45;
uniform float shadow_wrap : hint_range(0.0, 1.0) = 0.35;
uniform vec4 shadow_tint : source_color = vec4(0.66, 0.74, 0.98, 1.0);
uniform vec4 light_tint : source_color = vec4(1.0, 0.97, 0.89, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.3;
group_uniforms;

// ---------------------------------------------------------------------------
// Brush field
// ---------------------------------------------------------------------------
group_uniforms Brush;
// Stroke cells per object-space unit.
uniform float paint_scale : hint_range(0.5, 64.0) = 6.0;
// Object-space direction strokes run along.  Normalised in the shader.
uniform vec3 brush_direction = vec3(0.25, 1.0, 0.15);
// >1 elongates cells along `brush_direction` (long strokes), <1 shortens them.
uniform float brush_stretch : hint_range(0.25, 8.0) = 2.5;
// 0 = soft blended strokes, 1 = hard-edged faceted planes.
uniform float brush_hardness : hint_range(0.0, 1.0) = 0.55;
// How far the stroke domain is wobbled (makes edges irregular, not gridlike).
uniform float brush_warp : hint_range(0.0, 2.0) = 0.6;
group_uniforms;

group_uniforms PaintedVariation;
// Tilts the shading normal per stroke.  The main "painted planes" lever.
uniform float paint_normal_warp : hint_range(0.0, 1.5) = 0.35;
// Smears texture lookups along the field (UV units).  0 disables.
uniform float paint_uv_warp : hint_range(0.0, 0.1) = 0.012;
// Wobbles the band edge per stroke.  0 disables.
uniform float paint_terminator_jitter : hint_range(0.0, 0.5) = 0.12;
// Per-stroke brightness variation.  0 disables.
uniform float paint_value_jitter : hint_range(0.0, 0.5) = 0.08;
// Per-stroke warm/cool colour variation.  0 disables.
uniform float paint_color_jitter : hint_range(0.0, 0.3) = 0.06;
group_uniforms;

// ---------------------------------------------------------------------------
// Painted highlight — dry-brush dabs, not gloss.
// ---------------------------------------------------------------------------
group_uniforms SpecularHighlight;
uniform float toon_specular_strength : hint_range(0.0, 1.0) = 0.12;
// Hard ceiling on the highlight contribution per light (stops blow-outs).
uniform float toon_specular_max : hint_range(0.0, 1.0) = 0.25;
uniform float toon_specular_size : hint_range(0.0, 1.0) = 0.25;
uniform float toon_specular_softness : hint_range(0.0, 1.0) = 0.5;
// 0 = highlight is a smooth blob, 1 = heavily broken up by the brush field.
uniform float toon_specular_breakup : hint_range(0.0, 1.0) = 0.7;
// 0 = light-coloured highlight, 1 = tinted by the surface colour.
uniform float toon_specular_albedo_tint : hint_range(0.0, 1.0) = 0.6;
group_uniforms;

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------
group_uniforms Emission;
uniform bool use_emission_texture = false;
uniform sampler2D emission_texture : source_color, hint_default_black;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------
varying vec3 v_obj_pos;    // object-space position (stable, no swimming)
varying vec3 v_obj_nrm;    // object-space normal
varying float v_tone;      // per-stroke 0..1, written in fragment(), read in light()

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Hash without sin (stable at large coordinates).
vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

// 3D value noise returning 3 decorrelated channels in [0,1].
// `hardness` sharpens the interpolation toward flat cells with crisp edges.
vec3 vnoise3(vec3 p, float hardness) {
	vec3 i = floor(p);
	vec3 fr = fract(p);
	float w = mix(0.5, 0.03, hardness);
	fr = smoothstep(vec3(0.5 - w), vec3(0.5 + w), fr);

	vec3 c000 = hash33(i);
	vec3 c100 = hash33(i + vec3(1.0, 0.0, 0.0));
	vec3 c010 = hash33(i + vec3(0.0, 1.0, 0.0));
	vec3 c110 = hash33(i + vec3(1.0, 1.0, 0.0));
	vec3 c001 = hash33(i + vec3(0.0, 0.0, 1.0));
	vec3 c101 = hash33(i + vec3(1.0, 0.0, 1.0));
	vec3 c011 = hash33(i + vec3(0.0, 1.0, 1.0));
	vec3 c111 = hash33(i + vec3(1.0, 1.0, 1.0));

	return mix(
			mix(mix(c000, c100, fr.x), mix(c010, c110, fr.x), fr.y),
			mix(mix(c001, c101, fr.x), mix(c011, c111, fr.x), fr.y),
			fr.z);
}

// Reduces HSV saturation to `max_s` where it exceeds it, preserving value.
// compress: 1 = clamp to max_s, 0 = leave alone.
vec3 limit_saturation(vec3 c, float max_s, float compress) {
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float s = (mx - mn) / max(mx, 1e-5);
	if (s <= max_s) {
		return c;
	}
	float k = mix(s, max_s, compress) / s;
	return vec3(mx) - (vec3(mx) - c) * k;
}

float toon_ramp(float x, float steps, float softness) {
	float scaled = x * steps;
	float band = floor(scaled);
	float f = scaled - band;
	float edge = max(softness, 1e-4);
	float e = clamp((f - 0.5) / edge + 0.5, 0.0, 1.0);
	e = e * e * (3.0 - 2.0 * e);
	return (band + e) / steps;
}

void vertex() {
	v_obj_pos = VERTEX;
	v_obj_nrm = NORMAL;
}

void fragment() {
	// --- Brush field (computed once; light() reads v_tone) -----------------
	vec3 dir = normalize(brush_direction);
	vec3 p = v_obj_pos;
	float along = dot(p, dir);
	// Stretch cells along the stroke direction.
	p = (p - dir * along + dir * (along / brush_stretch)) * paint_scale;
	// Domain warp so cell edges wobble instead of forming a grid.
	p += (vnoise3(p * 0.45 + 17.1, 0.0) - 0.5) * 2.0 * brush_warp;
	vec3 s = vnoise3(p, brush_hardness);
	v_tone = s.x;

	// --- UV warp ------------------------------------------------------------
	vec2 uv = UV * uv_scale + (s.yz - 0.5) * 2.0 * paint_uv_warp;

	// --- Albedo -------------------------------------------------------------
	vec3 base = albedo_color.rgb;
	if (use_albedo_texture) {
		base *= texture(albedo_texture, uv).rgb;
	}
	if (use_vertex_color) {
		base *= COLOR.rgb;
	}
	base *= albedo_gain;

	// Per-stroke value + warm/cool variation.
	base *= 1.0 + (s.x - 0.5) * 2.0 * paint_value_jitter;
	base *= 1.0 + vec3(s.y - 0.5, 0.0, 0.5 - s.y) * 2.0 * paint_color_jitter;

	ALBEDO = limit_saturation(max(base, vec3(0.0)), saturation_max, saturation_compress);

	// --- Normal: map (by hand) + painterly warp ----------------------------
	vec3 n = NORMAL;
	if (use_normal_map) {
		vec3 t = texture(normal_texture, uv).xyz * 2.0 - 1.0;
		t.xy *= normal_strength;
		vec3 mapped = normalize(TANGENT * t.x + BINORMAL * t.y + NORMAL * max(t.z, 1e-3));
		n = normalize(mix(NORMAL, mapped, clamp(normal_strength, 0.0, 1.0)));
	}
	// Stroke tilt: a per-cell vector, flattened onto the surface plane so it
	// bends the normal sideways rather than pushing it in/out.
	vec3 d = vec3(s.y, s.z, s.x) * 2.0 - 1.0;
	d -= v_obj_nrm * dot(d, v_obj_nrm);
	vec3 d_view = (VIEW_MATRIX * (MODEL_MATRIX * vec4(d, 0.0))).xyz;
	NORMAL = normalize(n + d_view * paint_normal_warp);

	// --- Roughness / metallic / AO -----------------------------------------
	float rough = roughness;
	float metal = metallic;
	if (use_orm_texture) {
		vec3 orm = texture(orm_texture, uv).rgb;
		rough *= orm.g;
		metal *= orm.b;
	}
	ROUGHNESS = clamp(rough, 0.0, 1.0);
	METALLIC = clamp(metal, 0.0, 1.0);
	SPECULAR = specular;

	if (use_ao_texture) {
		AO = mix(1.0, texture(ao_texture, uv).r, ao_strength);
	}

	// --- Emission -----------------------------------------------------------
	vec3 emit = emission_color.rgb * emission_energy;
	if (use_emission_texture) {
		emit *= texture(emission_texture, uv).rgb;
	}
	EMISSION += limit_saturation(emit, saturation_max, saturation_compress);
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);

	// Lambert wrap (0 = clamped N.L, 1 = half-lambert).
	float wrapped = clamp((ndotl + shadow_wrap) / (1.0 + shadow_wrap), 0.0, 1.0);

	// Terminator wobbles per stroke, so band edges follow brush planes.
	float ramp_in = clamp(wrapped + (v_tone - 0.5) * paint_terminator_jitter, 0.0, 1.0);
	float bands = toon_ramp(ramp_in, float(toon_steps), toon_softness);

	vec3 tint = mix(shadow_tint.rgb, light_tint.rgb, bands);
	tint = mix(vec3(1.0), tint, tint_strength);

	// --- Diffuse (same accumulation shape as the engine) -------------------
	vec3 diff = ALBEDO * LIGHT_COLOR * bands * tint
			* (1.0 - METALLIC) * (1.0 / PI) * ATTENUATION;
	DIFFUSE_LIGHT += limit_saturation(diff, saturation_max, saturation_compress);

	// --- Painted highlight --------------------------------------------------
	float gloss = clamp(1.0 - ROUGHNESS, 0.0, 1.0);
	float power = exp2(mix(2.0, 11.0, gloss));
	vec3 h = normalize(LIGHT + VIEW);
	float lobe = pow(clamp(dot(NORMAL, h), 0.0, 1.0), power);

	float threshold = mix(0.95, 0.02, toon_specular_size);
	float soft = mix(0.002, 0.4, toon_specular_softness);
	float spec = smoothstep(threshold, min(threshold + soft, 1.0), lobe);

	// Break the blob up with the brush field: only some strokes catch light.
	float dab = smoothstep(0.35, 0.65, v_tone);
	spec *= mix(1.0, dab, toon_specular_breakup);

	// Only where this light actually reaches the surface.
	spec *= smoothstep(0.0, 0.2, ndotl);

	// Tint toward the surface colour (normalised so it never darkens).
	vec3 albedo_hue = ALBEDO / max(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), 1e-4);
	vec3 f0 = mix(vec3(1.0), albedo_hue, max(toon_specular_albedo_tint, METALLIC));

	vec3 hl = f0 * LIGHT_COLOR * ATTENUATION * (spec * toon_specular_strength);
	// Energy cap: a highlight can never exceed this, however bright the light.
	float peak = max(hl.r, max(hl.g, hl.b));
	hl *= min(1.0, toon_specular_max / max(peak, 1e-5));
	SPECULAR_LIGHT += limit_saturation(hl, saturation_max, saturation_compress);
}

// NOTE on the saturation limit: ambient/sky light is added by the engine after
// fragment(), as ALBEDO * ambient_colour.  ALBEDO is already limited, so the
// result is limited too unless the ambient/sky itself is strongly coloured.  A
// true last-step clamp on the final pixel needs a screen-space post-process.
