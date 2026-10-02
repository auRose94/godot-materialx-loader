@tool
extends VisualShaderNodeCustom
class_name MtlxOrenNayarLight

## A complete replacement for Godot's spatial lighting, with MaterialX's
## Oren-Nayar diffuse and sheen lobes.
##
## ## Why this node exists
##
## Godot's spatial BRDF has no diffuse-roughness input, so `diffuse_roughness`
## had nowhere to go. The obvious place to put it is the light stage -- but
## supplying a `light()` function sets LIGHT_CODE_USED, which makes Godot skip
## its *entire* lighting model (scene_forward_lights_inc.glsl:121). Writing
## `Diffuse Light` alone therefore also throws away specular, clearcoat, rim,
## anisotropy and SSS.
##
## So this node writes the whole thing. It is a transcription of Godot's own
## non-LIGHT_CODE_USED path, with substitutions only where MaterialX asks for
## a lobe Godot does not have: Oren-Nayar in place of Lambert, and Imageworks
## sheen in place of nothing.
##
## ## The equivalence property
##
## MaterialX's Oren-Nayar (mx_microfacet_diffuse.glsl:8) returns
## `A + B * stinv`, where `sigma2 = roughness * roughness`. At roughness 0 that
## is `sigma2 = 0`, so `A = 1.0` and `B = 0` and the function returns exactly
## 1.0 -- making the BRDF `color * NdotL / PI`, which is Lambert. Sheen weight
## 0 contributes nothing and dims nothing.
##
## So at diffuse_roughness = 0 and sheen = 0 this node reproduces Godot's
## built-in lighting rather than approximating it. That is asserted by
## demo/tests/mtlx_light_path_check.gd, which renders a sphere both ways and
## compares the two images.
##
## ## Deviations from Godot's path, and why
##
## * **energy_compensation.** Godot multiplies specular by
##   `get_energy_compensation(f0, prefiltered_dfg(roughness, NdotV).y)`, and
##   that `env` term is a sample from the DFG lookup texture. A user `light()`
##   cannot declare a sampler, so Filament's analytic fit of the same quantity
##   (the single-scatter specular energy, DFG.y) is used instead. Verified
##   numerically against integrate_dfg.glsl's own integration; see the note at
##   the site in _SHADER for why the UE4 mobile fit must not be used here.
## * **clearcoat normal.** Godot's clearcoat deliberately ignores the normal map
##   and uses the geometric normal, which is `vertex_normal` inside the engine.
##   That is not reachable from a light function, so NORMAL is used and the
##   clearcoat therefore follows the normal map. (Moot on this path: the gate
##   refuses clearcoat materials, since CLEARCOAT itself is not readable.)
## * **subsurface scattering.** Godot's SSS needs the transmittance uniforms,
##   which are per-object and not reachable from a light function either.
##   Materials that use subsurface scattering keep it anyway: the engine writes
##   SSS_STRENGTH outside the LIGHT_CODE_USED guard.
## * **indirect light.** Ambient diffuse stays Godot's (Lambert-weighted and
##   albedo-scaled in the fragment stage, outside the light function).
##   MaterialX also scales ambient by the Oren-Nayar / sheen directional
##   albedos; that half is out of reach here and is reported as a known
##   limitation rather than faked.
##
## Because of the indirect gap this is opt-in per project setting, and the
## emitter only uses it for materials that can actually be represented here, so
## the vast majority of materials keep Godot's built-in lighting untouched.

## Diffuse roughness, MaterialX's normalized 0..1. 0 reproduces Lambert exactly.
const SIGMA_MIN := 0.0


func _get_name() -> String:
	return "MaterialX Light"


func _get_category() -> String:
	return "Lighting/BRDF"


func _get_description() -> String:
	return "Godot spatial lighting with MaterialX Oren-Nayar diffuse and Imageworks sheen. At diffuse_roughness 0 and sheen 0 this is identical to the Godot built-in path."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_VECTOR_3D


func _is_available(mode: Shader.Mode, type: VisualShader.Type) -> bool:
	return mode == Shader.MODE_SPATIAL and type == VisualShader.TYPE_LIGHT


#region Input
func _get_input_port_count() -> int:
	# Sigma drives the diffuse lobe; the specular port value drives the
	# dielectric F0 (there is no built-in for the material's SPECULAR port --
	# SPECULAR_AMOUNT is the light's own specular). The sheen trio feeds the
	# Imageworks lobe; left unconnected it is 0 and costs nothing.
	return 5


func _get_input_port_name(port: int) -> String:
	match port:
		0:
			return "Diffuse Roughness"
		1:
			return "Specular Reflectance"
		2:
			return "Sheen Weight"
		3:
			return "Sheen Roughness"
		4:
			return "Sheen Color"
	return ""


func _get_input_port_type(port: int) -> PortType:
	match port:
		4:
			return PORT_TYPE_VECTOR_3D
	return PORT_TYPE_SCALAR


func _get_input_port_default_value(port: int) -> Variant:
	match port:
		0:
			return 0.0
		1:
			return 0.5  # Godot's dielectric default: SPECULAR 0.5 == IOR 1.5
		2:
			return 0.0
		3:
			return 0.3  # MaterialX sheen_roughness default
		4:
			return Vector3.ONE  # MaterialX sheen_color default
	return 0.0
#endregion


#region Output
func _get_output_port_count() -> int:
	return 2


func _get_output_port_name(port: int) -> String:
	match port:
		0:
			return "Diffuse Light"
		1:
			return "Specular Light"
	return ""


func _get_output_port_type(port: int) -> PortType:
	return PORT_TYPE_VECTOR_3D
#endregion


## VisualShaderNodeCustom calls _get_code, not _generate_code
## (visual_shader.cpp:620 checks GDVIRTUAL_IS_OVERRIDDEN(_get_code)).
## Using the ordinary-node name makes the engine skip this node and emit
## nothing, with no error pointing here.
func _get_code(input_vars: Array, output_vars: Array,
		mode: Shader.Mode, type: VisualShader.Type) -> String:
	# The sheen inputs are read from the light stage's built-ins when not
	# connected, so only the connected names are passed in.
	# A Dictionary, because the template uses named placeholders. With an
	# Array, String.format expects {0}/{1} and leaves {sigma} untouched.
	return _SHADER.format({
		"sigma": input_vars[0],
		"specular_in": input_vars[1],
		"sheen_w": input_vars[2],
		"sheen_r": input_vars[3],
		"sheen_c": input_vars[4],
		"diffuse_out": output_vars[0],
		"specular_out": output_vars[1],
	})


func _is_highend() -> bool:
	return true


## Godot's own lighting path, transcribed, with Lambert replaced by MaterialX's
## Oren-Nayar and sheen added. Section references are to
## servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl.
const _SHADER := """
	vec3 N = normalize(NORMAL);
	vec3 L = normalize(LIGHT);
	vec3 V = normalize(VIEW);
	vec3 H = normalize(V + L);

	// light_compute:177-178
	float NdotL = max(dot(N, L), 0.0);
	float NdotV = max(dot(N, V), 1e-4);
	float NdotH = clamp(dot(N, H), 0.0, 1.0);
	float LdotH = clamp(dot(L, H), 0.0, 1.0);

	float diffuse_roughness = max({sigma}, 0.0);
	float roughness = clamp(ROUGHNESS, 0.0, 1.0);
	float metallic = clamp(METALLIC, 0.0, 1.0);
	vec3 albedo = ALBEDO;
	vec3 diffuse_light = vec3(0.0);
	vec3 specular_light = vec3(0.0);

	// The material's SPECULAR port, as F0(metallic, specular, albedo) consumes
	// it at scene_forward_clustered.glsl:2236. The emitter feeds this from the
	// same uniform the fragment's SPECULAR port reads, so the dielectric here
	// matches the port exactly.
	float mx_specular_port = max({specular_in}, 0.0);

	// sheen inputs, MaterialX defaults: weight 0, roughness 0.3, white.
	float mx_sheen_weight = max({sheen_w}, 0.0);
	float mx_sheen_roughness = clamp({sheen_r}, 0.0, 1.0);
	vec3 mx_sheen_color = max({sheen_c}, vec3(0.0));

	if (ATTENUATION > 1e-5) {
		// F0, F0() at scene_forward_lights_inc.glsl:82
		float dielectric = 0.16 * mx_specular_port * mx_specular_port;
		vec3 f0 = mix(vec3(dielectric), albedo, vec3(metallic));

		// Diffuse, scene_forward_lights_inc.glsl:242.
		//
		// Godot's line is `light_color * diffuse_brdf_NL * attenuation *
		// cc_attenuation`, with no albedo in it -- and none should be added
		// here. The renderer applies albedo, AO and the metallic blend *after*
		// the light loop:
		//
		//     diffuse_light *= albedo;              // :3048
		//     diffuse_light *= ao;                  // :3051
		//     diffuse_light *= 1.0 - metallic;      // :3055
		//
		// so multiplying by albedo in here would apply it twice, and the render
		// test measured that as a mean error of 0.022 per channel against
		// Godot's own path -- larger than the whole specular difference.
		//
		// The Oren-Nayar term is a pure multiplier on the BRDF, so folding it
		// into diffuse_brdf_NL keeps the structure identical to Godot's. It is
		// exactly 1.0 at diffuse_roughness 0 (A = 1, B = 0), so at the default
		// this is Godot's expression rather than an approximation of it.
		//
		// There is no cc_attenuation here because this node is only used on
		// materials with no clearcoat -- the gate refuses the rest, since
		// CLEARCOAT is not readable from a light function.
		//
		// The sheen throughput dims the base layers, exactly as MaterialX's
		// <layer> stacks sheen over the diffuse: base response *=
		// 1 - dir_albedo * weight (mx_sheen_bsdf sets bsdf.throughput to that).
		float mx_sheen_throughput = 1.0;
		if (metallic < 1.0) {
			float NdotL_c = max(dot(N, L), 1e-4);
			float LdotV = max(dot(L, V), 1e-4);
			float s = LdotV - NdotL_c * NdotV;
			float stinv = (s > 0.0) ? s / max(NdotL_c, NdotV) : 0.0;
			float sigma2 = diffuse_roughness * diffuse_roughness;
			float A = 1.0 - 0.5 * (sigma2 / (sigma2 + 0.33));
			float B = 0.45 * sigma2 / (sigma2 + 0.09);
			float diffuse_brdf_NL = (A + B * stinv) * NdotL / 3.14159265;

			// Imageworks sheen directional albedo, mx_microfacet_sheen.glsl
			// (rational quadratic fit to Monte Carlo). Used only for the
			// energy split between the sheen and the base.
			float mx_sr2 = mx_sheen_roughness * mx_sheen_roughness;
			vec2 mx_dr = vec2(13.67300, 1.0)
				+ vec2(-68.78018, 61.57746) * NdotV
				+ vec2(799.08825, 442.78211) * mx_sheen_roughness
				+ vec2(-905.00061, 2597.49308) * NdotV * mx_sheen_roughness
				+ vec2(60.28956, 121.81241) * NdotV * NdotV
				+ vec2(1086.96473, 3045.55075) * mx_sr2;
			float mx_sheen_dir_albedo = clamp(mx_dr.x / mx_dr.y, 0.0, 1.0);
			mx_sheen_throughput = 1.0 - mx_sheen_dir_albedo * mx_sheen_weight;

			vec3 mx_base_diffuse = LIGHT_COLOR * diffuse_brdf_NL * ATTENUATION;
			diffuse_light += mx_base_diffuse * mx_sheen_throughput;
		}

		// Sheen response, mx_sheen_bsdf / mx_imageworks_sheen_brdf. F and G
		// are 1.0 by construction; the smoother denominator is the one
		// Imageworks published. Added after the base so the throughput dims
		// the base but not the sheen itself.
		if (mx_sheen_weight > 1e-5 && metallic < 1.0) {
			float mx_NdotL_s = clamp(dot(N, L), 1e-4, 1.0);
			float mx_inv_r = 1.0 / max(mx_sheen_roughness, 0.005);
			float mx_sin2 = 1.0 - NdotH * NdotH;
			float D = (2.0 + mx_inv_r) * pow(mx_sin2, mx_inv_r * 0.5) / (2.0 * 3.14159265);
			float mx_brdf = D / (4.0 * (mx_NdotL_s + NdotV - mx_NdotL_s * NdotV));
			diffuse_light += mx_sheen_color * mx_brdf * mx_NdotL_s * mx_sheen_weight
				* LIGHT_COLOR * ATTENUATION;
		}

		// Backlight, scene_forward_lights_inc.glsl (LIGHT_BACKLIGHT_USED).
		// Nothing in this emitter writes BACKLIGHT, so this is dead code kept
		// only to stay a faithful transcription of Godot's path.
		if (BACKLIGHT != vec3(0.0)) {
			diffuse_light += LIGHT_COLOR * (vec3(1.0 / 3.14159265)
				- vec3(NdotL / 3.14159265)) * BACKLIGHT * ATTENUATION;
		}

		// Specular GGX, scene_forward_lights_inc.glsl:268-292, isotropic only.
		// The anisotropic form needs TANGENT and BINORMAL, which a light
		// function cannot read, so materials that want it are refused instead.
		float alpha_ggx = roughness * roughness;

		// D_GGX, scene_forward_lights_inc.glsl:18. It is passed alpha_ggx
		// (Godot does the same at line 278) and k uses 1 - NoH^2, which a
		// textbook GGX D does not.
		float a = NdotH * alpha_ggx;
		float k = alpha_ggx / (1.0 - NdotH * NdotH + a * a);
		float D = clamp(k * k * (1.0 / 3.14159265), 0.0, 1.0);

		// V_GGX, scene_forward_lights_inc.glsl:56
		float Vis = clamp(0.5 / mix(2.0 * NdotL * NdotV, NdotL + NdotV, alpha_ggx), 0.0, 1.0);

		// energy_compensation, scene_forward_clustered_inc.glsl:502, with the
		// DFG term approximated analytically because a light function cannot
		// sample the lookup texture. The engine's env is the DFG texture's .y,
		// which integrate_dfg.glsl builds as E[G * Vis] -- the specular energy
		// of the single-scatter lobe. This is Filament's analytic fit of that
		// quantity (its own source cites the same listing); numerically it
		// tracks the engine's integrated values to within ~0.05 absolute
		// across the roughness/NoV square, which for this path's dielectrics
		// (f0 <= 0.1) keeps the specular within a couple of percent. Do NOT
		// substitute the UE4 mobile AB.y fit here -- that approximates the
		// F0-independent addend, not the energy, and explodes the
		// compensation at low roughness.
		vec4 dfg_r = roughness * vec4(-1.0, -0.0275, -0.572, 0.022) + vec4(1.0, 0.0425, 1.04, -0.04);
		float dfg_a = min(dfg_r.x * dfg_r.x, exp2(-9.28 * NdotV)) * dfg_r.x + dfg_r.y;
		float ess = (-1.04 * dfg_a + dfg_r.z) + dfg_r.w * dfg_a;
		vec3 energy_compensation = vec3(1.0) + f0 * (1.0 / max(ess, 1e-4) - 1.0);

		// SchlickFresnel, scene_forward_lights_inc.glsl:76
		float sf_m = 1.0 - LdotH;
		float sf_m2 = sf_m * sf_m;
		float cLdotH5 = sf_m2 * sf_m2 * sf_m;
		// f90, scene_forward_lights_inc.glsl:287: the clamp input is the dot
		// of f0 with 50.0 * 0.33, not a single channel of it.
		float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), metallic, 1.0);
		vec3 F = f0 + (f90 - f0) * cLdotH5;

		specular_light += energy_compensation * NdotL * D * Vis * F
			* LIGHT_COLOR * ATTENUATION * SPECULAR_AMOUNT;
	}

	{diffuse_out} = diffuse_light;
	{specular_out} = specular_light;
"""
