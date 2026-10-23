shader_type spatial;

// Painted Toon — World (PBR Specular Rework)
// ============================================================================
// Stylised surface shader for map geometry.
//
// Direct diffuse lighting uses a banded painterly ramp, while specular
// reflection uses a simplified PBR GGX/Fresnel model. The PBR response is
// subsequently broken up by the brush field so highlights still read as
// painted rather than perfectly smooth.
//
// Key properties:
//
//   * BRUSH FIELD
//     Domain-warped value noise creates irregular painterly cells.
//
//   * NORMAL WARP
//     Each brush cell tilts the shading normal, creating painted planes.
//
//   * UV WARP
//     Albedo/normal/ORM lookups are smeared using the same brush field.
//
//   * COLOUR VARIATION
//     Small per-stroke brightness and warm/cool variations.
//
//   * TOON DIFFUSE
//     Direct diffuse lighting is quantised into painterly bands.
//
//   * PBR SPECULAR
//     Specular uses dielectric F0 ≈ 0.04, metallic F0 from albedo,
//     Fresnel, GGX distribution and Smith geometry attenuation.
//
//     The brush field modifies the final visibility of the highlight rather
//     than replacing the underlying PBR response.
//
//   * SATURATION LIMIT
//     Saturation is compressed after albedo, diffuse, specular and emission.
//
// ============================================================================


// ---------------------------------------------------------------------------
// Albedo
// ---------------------------------------------------------------------------
group_uniforms Albedo;

uniform bool use_albedo_texture = false;
uniform sampler2D albedo_texture : source_color, hint_default_white;

uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform bool use_vertex_color = false;

uniform vec2 uv_scale = vec2(1.0, 1.0);

// Lifts albedo to compensate for losing PBR ambient sheen.
uniform float albedo_gain : hint_range(0.0, 4.0) = 2.0;

group_uniforms;


// ---------------------------------------------------------------------------
// Saturation limit
// ---------------------------------------------------------------------------
group_uniforms SaturationLimit;

// HSV saturation ceiling.
// 1.0 = effectively off.
uniform float saturation_max : hint_range(0.0, 1.0) = 0.7;

// 1.0 = hard clamp.
// 0.0 = no effect.
uniform float saturation_compress : hint_range(0.0, 1.0) = 0.85;

group_uniforms;


// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------
group_uniforms Surface;

uniform bool use_normal_map = false;
uniform sampler2D normal_texture : hint_normal;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// Packed ORM, glTF convention:
//   G = roughness
//   B = metallic
uniform bool use_orm_texture = false;
uniform sampler2D orm_texture : hint_default_white;

uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;

// Engine-side PBR specular strength.
// 0.5 is approximately the conventional default.
uniform float specular : hint_range(0.0, 1.0) = 0.5;

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

uniform vec4 shadow_tint : source_color =
	vec4(0.66, 0.74, 0.98, 1.0);

uniform vec4 light_tint : source_color =
	vec4(1.0, 0.97, 0.89, 1.0);

uniform float tint_strength : hint_range(0.0, 1.0) = 0.3;

group_uniforms;


// ---------------------------------------------------------------------------
// Brush field
// ---------------------------------------------------------------------------
group_uniforms Brush;

// Stroke cells per object-space unit.
uniform float paint_scale : hint_range(0.5, 64.0) = 6.0;

// Object-space direction strokes run along.
uniform vec3 brush_direction = vec3(0.25, 1.0, 0.15);

// >1 elongates cells along brush_direction.
uniform float brush_stretch : hint_range(0.25, 8.0) = 2.5;

// 0 = soft blended strokes.
// 1 = hard-edged faceted planes.
uniform float brush_hardness : hint_range(0.0, 1.0) = 0.55;

// Domain warp amount.
uniform float brush_warp : hint_range(0.0, 2.0) = 0.6;

group_uniforms;


// ---------------------------------------------------------------------------
// Painted variation
// ---------------------------------------------------------------------------
group_uniforms PaintedVariation;

// Tilts shading normal per stroke.
uniform float paint_normal_warp : hint_range(0.0, 1.5) = 0.35;

// Smears texture lookups.
uniform float paint_uv_warp : hint_range(0.0, 0.1) = 0.012;

// Wobbles band edge.
uniform float paint_terminator_jitter : hint_range(0.0, 0.5) = 0.12;

// Per-stroke brightness variation.
uniform float paint_value_jitter : hint_range(0.0, 0.5) = 0.08;

// Per-stroke warm/cool variation.
uniform float paint_color_jitter : hint_range(0.0, 0.3) = 0.06;

group_uniforms;


// ---------------------------------------------------------------------------
// PBR / Painted Specular
// ---------------------------------------------------------------------------
group_uniforms SpecularHighlight;

// Multiplier applied to the physically-based specular response.
//
// Unlike the old implementation, this is NOT the raw brightness of a white
// blob. A dielectric surface still starts with ~4% F0.
uniform float toon_specular_strength : hint_range(0.0, 2.0) = 1.0;

// Safety ceiling for the final painted specular contribution.
uniform float toon_specular_max : hint_range(0.0, 4.0) = 1.5;

// Controls how much of the PBR lobe is shaped by the painterly threshold.
uniform float toon_specular_size : hint_range(0.0, 1.0) = 0.25;

// Controls the softness of the painterly threshold.
uniform float toon_specular_softness : hint_range(0.0, 1.0) = 0.5;

// 0 = ordinary PBR highlight.
// 1 = heavily broken up by brush cells.
uniform float toon_specular_breakup : hint_range(0.0, 1.0) = 0.7;

group_uniforms;


// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------
group_uniforms Emission;

uniform bool use_emission_texture = false;
uniform sampler2D emission_texture : source_color, hint_default_black;

uniform vec4 emission_color : source_color =
	vec4(0.0, 0.0, 0.0, 1.0);

uniform float emission_energy = 1.0;

group_uniforms;


// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

varying vec3 v_obj_pos;
varying vec3 v_obj_nrm;
varying float v_tone;


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Hash without sin.
// Stable at large coordinates.
vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);

	return fract((p.xxy + p.yxx) * p.zyx);
}


// 3D value noise returning three decorrelated channels.
//
// hardness sharpens interpolation toward flat cells.
vec3 vnoise3(vec3 p, float hardness) {
	vec3 i = floor(p);
	vec3 fr = fract(p);

	float w = mix(0.5, 0.03, hardness);

	fr = smoothstep(
		vec3(0.5 - w),
		vec3(0.5 + w),
		fr
	);

	vec3 c000 = hash33(i);
	vec3 c100 = hash33(i + vec3(1.0, 0.0, 0.0));

	vec3 c010 = hash33(i + vec3(0.0, 1.0, 0.0));
	vec3 c110 = hash33(i + vec3(1.0, 1.0, 0.0));

	vec3 c001 = hash33(i + vec3(0.0, 0.0, 1.0));
	vec3 c101 = hash33(i + vec3(1.0, 0.0, 1.0));

	vec3 c011 = hash33(i + vec3(0.0, 1.0, 1.0));
	vec3 c111 = hash33(i + vec3(1.0, 1.0, 1.0));

	return mix(
		mix(
			mix(c000, c100, fr.x),
			mix(c010, c110, fr.x),
			fr.y
		),
		mix(
			mix(c001, c101, fr.x),
			mix(c011, c111, fr.x),
			fr.y
		),
		fr.z
	);
}


// Reduces HSV saturation to max_s where it exceeds it.
//
// compress:
//   1 = clamp to max_s
//   0 = leave unchanged
vec3 limit_saturation(
	vec3 c,
	float max_s,
	float compress
) {
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));

	float s = (mx - mn) / max(mx, 1e-5);

	if (s <= max_s) {
		return c;
	}

	float k = mix(s, max_s, compress) / s;

	return vec3(mx) - (vec3(mx) - c) * k;
}


// Toon ramp.
float toon_ramp(
	float x,
	float steps,
	float softness
) {
	float scaled = x * steps;

	float band = floor(scaled);
	float f = scaled - band;

	float edge = max(softness, 1e-4);

	float e = clamp(
		(f - 0.5) / edge + 0.5,
		0.0,
		1.0
	);

	e = e * e * (3.0 - 2.0 * e);

	return (band + e) / steps;
}


// ---------------------------------------------------------------------------
// Vertex
// ---------------------------------------------------------------------------
void vertex() {
	v_obj_pos = VERTEX;
	v_obj_nrm = NORMAL;
}


// ---------------------------------------------------------------------------
// Fragment
// ---------------------------------------------------------------------------
void fragment() {

	// -----------------------------------------------------------------------
	// Brush field
	// -----------------------------------------------------------------------

	vec3 dir = normalize(brush_direction);

	vec3 p = v_obj_pos;

	float along = dot(p, dir);

	// Stretch cells along the stroke direction.
	p = (
		p
		- dir * along
		+ dir * (along / brush_stretch)
	) * paint_scale;

	// Domain warp so cell edges wobble instead of forming a grid.
	p += (
		vnoise3(
			p * 0.45 + 17.1,
			0.0
		) - 0.5
	) * 2.0 * brush_warp;

	vec3 s = vnoise3(
		p,
		brush_hardness
	);

	v_tone = s.x;


	// -----------------------------------------------------------------------
	// UV warp
	// -----------------------------------------------------------------------

	vec2 uv =
		UV * uv_scale
		+ (s.yz - 0.5)
		* 2.0
		* paint_uv_warp;


	// -----------------------------------------------------------------------
	// Albedo
	// -----------------------------------------------------------------------

	vec3 base = albedo_color.rgb;

	if (use_albedo_texture) {
		base *= texture(
			albedo_texture,
			uv
		).rgb;
	}

	if (use_vertex_color) {
		base *= COLOR.rgb;
	}

	base *= albedo_gain;


	// Per-stroke value variation.
	base *= 1.0
		+ (s.x - 0.5)
		* 2.0
		* paint_value_jitter;


	// Per-stroke warm/cool variation.
	base *= 1.0
		+ vec3(
			s.y - 0.5,
			0.0,
			0.5 - s.y
		)
		* 2.0
		* paint_color_jitter;


	ALBEDO = limit_saturation(
		max(base, vec3(0.0)),
		saturation_max,
		saturation_compress
	);


	// -----------------------------------------------------------------------
	// Normal map + painterly normal warp
	// -----------------------------------------------------------------------

	vec3 n = NORMAL;

	if (use_normal_map) {

		vec3 t =
			texture(
				normal_texture,
				uv
			).xyz * 2.0 - 1.0;

		t.xy *= normal_strength;

		vec3 mapped = normalize(
			TANGENT * t.x
			+ BINORMAL * t.y
			+ NORMAL * max(t.z, 1e-3)
		);

		n = normalize(
			mix(
				NORMAL,
				mapped,
				clamp(
					normal_strength,
					0.0,
					1.0
				)
			)
		);
	}


	// Stroke tilt.
	//
	// Flatten the random vector onto the surface plane so that it bends the
	// normal sideways instead of simply pushing it inward/outward.

	vec3 d =
		vec3(
			s.y,
			s.z,
			s.x
		) * 2.0 - 1.0;

	d -= v_obj_nrm
		* dot(
			d,
			v_obj_nrm
		);

	vec3 d_view =
		(VIEW_MATRIX
		* (MODEL_MATRIX * vec4(d, 0.0))).xyz;

	NORMAL = normalize(
		n
		+ d_view * paint_normal_warp
	);


	// -----------------------------------------------------------------------
	// Roughness / metallic / AO
	// -----------------------------------------------------------------------

	float rough = roughness;
	float metal = metallic;

	if (use_orm_texture) {

		vec3 orm =
			texture(
				orm_texture,
				uv
			).rgb;

		rough *= orm.g;
		metal *= orm.b;
	}

	ROUGHNESS = clamp(
		rough,
		0.0,
		1.0
	);

	METALLIC = clamp(
		metal,
		0.0,
		1.0
	);

	SPECULAR = specular;


	// AO.
	if (use_ao_texture) {

		AO = mix(
			1.0,
			texture(
				ao_texture,
				uv
			).r,
			ao_strength
		);
	}


	// -----------------------------------------------------------------------
	// Emission
	// -----------------------------------------------------------------------

	vec3 emit =
		emission_color.rgb
		* emission_energy;

	if (use_emission_texture) {

		emit *= texture(
			emission_texture,
			uv
		).rgb;
	}

	EMISSION += limit_saturation(
		emit,
		saturation_max,
		saturation_compress
	);
}


// ---------------------------------------------------------------------------
// Light
// ---------------------------------------------------------------------------
void light() {

	float ndotl = dot(
		NORMAL,
		LIGHT
	);


	// -----------------------------------------------------------------------
	// Toon diffuse
	// -----------------------------------------------------------------------

	// Lambert wrap.
	//
	// 0 = ordinary clamped N.L
	// 1 = half-Lambert-like wrap.

	float wrapped = clamp(
		(ndotl + shadow_wrap)
		/ (1.0 + shadow_wrap),
		0.0,
		1.0
	);


	// Terminator wobbles per stroke.
	float ramp_in = clamp(
		wrapped
		+ (v_tone - 0.5)
		* paint_terminator_jitter,
		0.0,
		1.0
	);

	float bands = toon_ramp(
		ramp_in,
		float(toon_steps),
		toon_softness
	);


	// Shadow/light tint.
	vec3 tint = mix(
		shadow_tint.rgb,
		light_tint.rgb,
		bands
	);

	tint = mix(
		vec3(1.0),
		tint,
		tint_strength
	);


	// -----------------------------------------------------------------------
	// Diffuse
	// -----------------------------------------------------------------------

	vec3 diff =
		ALBEDO
		* LIGHT_COLOR
		* bands
		* tint
		* (1.0 - METALLIC)
		* (1.0 / PI)
		* ATTENUATION;

	DIFFUSE_LIGHT += limit_saturation(
		diff,
		saturation_max,
		saturation_compress
	);


	// -----------------------------------------------------------------------
	// PBR-style painted specular
	// -----------------------------------------------------------------------
	//
	// The important difference from the previous version:
	//
	// The highlight is now actually derived from:
	//
	//     F0 -> Fresnel -> GGX -> Smith geometry
	//
	// instead of:
	//
	//     white threshold blob -> arbitrary tint -> energy cap
	//
	// Consequently:
	//
	//   dielectric paint:
	//       F0 ≈ 0.04
	//
	//   metallic material:
	//       F0 ≈ albedo
	//
	//   rough material:
	//       broad/dim highlight
	//
	//   smooth material:
	//       tight/bright highlight
	//
	//   grazing angles:
	//       stronger reflection
	//

	float rough = clamp(
		ROUGHNESS,
		0.045,
		1.0
	);

	float alpha = rough * rough;
	float alpha2 = alpha * alpha;

	vec3 N = normalize(NORMAL);
	vec3 L = normalize(LIGHT);
	vec3 V = normalize(VIEW);
	vec3 H = normalize(L + V);

	float NdotL = max(
		dot(N, L),
		0.0
	);

	float NdotV = max(
		dot(N, V),
		0.0
	);

	float NdotH = max(
		dot(N, H),
		0.0
	);

	float VdotH = max(
		dot(V, H),
		0.0
	);


	if (
		NdotL > 0.0
		&& NdotV > 0.0
	) {

		// -------------------------------------------------------------------
		// Fresnel
		// -------------------------------------------------------------------
		//
		// Dielectric surfaces use approximately 0.04 F0.
		//
		// Metals use their albedo as F0.
		//
		// This is what prevents ordinary painted surfaces from behaving like
		// they have a 100% reflective white coating.
		//

		vec3 dielectric_f0 =
			vec3(0.04);

		vec3 surface_f0 = mix(
			dielectric_f0,
			ALBEDO,
			clamp(
				METALLIC,
				0.0,
				1.0
			)
		);


		// Schlick Fresnel.
		float fresnel_factor = pow(
			1.0 - VdotH,
			5.0
		);

		vec3 F = surface_f0
			+ (
				vec3(1.0)
				- surface_f0
			)
			* fresnel_factor;


		// -------------------------------------------------------------------
		// GGX / Trowbridge-Reitz normal distribution
		// -------------------------------------------------------------------

		float denom =
			NdotH * NdotH
			* (alpha2 - 1.0)
			+ 1.0;

		float D =
			alpha2
			/ max(
				PI
				* denom
				* denom,
				1e-5
			);


		// -------------------------------------------------------------------
		// Smith-Schlick geometry term
		// -------------------------------------------------------------------

		float k = alpha * 0.5;

		float Gv =
			NdotV
			/ max(
				NdotV * (1.0 - k) + k,
				1e-5
			);

		float Gl =
			NdotL
			/ max(
				NdotL * (1.0 - k) + k,
				1e-5
			);

		float G =
			Gv * Gl;


		// -------------------------------------------------------------------
		// Microfacet BRDF
		// -------------------------------------------------------------------

		float spec_brdf =
			(D * G)
			/ max(
				4.0
				* NdotV
				* NdotL,
				1e-5
			);


		// Convert BRDF into reflected light.
		vec3 pbr_spec =
			F
			* spec_brdf
			* LIGHT_COLOR
			* NdotL
			* ATTENUATION;


		// -------------------------------------------------------------------
		// Painterly breakup
		// -------------------------------------------------------------------
		//
		// The brush pattern does NOT replace the PBR highlight.
		//
		// Instead, it determines which parts of the physically-based
		// reflection remain visible.
		//

		float dab = smoothstep(
			0.35,
			0.65,
			v_tone
		);

		float breakup = mix(
			1.0,
			dab,
			toon_specular_breakup
		);


		// -------------------------------------------------------------------
		// Painterly threshold
		// -------------------------------------------------------------------
		//
		// NdotH is used only as an artistic mask layered over the PBR lobe.
		// It therefore cannot turn the entire specular calculation into an
		// arbitrary white dot.
		//

		float threshold = mix(
			0.95,
			0.0,
			toon_specular_size
		);

		float threshold_softness = mix(
			0.002,
			0.4,
			toon_specular_softness
		);

		float lobe = smoothstep(
			threshold,
			min(
				threshold + threshold_softness,
				1.0
			),
			NdotH
		);


		// Keep most of the underlying PBR response while allowing the
		// painterly threshold to shape it.
		float painted_mask = mix(
			1.0,
			lobe,
			0.65
		);

		painted_mask *= breakup;


		// -------------------------------------------------------------------
		// Final painted PBR highlight
		// -------------------------------------------------------------------

		vec3 hl =
			pbr_spec
			* toon_specular_strength
			* painted_mask;


		// -------------------------------------------------------------------
		// Safety ceiling
		// -------------------------------------------------------------------
		//
		// This is now only a safety mechanism rather than the thing that
		// defines the highlight's normal appearance.
		//

		float peak = max(
			hl.r,
			max(
				hl.g,
				hl.b
			)
		);

		if (peak > toon_specular_max) {
			hl *= toon_specular_max
				/ max(
					peak,
					1e-5
				);
		}


		SPECULAR_LIGHT += limit_saturation(
			hl,
			saturation_max,
			saturation_compress
		);
	}
}


// ============================================================================
// NOTE
// ============================================================================
//
// Ambient/sky lighting is added by the engine separately from light().
//
// ALBEDO is already saturation-limited, so ordinary ambient contribution
// inherits that limitation. A strongly coloured environment can still affect
// the final result.
//
// A true final-pixel saturation clamp would require a screen-space
// post-process.
// ============================================================================