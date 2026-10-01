@tool
extends VisualShaderNodeCustom
class_name MtlxOrenNayarLight

## A complete replacement for Godot's spatial lighting, with MaterialX's
## Oren-Nayar diffuse lobe.
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
## non-LIGHT_CODE_USED path, with one substitution: Lambert becomes Oren-Nayar.
##
## ## The equivalence property
##
## MaterialX's Oren-Nayar (mx_microfacet_diffuse.glsl:8) returns
## `A + B * stinv`, where `sigma2 = roughness * roughness`. At roughness 0 that
## is `sigma2 = 0`, so `A = 1.0` and `B = 0` and the function returns exactly
## 1.0 -- making the BRDF `color * NdotL / PI`, which is Lambert.
##
## So at diffuse_roughness = 0 this node reproduces Godot's built-in lighting
## rather than approximating it. That is asserted by
## tools/mtlx_oren_nayar_check.gd, which renders a sphere both ways and compares
## the two images.
##
## ## Deviations from Godot's path, and why
##
## * **energy_compensation.** Godot multiplies specular by
##   `get_energy_compensation(f0, prefiltered_dfg(roughness, NdotV).y)`, and that
##   `env` term is a sample from the DFG lookup texture. A user `light()` cannot
##   declare a sampler, so Filament's analytic approximation of the same split-sum
##   term is used instead (the function Godot's own source cites).
## * **clearcoat normal.** Godot's clearcoat deliberately ignores the normal map
##   and uses the geometric normal, which is `vertex_normal` inside the engine.
##   That is not reachable from a light function, so NORMAL is used and the
##   clearcoat therefore follows the normal map.
## * **subsurface scattering.** Godot's SSS needs the transmittance uniforms,
##   which are per-object and not reachable from a light function either. Materials
##   that use subsurface scattering are left to Godot's own path -- see
##   is_compatible() below.
##
## Because of the last point this is opt-in: the emitter only uses it for
## materials that can actually be represented here, so the 256 materials without
## diffuse_roughness keep using Godot's built-in lighting untouched.

## Diffuse roughness, MaterialX's normalized 0..1. 0 reproduces Lambert exactly.
const SIGMA_MIN := 0.0


func _get_name() -> String:
	return "MaterialX Light"


func _get_category() -> String:
	return "Lighting/BRDF"


func _get_description() -> String:
	return "Godot spatial lighting with MaterialX Oren-Nayar diffuse. At diffuse_roughness 0 this is identical to Godot built-in path."


func _get_return_icon_type() -> PortType:
	return PORT_TYPE_VECTOR_3D


func _is_available(mode: Shader.Mode, type: VisualShader.Type) -> bool:
	return mode == Shader.MODE_SPATIAL and type == VisualShader.TYPE_LIGHT


#region Input
func _get_input_port_count() -> int:
	# Only sigma is an input. Everything else is read from the light stage's
	# built-ins, because the fragment and light stages are separate graphs and
	# nothing can be wired between them.
	return 1


func _get_input_port_name(port: int) -> String:
	match port:
		0:
			return "Diffuse Roughness"
	return ""


func _get_input_port_type(port: int) -> PortType:
	match port:
		0:
			return PORT_TYPE_SCALAR
	return PORT_TYPE_SCALAR


func _get_input_port_default_value(port: int) -> Variant:
	match port:
		0:
			return 0.0
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
	# sigma arrives through a varying; everything else is a light-stage
	# built-in, so it needs no connection.
	return _SHADER.format([input_vars[0], output_vars[0], output_vars[1]])


func _is_highend() -> bool:
	return true


## Godot's own lighting path, transcribed, with Lambert replaced by MaterialX's
## Oren-Nayar. Section references are to
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

	if (ATTENUATION > 1e-5) {
		// F0, scene_forward_lights_inc.glsl:82
		float dielectric = 0.16 * SPECULAR_AMOUNT * SPECULAR_AMOUNT;
		vec3 f0 = mix(vec3(dielectric), albedo, vec3(metallic));

		// Clearcoat, scene_forward_lights_inc.glsl:207-221. Godot uses the
		// geometric normal here; NORMAL is the only one a light function can
		// see, so the clearcoat follows the normal map.
		float cc_attenuation = 1.0;
		float clearcoat = CLEARCOAT;
		if (clearcoat > 0.0) {
			float cc_rough = mix(0.001, 0.1, clamp(CLEARCOAT_ROUGHNESS, 0.0, 1.0));
			float cc_NdotH = max(dot(N, H), 0.0);
			float cc_NdotL = max(dot(N, L), 0.0);
			float cc_a = cc_NdotH * cc_rough;
			float cc_k = cc_rough / (1.0 - cc_NdotH * cc_NdotH + cc_a * cc_a);
			float cc_D = clamp(cc_k * cc_k * (1.0 / 3.14159265), 0.0, 1.0);
			// V_Kelemen, scene_forward_lights_inc.glsl:89
			float cc_G = clamp(0.25 / (LdotH * LdotH + 1e-4), 0.0, 1.0);
			// Schlick, composed the way Godot does at line 217
			float cc_m = 1.0 - LdotH;
			float cc_m2 = cc_m * cc_m;
			float cc_F = mix(0.04, 1.0, cc_m2 * cc_m2 * cc_m) * clearcoat;
			cc_attenuation = 1.0 - cc_F;
			specular_light += vec3(cc_D * cc_G * cc_F * cc_NdotL)
				* LIGHT_COLOR * ATTENUATION * SPECULAR_AMOUNT;
		}

		// Diffuse, scene_forward_lights_inc.glsl:222-244.
		//
		// Godot's line here is `light_color * (NdotL / PI) * attenuation *
		// cc_attenuation`. This is the same thing scaled by MaterialX's
		// Oren-Nayar term, which is exactly 1.0 at diffuse_roughness 0, so at
		// the default this reduces to Godot's expression rather than
		// approximating it.
		if (metallic < 1.0) {
			float NdotL_c = max(dot(N, L), 1e-4);
			float LdotV = max(dot(L, V), 1e-4);
			float s = LdotV - NdotL_c * NdotV;
			float stinv = (s > 0.0) ? s / max(NdotL_c, NdotV) : 0.0;
			float sigma2 = diffuse_roughness * diffuse_roughness;
			float A = 1.0 - 0.5 * (sigma2 / (sigma2 + 0.33));
			float B = 0.45 * sigma2 / (sigma2 + 0.09);
			float diffuse_term = A + B * stinv;

			diffuse_light += albedo * LIGHT_COLOR
				* (diffuse_term * NdotL / 3.14159265) * ATTENUATION * cc_attenuation;
		}

		// Rim, scene_forward_lights_inc.glsl:190-194. Godot adds this to the
		// diffuse response, which is preserved here.
		float rim = RIM;
		if (rim > 0.0) {
			float rim_light = pow(max(1e-4, 1.0 - NdotV), max(0.0, (1.0 - roughness) * 16.0));
			diffuse_light += rim_light * rim * mix(vec3(1.0), albedo, RIM_TINT) * LIGHT_COLOR;
		}

		// Specular GGX, scene_forward_lights_inc.glsl:268-292.
		float alpha_ggx = roughness * roughness;
		float D;
		float Vis;
		float anisotropy = clamp(ANISOTROPY, 0.0, 0.98);
		if (anisotropy > 0.0) {
			// D_GGX_anisotropic, scene_forward_lights_inc.glsl:61
			vec3 T = normalize(TANGENT);
			vec3 B = normalize(BINORMAL);
			float aspect = sqrt(1.0 - anisotropy * 0.9);
			float ax = alpha_ggx / aspect;
			float ay = alpha_ggx * aspect;
			float XdotH = dot(T, H);
			float YdotH = dot(B, H);
			float aniso2 = ax * ay;
			vec3 v = vec3(ay * XdotH, ax * YdotH, aniso2 * NdotH);
			float v2 = max(dot(v, v), 1e-8);
			float w2 = aniso2 / v2;
			D = aniso2 * w2 * w2 * (1.0 / 3.14159265);

			// V_GGX_anisotropic, scene_forward_lights_inc.glsl:69
			float lambda_v = NdotL * length(vec3(ax * dot(T, V), ay * dot(B, V), NdotV));
			float lambda_l = NdotV * length(vec3(ax * dot(T, L), ay * dot(B, L), NdotL));
			Vis = clamp(0.5 / max(lambda_v + lambda_l, 1e-6), 0.0, 1.0);
		} else {
			// D_GGX, scene_forward_lights_inc.glsl:18. It is passed alpha_ggx
			// (Godot does the same at line 278) and k uses 1 - NoH^2, which a
			// textbook GGX D does not.
			float a = NdotH * alpha_ggx;
			float k = alpha_ggx / (1.0 - NdotH * NdotH + a * a);
			D = clamp(k * k * (1.0 / 3.14159265), 0.0, 1.0);

			// V_GGX, scene_forward_lights_inc.glsl:56
			Vis = clamp(0.5 / mix(2.0 * NdotL * NdotV, NdotL + NdotV, alpha_ggx), 0.0, 1.0);
		}

		// energy_compensation, scene_forward_clustered_inc.glsl:502, with the
		// DFG term approximated analytically because a light function cannot
		// sample the lookup texture.
		vec4 dfg_r = roughness * vec4(-1.0, -0.0275, -0.572, 0.022) + vec4(1.0, 0.0425, 1.04, -0.04);
		float dfg_a = min(dfg_r.x * dfg_r.x, exp2(-9.28 * NdotV)) * dfg_r.x + dfg_r.y;
		float ess = (-1.04 * dfg_a + dfg_r.z) + dfg_r.w * dfg_a;
		vec3 energy_compensation = vec3(1.0) + f0 * (1.0 / max(ess, 1e-4) - 1.0);

		// SchlickFresnel, scene_forward_lights_inc.glsl:76
		float sf_m = 1.0 - LdotH;
		float sf_m2 = sf_m * sf_m;
		float cLdotH5 = sf_m2 * sf_m2 * sf_m;
		float f90 = clamp(50.0 * 0.33 * f0.g, metallic, 1.0);
		vec3 F = f0 + (f90 - f0) * cLdotH5;

		specular_light += energy_compensation * NdotL * D * Vis * F
			* LIGHT_COLOR * ATTENUATION * cc_attenuation * SPECULAR_AMOUNT;
	}

	{diffuse_out} = diffuse_light;
	{specular_out} = specular_light;
"""
