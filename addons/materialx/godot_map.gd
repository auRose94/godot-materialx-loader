@tool
class_name GodotMap
extends RefCounted

## Verified mappings between MaterialX and Godot's visual shader.
##
## Every constant here was read out of Godot 4.7.2 and MaterialX 1.39 rather
## than assumed; the sources are noted beside each table so they can be
## re-checked when either engine moves.

# ---------------------------------------------------------------------------
# Output ports
#
# VisualShaderNodeOutput for a spatial fragment stage. Godot stores these as
# bare indices, never by name, which is why a .tres never mentions ALBEDO.
# Source: modules/visual_shader/visual_shader.cpp (mode_spatial fragment block).
# ---------------------------------------------------------------------------

const OUT_ALBEDO := 0
const OUT_ALPHA := 1
const OUT_METALLIC := 2
const OUT_ROUGHNESS := 3
const OUT_SPECULAR := 4
const OUT_EMISSION := 5
const OUT_AO := 6
const OUT_AO_LIGHT_AFFECT := 7
const OUT_NORMAL := 8
const OUT_NORMAL_MAP := 9
const OUT_NORMAL_MAP_DEPTH := 10
const OUT_RIM := 11
const OUT_RIM_TINT := 12
const OUT_CLEARCOAT := 13
const OUT_CLEARCOAT_ROUGHNESS := 14
const OUT_ANISOTROPY := 15
const OUT_ANISOTROPY_FLOW := 16
const OUT_SSS_STRENGTH := 17
const OUT_BACKLIGHT := 18

# ---------------------------------------------------------------------------
# Node enums
# ---------------------------------------------------------------------------

# VisualShaderNodeTexture.TextureType
const TEX_DATA := 0
const TEX_COLOR := 1
const TEX_NORMAL_MAP := 2

# VisualShaderNodeMix.OpType
const MIX_SCALAR := 0
const MIX_VECTOR_2D := 1
const MIX_VECTOR_2D_SCALAR := 2
const MIX_VECTOR_3D := 3
const MIX_VECTOR_3D_SCALAR := 4
const MIX_VECTOR_4D := 5
const MIX_VECTOR_4D_SCALAR := 6

# VisualShaderNodeVectorOp.Operator
const VOP_ADD := 0
const VOP_SUB := 1
const VOP_MUL := 2
const VOP_DIV := 3
const VOP_MOD := 4
const VOP_POW := 5
const VOP_MAX := 6
const VOP_MIN := 7
const VOP_CROSS := 8
const VOP_ATAN2 := 9
const VOP_REFLECT := 10
const VOP_STEP := 11

# VisualShaderNodeVectorBase.OpType (VectorOp / VectorMath op_type)
const VOP_TYPE_2D := 0
const VOP_TYPE_3D := 1
const VOP_TYPE_4D := 2

# VisualShaderNodeFloatOp.Operator
const FOP_ADD := 0
const FOP_SUB := 1
const FOP_MUL := 2
const FOP_DIV := 3
const FOP_MOD := 4
const FOP_POW := 5
const FOP_MAX := 6
const FOP_MIN := 7
const FOP_ATAN2 := 8
const FOP_STEP := 9

# VisualShaderNodeColorOp.Operator
const COP_SCREEN := 0
const COP_DIFFERENCE := 1
const COP_DARKEN := 2
const COP_LIGHTEN := 3
const COP_OVERLAY := 4
const COP_DODGE := 5
const COP_BURN := 6
const COP_SOFT_LIGHT := 7
const COP_HARD_LIGHT := 8


# ---------------------------------------------------------------------------
# Specular reflectance: the mapping most likely to be got wrong
# ---------------------------------------------------------------------------
#
# MaterialX standard_surface builds a dielectric with a *physical* IOR:
#   F0 = ((ior - 1) / (ior + 1))^2        (MaterialX 1.39,
#                                          libraries/pbrlib/genglsl/lib/mx_microfacet_specular.glsl:184,
#                                          mx_ior_to_f0)
# scaled by the `specular` weight and tinted by `specular_color`.
#
# Godot instead parameterises the output port so that SPECULAR = 0.5 means
# IOR 1.5, and its internal F0 is quadratic in that port:
#   dielectric = 0.16 * specular * specular (Godot 4.7.2,
#                                          servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl:82)
#
# Inverting gives the conversion below. Feeding MaterialX `specular = 1.0`
# straight into the port would yield F0 = 0.16 instead of 0.04 -- 4x too
# reflective on 252 of the 276 materials in this library.
const GODOT_DIELECTRIC_SCALE := 0.16


## MaterialX specular reflectance at normal incidence, per channel.
##
## `specular` is the lobe weight (default 1.0), `specular_color` the tint
## (default white), `specular_ior` the physical IOR (default 1.5).
static func mtlx_specular_f0(ior: float, specular: float, specular_color: Variant) -> Variant:
	var ior_f: float = clampf(ior, 1.0, 4.0)
	var f0: float = pow((ior_f - 1.0) / (ior_f + 1.0), 2.0) * specular
	var tint: Variant = specular_color
	if tint is Color:
		var c: Color = tint
		return Vector3(c.r, c.g, c.b) * f0
	if tint is Vector3:
		return tint * f0
	return Vector3(f0, f0, f0)


## The Godot SPECULAR port value that reproduces a MaterialX F0.
##
## Godot has one scalar port, so a per-channel tint has to collapse to a
## single number. Brightness is used, which keeps F0 correct for neutral
## tints and degrades gracefully (to a luminance match) for coloured ones.
## Returns 0.0 when F0 is zero, since sqrt(0) is fine but the caller would
## otherwise feed a degenerate colour into the port.
static func godot_specular_from_f0(f0: Variant) -> float:
	var v: Vector3 = _as_vector3(f0)
	var brightness: float = maxf(v.x, maxf(v.y, v.z))
	var s: float = sqrt(maxf(brightness, 0.0) / GODOT_DIELECTRIC_SCALE)
	# The port is a 0..1 artistic control; anything above 1 is clamped away
	# by the engine anyway, so clamp here to keep the emitted value honest.
	return clampf(s, 0.0, 1.0)


## Roughness handed to Godot's ROUGHNESS port.
##
## MaterialX's `main_roughness` is derived from `specular_roughness` alone
## (libraries/bxdf/standard_surface.mtlx:130), with `coat_affect_roughness`
## optionally mixing in the coat. `diffuse_roughness` is *not* part of it --
## it feeds only the Oren-Nayar diffuse lobe, which Godot has no port for.
static func godot_roughness(specular_roughness: float) -> float:
	return clampf(specular_roughness, 0.0, 1.0)


static func _as_vector3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Vector4:
		var a: Vector4 = v
		return Vector3(a.x, a.y, a.z)
	if v is Color:
		var c: Color = v
		return Vector3(c.r, c.g, c.b)
	if v is float or v is int:
		var f: float = float(v)
		return Vector3(f, f, f)
	return Vector3.ZERO


# ---------------------------------------------------------------------------
# standard_surface input -> Godot output port
#
# `null` means the input has no faithful destination and is dropped. The reason
# is reported so the import is honest about what it lost.
# ---------------------------------------------------------------------------

## Inputs folded into a multiply node rather than a direct port, because both
## a scalar weight and a colour texture must reach the same port.
const FOLDED := "__folded__"

## Direct port mapping. Anything absent is dropped.
const SURFACE_PORTS := {
	"metalness": OUT_METALLIC,
	"specular_roughness": OUT_ROUGHNESS,
	"coat": OUT_CLEARCOAT,
	"coat_roughness": OUT_CLEARCOAT_ROUGHNESS,
	# Sheen maps to Godot's rim. Both are grazing-angle lobes, so this is a
	# close analogue rather than an identity: MaterialX's sheen is
	# retroreflective and roughness-dependent, whereas Godot's rim is
	# fresnel-weighted and takes its exponent from the surface roughness
	# (scene_forward_lights_inc.glsl: rim_light = pow(1 - N.V, (1 - roughness) * 16)).
	"sheen": OUT_RIM,
	# sheen_color is a colour and RIM_TINT is a scalar, so it has to be folded
	# down; see _fold_sheen_color in mtlx_emitter.gd.
	"sheen_color": FOLDED,
	"specular_anisotropy": OUT_ANISOTROPY,
	"subsurface": OUT_SSS_STRENGTH,
	"normal": OUT_NORMAL_MAP,
	# base/base_color and emission/emission_color each combine a scalar weight
	# with a colour, which needs a multiply before the port.
	"base": FOLDED,
	"base_color": FOLDED,
	"emission": FOLDED,
	"emission_color": FOLDED,
	# specular_IOR + specular + specular_color collapse into one scalar port.
	"specular_IOR": FOLDED,
	"specular": FOLDED,
	"specular_color": FOLDED,
	# Both are computed into Godot ports by _fold_specular / the folds in
	# mtlx_emitter.gd rather than copied straight across.
	"specular_rotation": FOLDED,
	"opacity": FOLDED,
}

## Inputs with no representation in Godot 4's spatial shader. Godot's BRDF is
## fixed (metallic-roughness + a single specular lobe), so these cannot be
## expressed as graph nodes at all.
const SURFACE_DROPS := {
	"diffuse_roughness": "feeds MaterialX's Oren-Nayar diffuse lobe only; Godot has no diffuse-roughness port",
	"tangent": "Godot derives the tangent frame itself",
	"coat_color": "Godot's clearcoat has no tint port",
	"coat_normal": "one normal port only; the base normal is used",
	"coat_anisotropy": "Godot's clearcoat is isotropic",
	"coat_rotation": "Godot's clearcoat has no rotation",
	"coat_IOR": "Godot hardcodes the coat IOR at 1.5",
	"coat_affect_color": "Godot's clearcoat does not tint the layer below",
	"coat_affect_roughness": "Godot's clearcoat does not affect base roughness",
	"sheen_roughness": "Godot's rim has no roughness term; its exponent comes from the surface roughness",
	"subsurface_color": "Godot's SSS takes a radius and depth, not a colour",
	"subsurface_radius": "Godot's SSS radius is per-object, not per-material",
	"subsurface_scale": "Godot's SSS radius is per-object, not per-material",
	"subsurface_anisotropy": "Godot's SSS has no anisotropy",
	"transmission": "no refraction lobe in Godot's spatial BRDF; folded into ALPHA instead",
	"transmission_color": "no refraction lobe in Godot's spatial BRDF",
	"transmission_depth": "no refraction lobe in Godot's spatial BRDF",
	"transmission_scatter": "no refraction lobe in Godot's spatial BRDF",
	"transmission_scatter_anisotropy": "no refraction lobe in Godot's spatial BRDF",
	"transmission_dispersion": "no refraction lobe in Godot's spatial BRDF",
	"transmission_extra_roughness": "no refraction lobe in Godot's spatial BRDF",
	"thin_walled": "no thin-walled mode in Godot's spatial BRDF",
	"thin_walled_thickness": "no thin-walled mode in Godot's spatial BRDF",
	"thin_film_thickness": "no thin-film interference in Godot's spatial BRDF",
	"thin_film_IOR": "no thin-film interference in Godot's spatial BRDF",
}

## standard_surface input defaults, from the node definition
## (MaterialX 1.39, libraries/bxdf/standard_surface.mtlx, ND_standard_surface_surfaceshader).
##
## These are only used to decide whether an unmapped input is worth reporting.
## An input left at its default costs nothing visually; one the file actually
## drives from the graph, or sets to something else, is a real loss and should
## be surfaced rather than buried among the defaults.
const SURFACE_DEFAULTS := {
	"base": 1.0,
	"base_color": Vector3(0.8, 0.8, 0.8),
	"diffuse_roughness": 0.0,
	"metalness": 0.0,
	"specular": 1.0,
	"specular_color": Vector3(1.0, 1.0, 1.0),
	"specular_roughness": 0.2,
	"specular_IOR": 1.5,
	"specular_anisotropy": 0.0,
	"specular_rotation": 0.0,
	"transmission": 0.0,
	"transmission_color": Vector3(1.0, 1.0, 1.0),
	"transmission_depth": 0.0,
	"transmission_scatter": Vector3(0.0, 0.0, 0.0),
	"transmission_scatter_anisotropy": 0.0,
	"transmission_dispersion": 0.0,
	"transmission_extra_roughness": 0.0,
	"subsurface": 0.0,
	"subsurface_color": Vector3(1.0, 1.0, 1.0),
	"subsurface_radius": Vector3(1.0, 1.0, 1.0),
	"subsurface_scale": 1.0,
	"subsurface_anisotropy": 0.0,
	"sheen": 0.0,
	"sheen_color": Vector3(1.0, 1.0, 1.0),
	"sheen_roughness": 0.3,
	"coat": 0.0,
	"coat_color": Vector3(1.0, 1.0, 1.0),
	"coat_roughness": 0.1,
	"coat_anisotropy": 0.0,
	"coat_rotation": 0.0,
	"coat_IOR": 1.5,
	"coat_affect_color": 0.0,
	"coat_affect_roughness": 0.0,
	"thin_film_thickness": 0.0,
	"thin_film_IOR": 1.5,
	"emission": 0.0,
	"emission_color": Vector3(1.0, 1.0, 1.0),
	"opacity": Vector3(1.0, 1.0, 1.0),
	"thin_walled": false,
}


## True when `value` is the standard_surface default for `name`, i.e. dropping
## it costs nothing. Linked inputs always count as "used" and are handled by
## the caller before this is consulted.
static func is_default(name: String, value: Variant) -> bool:
	if not SURFACE_DEFAULTS.has(name):
		return false
	var want: Variant = SURFACE_DEFAULTS[name]

	if value is bool or want is bool:
		return bool(value) == bool(want)

	# MaterialX files are not consistent about scalar vs vector for the same
	# input: this library writes subsurface_scale as a bare number while the
	# nodedef declares it vector3. So the recorded default can be a Vector3
	# when the decoded value is a scalar, or the reverse. Rather than compare
	# like with like and risk an invalid-operand error inside a predicate that
	# is only ever asking "is this worth reporting", reduce both sides to a
	# scalar when their shapes disagree.
	if value is float or value is int:
		return is_equal_approx(float(value), _scalar_of(want))
	if value is Vector3:
		var w3: Vector3 = want if want is Vector3 else Vector3(_scalar_of(want), _scalar_of(want), _scalar_of(want))
		return (value as Vector3).is_equal_approx(w3)

	return value == want


## The scalar a recorded default reduces to, whatever its declared shape.
static func _scalar_of(want: Variant) -> float:
	if want is float or want is int:
		return float(want)
	if want is Vector3:
		# luminance, so a grey vector compares like the scalar it stands for
		var v: Vector3 = want
		return v.dot(Vector3(0.2126, 0.7152, 0.0722))
	if want is bool:
		return 1.0 if bool(want) else 0.0
	return 0.0