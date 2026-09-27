shader_type spatial;

// Painted Toon
// ============================================================================
// A stylised, hand-painted-looking surface shader.
//
// It is a normal PBR-ish material (albedo / normal / metallic / roughness /
// AO / emission maps all supported) whose *direct* lighting is replaced by a
// banded ramp with a soft, irregular terminator, so it reads as brushwork
// rather than as a hard cel outline.  On top of that it adds a back rim light
// that is deliberately independent of the scene's lights.
//
// How the pieces fit together, and why:
//
//   * `light()` is overridden, which in Godot replaces the *entire* built-in
//     direct-light path (see `LIGHT_CODE_USED` in
//     `scene_forward_lights_inc.glsl`).  Ambient / sky / reflection probe
//     contribution is computed in the fragment pass, so it is untouched --
//     which is what keeps the shadowed side readable instead of black.
//
//   * Shadows arrive inside `ATTENUATION` (the engine passes
//     `omni_attenuation * shadow` / `spot_attenuation * shadow` into
//     `light_compute`).  Every lighting term below therefore multiplies by it;
//     drop that multiply and the material stops receiving shadows entirely.
//
//   * The diffuse is accumulated exactly the way the engine does it --
//     `light_color * brdf * (1/M_PI) * attenuation` -- with our ramp standing
//     in for `NdotL`.  Mirroring the engine's structure (rather than inventing
//     our own brightness constant) is what keeps this shader's exposure
//     matching a StandardMaterial3D next to it.
//
//   * The back rim goes into `EMISSION` from `fragment()`, not into `light()`.
//     Two reasons: `light()` runs once per light, so a rim written there would
//     be added N times; and emission is light-independent by construction,
//     which is exactly the "always lit from behind" behaviour we want -- it
//     stays on in shadow, in the dark, and under any light setup.
//
//   * The painting is object-space (see `v_obj_pos`), so the brushwork sticks
//     to the surface and does not swim when the object moves or when the
//     camera orbits.

// ---------------------------------------------------------------------------
// Albedo
// ---------------------------------------------------------------------------
group_uniforms Albedo;
uniform bool use_albedo_texture = false;
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_vertex_color = false;
uniform vec2 uv_scale = vec2(1.0, 1.0);
// Brightness.  Godot's default diffuse is Burley and the ramp here is
// Lambert-shaped, and a matte surface gives up the ambient/IBL sheen a PBR
// material leans on, so converting to this shader lands darker than what it
// replaced.  This lifts the albedo, which is the lever that works in *any*
// lighting — a multiplier on the direct term alone does nothing in a scene lit
// mostly by ambient (measured: 1.0 -> 4.0 on the direct term moved the result
// by 8%).  Push it until the swap stops reading dark; much past 2 it starts
// clipping bright textures, and it cannot reach exact parity with a PBR
// material on its own — see 05-known-issues.md #53 for the residual gap.
uniform float albedo_gain : hint_range(0.0, 4.0) = 2.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Surface — maps and scalars.  Scalars multiply whatever the maps provide, so
// a material can use a map for detail and still be dialled in the inspector.
// ---------------------------------------------------------------------------
group_uniforms Surface;
uniform bool use_normal_map = false;
uniform sampler2D normal_texture : hint_normal;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// Packed ORM, glTF convention: G = roughness, B = metallic (R is ignored;
// use the separate AO slot below).  Multiply, not replace — see above.
uniform bool use_orm_texture = false;
uniform sampler2D orm_texture : hint_default_white;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
// Matte by default: this feeds both the stylised highlight's F0 and the
// ambient/IBL reflection sheen (`SPECULAR`, written in fragment()).  At 0.0 the
// surface catches no reflections at all, which is what a painted look wants —
// a PBR sheen on top of flat bands reads as plastic.
uniform float specular : hint_range(0.0, 1.0) = 0.0;

uniform bool use_ao_texture = false;
uniform sampler2D ao_texture : hint_default_white;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Toon ramp
// ---------------------------------------------------------------------------
group_uniforms Toon;
// 1 band == a smooth gradient; higher values read as more graphic/posterised.
uniform int toon_steps : hint_range(1, 8) = 3;
// 0.0 = hard cel edge, 1.0 = fully blended.  Mid values are the painted look.
uniform float toon_softness : hint_range(0.0, 1.0) = 0.45;
// How far light wraps onto the unlit side.  Keeps the dark side from going
// flat black and gives the ramp room to show more than two tones.
uniform float shadow_wrap : hint_range(0.0, 1.0) = 0.35;
// Classic painter's move: cool shadows, warm light.  Set tint_strength to 0
// to disable and get neutral grey shading.
uniform vec4 shadow_tint : source_color = vec4(0.66, 0.74, 0.98, 1.0);
uniform vec4 light_tint : source_color = vec4(1.0, 0.97, 0.89, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.3;
group_uniforms;

// ---------------------------------------------------------------------------
// Painted noise — a cheap object-space sine field.  Three incommensurate
// octaves cost three `sin` calls (noise-free, seamless, stable) and are plenty
// to break up an otherwise machine-perfect edge.
// ---------------------------------------------------------------------------
group_uniforms PaintedNoise;
uniform float paint_scale : hint_range(1.0, 64.0) = 12.0;
// Wobble the terminator so the band edge looks brushed on rather than
// stencilled.  0.0 disables.
uniform float paint_terminator_jitter : hint_range(0.0, 0.5) = 0.05;
// Tonal variation across large flat areas so they read as brushwork.
// 0.0 disables.
uniform float paint_value_jitter : hint_range(0.0, 0.5) = 0.06;
group_uniforms;

// ---------------------------------------------------------------------------
// Toon specular — a Blinn-Phong lobe put through a threshold, which is what
// produces the single stylised highlight blob of an anime/comic surface
// instead of a physically-correct falloff.
// ---------------------------------------------------------------------------
group_uniforms SpecularHighlight;
uniform float toon_specular_strength : hint_range(0.0, 2.0) = 0.0;
uniform float toon_specular_size : hint_range(0.0, 1.0) = 0.5;
uniform float toon_specular_softness : hint_range(0.0, 1.0) = 0.15;
group_uniforms;

// ---------------------------------------------------------------------------
// Back rim.  This is a fresnel on the view vector: the surface brightens as it
// turns away from the camera, which is precisely what happens when a light
// sits *behind* the subject.  Because it is driven by the view and not by any
// scene light, it always reads as a back light, whatever the lighting is.
// ---------------------------------------------------------------------------
group_uniforms BackRim;
uniform bool rim_enabled = true;
// Alpha is the rim's opacity — it scales the glow like `rim_strength` does, so
// the colour picker's alpha slider dials it down without touching the strength.
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 0.5);
uniform float rim_strength : hint_range(0.0, 4.0) = 0.6;
// 0.0 = thin outline hugging the silhouette, 1.0 = broad wash across the form.
uniform float rim_width : hint_range(0.0, 1.0) = 0.3;
// 0.0 = crisp banded edge, 1.0 = fully soft falloff.
uniform float rim_softness : hint_range(0.0, 1.0) = 0.12;
// Pushes the rim upward (positive) or downward (negative) in world space, for
// when a straight-behind light is not what the shot wants.  The underlying
// fresnel stays view-driven, so this re-aims it without un-behind-ing it.
uniform float rim_top_bias : hint_range(-1.0, 1.0) = 0.7;
// Pick up the surface colour in the rim, as if light were bleeding through.
uniform float rim_albedo_mix : hint_range(0.0, 1.0) = 0.0;
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

// Object-space position (post-skin for skinned meshes), so the painted field
// sticks to the surface instead of swimming through it.
//
// This has to be a varying rather than a global: Godot has no mutable global
// shader variables ("Global non-constant variables are not supported"), so
// there is no way to compute the noise once in fragment() and hand the result
// to light().  Both functions derive it from this varying instead — which also
// makes it independent of how many lights the fragment ends up shading.
varying vec3 v_obj_pos;
varying vec3 v_world_normal;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Three-octave sine field in [0, 1].  Deliberately not a hash noise: sines are
// continuous and seamless at any coordinate, which is what a terminator wobble
// wants, and they cost a fraction of the voxel noise this would otherwise need.
float paint_pattern(vec3 p) {
	float n = 0.0;
	n += sin(p.x * 1.9 + p.y * 1.3) * 0.50;
	n += sin(p.y * 2.7 - p.z * 1.7 + 1.7) * 0.30;
	n += sin(p.z * 4.1 + p.x * 2.9 + 4.2) * 0.20;
	return n * 0.5 + 0.5;
}

// Quantises `x` into `steps` bands with a controllable edge.
//
// `softness` widens the transition centred on each band boundary: at 0 the
// result is a hard cel step, at 1 the banding is fully blended away.  The
// smoothstep keeps the edge itself curved rather than linear, which is what
// makes a mid softness read as a painted gradient.
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
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = UV * uv_scale;

	// --- Albedo -------------------------------------------------------------
	vec3 base = albedo_color.rgb;
	if (use_albedo_texture) {
		base *= texture(albedo_texture, uv).rgb;
	}
	if (use_vertex_color) {
		base *= COLOR.rgb;
	}
	base *= albedo_gain;

	// --- Painted tonal variation -------------------------------------------
	if (paint_value_jitter > 0.0) {
		float paint = paint_pattern(v_obj_pos * paint_scale);
		base *= 1.0 + (paint - 0.5) * 2.0 * paint_value_jitter;
	}

	ALBEDO = base;

	// --- Normal map ---------------------------------------------------------
	if (use_normal_map) {
		NORMAL_MAP = texture(normal_texture, uv).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}

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
	// Ambient / IBL reflection strength.  Left at Godot's default of 0.5 the
	// surface keeps a broad sky sheen regardless of the toon highlight, so the
	// matte setting has to reach this too or "not shiny" is only half true.
	SPECULAR = specular;

	if (use_ao_texture) {
		AO = mix(1.0, texture(ao_texture, uv).r, ao_strength);
	}

	// --- Emission -----------------------------------------------------------
	vec3 emit = emission_color.rgb * emission_energy;
	if (use_emission_texture) {
		emit *= texture(emission_texture, uv).rgb;
	}

	// --- Back rim -----------------------------------------------------------
	// `dot(NORMAL, VIEW)` is 1 when the surface faces the camera and falls to 0
	// at the silhouette, so the complement is a back light's contribution.
	if (rim_enabled) {
		float fresnel = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);

		// Bias toward the top or bottom of the silhouette before banding, so
		// the shaping happens on the raw fresnel rather than on the cut edge.
		if (abs(rim_top_bias) > 0.001) {
			float up = normalize(v_world_normal).y;
			fresnel *= clamp(1.0 + rim_top_bias * up, 0.0, 2.0);
		}

		// Exponential mapping, not linear.  The fresnel rises steeply right at
		// the silhouette, so on a sphere a linear exponent spends almost the
		// whole slider on a 1px outline and only becomes a rim light at the
		// very top of its range.  exp2(3)..exp2(-1) puts "hairline accent" at
		// one end, "broad wash across the form" at the other, and a real rim
		// light in the middle.
		float rim = pow(clamp(fresnel, 0.0, 1.0), exp2(mix(3.0, -1.0, rim_width)));

		float rs = max(rim_softness, 1e-3);
		rim = smoothstep(0.5 - rs * 0.5, 0.5 + rs * 0.5, rim);

		vec3 rim_rgb = rim_color.rgb * rim_color.a * rim * rim_strength;
		rim_rgb *= mix(vec3(1.0), base, rim_albedo_mix);
		emit += rim_rgb;
	}

	EMISSION += emit;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);

	// Lambert wrap.  With wrap at 0 this is plain clamped N·L; at 1 it is
	// half-lambert.  Widening the lit range is what gives the ramp more than
	// two tones to work with on a curved surface.
	float wrapped = clamp((ndotl + shadow_wrap) / (1.0 + shadow_wrap), 0.0, 1.0);

	// Wobble the band edge so it looks brushed on.  Same field as the albedo
	// jitter in fragment(); recomputed here because there is no global to
	// carry it across (see the varying above).
	float paint = paint_pattern(v_obj_pos * paint_scale);
	float ramp_in = clamp(wrapped + (paint - 0.5) * paint_terminator_jitter, 0.0, 1.0);
	float bands = toon_ramp(ramp_in, float(toon_steps), toon_softness);

	// Warm the lit bands, cool the shadowed ones.
	vec3 tint = mix(shadow_tint.rgb, light_tint.rgb, bands);
	tint = mix(vec3(1.0), tint, tint_strength);

	// --- Diffuse ------------------------------------------------------------
	// Same shape as the engine's own accumulation: light_color * brdf *
	// attenuation, with the BRDF carrying the 1/PI.  Metals have no diffuse.
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * bands * tint
			* (1.0 - METALLIC) * (1.0 / PI) * ATTENUATION;

	// --- Stylised highlight -------------------------------------------------
	// A Blinn-Phong lobe pushed through a threshold, so the highlight is a
	// shaped blob rather than a falloff.  Roughness only sets how tight the
	// lobe is; the threshold controls how much of it survives.
	float gloss = clamp(1.0 - ROUGHNESS, 0.0, 1.0);
	float power = exp2(mix(2.0, 11.0, gloss));
	vec3 h = normalize(LIGHT + VIEW);
	float lobe = pow(clamp(dot(NORMAL, h), 0.0, 1.0), power);

	float threshold = mix(0.95, 0.02, toon_specular_size);
	float soft = mix(0.002, 0.4, toon_specular_softness);
	float spec = smoothstep(threshold, min(threshold + soft, 1.0), lobe);

	// Keep the highlight off surfaces the light is not actually hitting.
	spec *= smoothstep(0.0, 0.2, ndotl);

	vec3 f0 = mix(vec3(0.16 * specular * specular), ALBEDO, METALLIC);
	SPECULAR_LIGHT += f0 * spec * toon_specular_strength * LIGHT_COLOR * ATTENUATION;
}
