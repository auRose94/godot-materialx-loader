@tool
class_name MtlxEmitter
extends RefCounted

## Builds a Godot VisualShader from a MaterialX surface, using VisualShader's
## own runtime API (add_node / connect_nodes_forced) rather than by writing
## .tres text. That way Godot owns the serialisation and there is no second
## implementation of the format to drift out of sync.
##
## Two entry points:
##   build_file(path)    -> a VisualShader for the file's material
##   report_file(path)   -> a fidelity report, no shader
##
## ## What "faithful" can mean here
##
## Godot's spatial shader has one fixed metallic-roughness BRDF: GGX specular
## plus a single diffuse lobe, no multi-scatter, no Oren-Nayar, no sheen or
## refraction. MaterialX standard_surface is a layered Autodesk Standard
## Surface model. So the graph is reproduced exactly, values are reproduced
## exactly, and the handful of inputs with no Godot equivalent are reported
## rather than silently approximated. See GodotMap for the specifics.

const FRAGMENT := 1  # VisualShader.TYPE_FRAGMENT
const LIGHT := 2  # VisualShader.TYPE_LIGHT
const FIRST_NODE_ID := 2  # VisualShader::add_node rejects ids < 2
const OUTPUT_NODE := 0  # implicit VisualShaderNodeOutput; id 1 is unused

# Experimental custom lighting: a copy of Godot's own lighting model with
# MaterialX's Oren-Nayar diffuse lobe in place of Lambert. Gated behind a project
# setting, and used only for materials that actually drive diffuse_roughness.
const Config := preload("res://addons/materialx/mtlx_config.gd")
const OrenNayarLight := preload("res://addons/materialx/mtlx_oren_nayar_light.gd")

## A connection endpoint: a node in the graph plus one of its output ports.
class Ref2 extends RefCounted:
	var node: int = -1
	var port: int = 0

	func _init(p_node: int = -1, p_port: int = 0) -> void:
		node = p_node
		port = p_port

	func is_valid() -> bool:
		return node >= 0

class Result extends RefCounted:
	var shader: VisualShader
	var ok: bool = false
	var message: String = ""
	var notes: PackedStringArray = []
	var dropped: Dictionary = {}  # input name -> reason
	var missing_textures: PackedStringArray = []

var _doc: MtlxDocument
var _shader: VisualShader
var _next_id := FIRST_NODE_ID
var _cache: Dictionary = {}  # MtlxElement -> Ref2, fragment stage
var _cache_light: Dictionary = {}  # MtlxElement -> Ref2, light stage
var _notes: PackedStringArray = []
var _dropped: Dictionary = {}
var _missing_textures: PackedStringArray = []
## Resource directory the .mtlx lives in, for resolving relative file paths.
var _base_dir: String = "res://"
## Where textures are found, tried in order.
var _texture_roots: PackedStringArray = []

## Which stage the next _add() lands in. The emitter is fragment-first; the
## custom light node and the screen-refraction chain need to place nodes in the
## light stage, and re-emitting a MaterialX sub-graph there needs the whole
## emission machinery to follow. Set _stage, emit, restore.
var _stage: int = FRAGMENT
## Node id -> the stage it was added to. get_node()/connect_nodes() are
## stage-indexed, so every id has to be rememberable.
var _node_stage: Dictionary = {}
## Shader parameter name -> the stage whose parameter node owns the uniform
## declaration. A parameter needed by both stages (the folded `specular` is the
## standing example) is declared by its owner and referenced everywhere else
## through a ParameterRef, because two Parameter nodes with one name would
## emit `uniform float x` twice and fail to compile.
var _param_owners: Dictionary = {}

## Screen-space refraction state, filled by _plan_screen_refraction and spent
## by the base fold and _wire_screen_refraction.
var _refraction_surface_w: Ref2 = null  # how much of the lit surface survives
var _refraction_background_w: Ref2 = null  # how much background replaces it
var _refraction_transmission: Ref2 = null  # the transmission weight itself
## The graph that drives the ROUGHNESS port, for the refraction blur. There is
## no fragment *input* named "roughness" -- the built-in is write-only -- so the
## only way to the same value is the fold that produced it.
var _roughness_ref: Ref2 = null
## The emission chain built by the emission fold, so the refracted background
## can be ADDED to it instead of replacing it.
var _emission_ref: Ref2 = null
## Surface inputs consumed by a feature path (refraction, the light node's
## sheen) rather than dropped. Reported as dropped only when the feature path
## did not actually take them.
var _consumed_by_features: Dictionary = {}
## True when the Oren-Nayar light node took over the material.
var _custom_light_wired: bool = false
## True when the sheen lobe went to the light node rather than Godot's RIM.
var _sheen_wired_light: bool = false
## The brightest-channel collapse of specular_color, shared by the fragment
## fold and the light-stage fold so its note is emitted once.
var _specular_col_scale: float = 1.0


static func build_file(path: String, texture_roots: PackedStringArray = PackedStringArray()) -> Result:
	# The emitter holds per-conversion state, so each conversion needs its own
	# instance; _run() below fills in the Result it is given.
	var emitter := MtlxEmitter.new()
	var doc: MtlxDocument = MtlxDocument.load_from_file(path)
	if doc == null:
		var failed := Result.new()
		failed.message = "could not read " + path
		return failed
	return emitter._run(doc, path, texture_roots)


static func report_file(path: String, texture_roots: PackedStringArray = PackedStringArray()) -> Result:
	return build_file(path, texture_roots)


func _run(doc: MtlxDocument, path: String, texture_roots: PackedStringArray) -> Result:
	var r := Result.new()
	_doc = doc
	_texture_roots = texture_roots
	_base_dir = path.get_base_dir()

	if doc.materials.is_empty():
		r.message = "no <surfacematerial> found"
		return r

	# A file can export more than one material; the first is the one a
	# .mtlx-as-asset conversion represents.
	var material: MtlxDocument.MtlxElement = doc.materials[0]
	var surface: MtlxDocument.MtlxElement = doc.find_surface(material)
	if surface == null:
		r.message = "no standard_surface behind the material"
		return r

	_shader = VisualShader.new()
	_shader.mode = Shader.MODE_SPATIAL

	_emit_surface(surface)
	_apply_layout()

	if _shader.get_node_list(FRAGMENT).is_empty():
		r.message = "nothing was emitted"
		return r

	r.shader = _shader
	r.ok = true
	r.notes = _notes
	r.dropped = _dropped
	r.missing_textures = _missing_textures
	r.notes.append_array(doc.warnings)
	return r


# ---------------------------------------------------------------------------
# Surface
# ---------------------------------------------------------------------------


func _emit_surface(surface: MtlxDocument.MtlxElement) -> void:
	# base/base_color and emission/emission_color each pair a scalar weight
	# with a colour, and both have to land on one port, so each pair is folded
	# through a multiply.
	#
	# Ordering matters twice here:
	# * the refraction state decides both whether `transmission` stays with
	#   _fold_opacity and by how much ALBEDO is dimmed, so it is computed
	#   before the base fold;
	# * the custom-lighting decision decides whether `sheen` goes to Godot's
	#   RIM (fragment) or to the light node (light stage), so it runs before
	#   the sheen fold.
	var refracted: bool = _plan_screen_refraction(surface)
	_fold_into_output(surface, ["base", "base_color"], GodotMap.OUT_ALBEDO, Vector3.ONE, "base", _refraction_surface_w)
	_fold_into_output(surface, ["emission", "emission_color"], GodotMap.OUT_EMISSION, Vector3.ZERO, "emission")
	_fold_specular(surface)
	_fold_anisotropy_flow(surface)
	_fold_subsurface(surface)
	var custom_lit: bool = _try_custom_lighting(surface)
	_fold_sheen(surface, custom_lit)
	if refracted:
		_wire_screen_refraction(surface)
	else:
		_fold_opacity(surface)

	# Inputs handled by the folds above rather than by the direct port loop.
	const FOLDED_INPUTS := [
		"base", "base_color", "emission", "emission_color",
		"specular", "specular_IOR", "specular_color",
		"specular_rotation", "opacity", "transmission", "sheen", "sheen_color",
		"transmission_color", "transmission_depth", "ior",
		"subsurface",
	]
	for key in GodotMap.SURFACE_PORTS.keys():
		var name: String = key
		if name in FOLDED_INPUTS:
			continue  # already folded above
		var port: int = GodotMap.SURFACE_PORTS[name]
		var inp: MtlxDocument.MtlxInput = surface.input(name)
		if inp == null:
			continue
		var src: Ref2 = _emit_input(inp, surface.graph)
		if not src.is_valid():
			continue
		if port == GodotMap.OUT_ROUGHNESS:
			# Remembered for the refraction blur, which needs the material's
			# roughness but has no fragment input to read it from.
			_roughness_ref = src
		_connect_output(src, port)

	# Report only the unmapped inputs the file actually asked for. Anything
	# left at its standard_surface default costs nothing visually, so listing
	# it would bury the real losses in noise.
	for key in surface.inputs.keys():
		var name: String = key
		if GodotMap.SURFACE_PORTS.has(name):
			continue
		if _consumed_by_features.has(name):
			continue  # a feature path took it; reporting it as dropped would lie
		var inp: MtlxDocument.MtlxInput = surface.inputs[name]
		if not _is_worth_reporting(name, inp):
			continue
		_dropped[name] = GodotMap.SURFACE_DROPS.get(name, "no mapping in Godot's spatial output")


## An unmapped input is worth reporting when the graph drives it for real, or
## when its literal differs from the standard_surface default.
func _is_worth_reporting(name: String, inp: MtlxDocument.MtlxInput) -> bool:
	if inp == null:
		return false
	if inp.is_link():
		return not _is_geometry_placeholder(inp)
	var value: Variant = inp.typed_value()
	if value == null:
		return false
	return not GodotMap.is_default(name, value)


## True when a link resolves to a bare geometry node.
##
## These GLSLFX-exported files wire coat_normal and tangent to
## `<normal space="world">` / `<tangent space="world">` placeholders that carry
## no data -- they are just the surface normal and tangent. Reporting them as
## dropped inputs would flag 253 of 276 materials for nothing.
func _is_geometry_placeholder(inp: MtlxDocument.MtlxInput) -> bool:
	var src: MtlxDocument.MtlxElement = _doc.source_element(inp, "")
	if src == null or (src.def != "normal" and src.def != "tangent"):
		return false
	# Only `space` and friends; a scale or an `in` link means real data.
	for k in src.inputs.keys():
		var iname: String = k
		if iname != "space" and iname != "index":
			return false
	return true


func _fold_into_output(surface: MtlxDocument.MtlxElement, names: Array, out_port: int, neutral: Vector3, param_base: String, dim: Ref2 = null) -> void:
	# a * b, where each factor is either a scalar weight, a colour, or absent.
	var mul_id: int = _add(VisualShaderNodeVectorOp.new())
	var mul: VisualShaderNodeVectorOp = _node(mul_id)
	mul.operator = GodotMap.VOP_MUL
	mul.op_type = GodotMap.VOP_TYPE_3D
	mul.set_default_input_values([0, neutral, 1, Vector3.ONE])

	var wired := false
	var idx := 0
	for name in names:
		var inp: MtlxDocument.MtlxInput = surface.input(name)
		if inp == null:
			continue
		var src: Ref2 = _emit_input_as(inp, surface.graph, _scalar_or_vector)
		if not src.is_valid():
			continue
		# Scalar weight has to be splatted into the vector port; connecting a
		# float to a vec3 input is legal in Godot and splats automatically.
		_connect(src, src.port, mul_id, idx)
		idx += 1
		wired = true

	var out_ref := Ref2.new(mul_id, 0)
	if not wired:
		# Nothing but the neutral value; drop the node.
		_shader.remove_node(FRAGMENT, mul_id)
		_next_id -= 1
		if dim == null or not dim.is_valid():
			return
		# Only the dim remains: a scalar splatted onto the port.
		_connect_output(dim, out_port)
		return
	if dim != null and dim.is_valid():
		# Screen-space refraction dims the surface so the background sample
		# replaces rather than stacks on top of it (the engine does the same:
		# `ALBEDO *= 1.0 - ref_amount` in material.cpp).
		out_ref = _vop(GodotMap.VOP_MUL, out_ref, dim)
	if out_port == GodotMap.OUT_EMISSION:
		_emission_ref = out_ref
	_connect_output(out_ref, out_port)


## MaterialX's physical-IOR specular into Godot's artistic SPECULAR port.
##
##   F0        = ((ior - 1) / (ior + 1))^2 * specular * specular_color
##   SPECULAR  = sqrt(F0 / 0.16)
##
## The square root is the whole point: see GodotMap for why. Because 7
## materials in this library drive specular_IOR from the graph and 6 drive
## specular_color, the conversion has to happen in the shader, not at import
## time. Constants are folded so the common case stays a single node, and
## only the parts that actually vary get arithmetic nodes.
##
## specular_color is a per-channel tint that Godot's scalar port cannot
## carry. White is exact; anything else is collapsed to its brightest channel
## so highlights keep their intensity, and that is reported.
func _fold_specular(surface: MtlxDocument.MtlxElement) -> void:
	var ior_in: MtlxDocument.MtlxInput = surface.input("specular_IOR")
	var spec_in: MtlxDocument.MtlxInput = surface.input("specular")
	var col_in: MtlxDocument.MtlxInput = surface.input("specular_color")

	# Computed once and reused by the light-stage fold (if the custom lighting
	# takes the material), so the "collapsed to a scalar" note is not appended
	# twice.
	_specular_col_scale = _specular_color_scale(col_in)
	var f0: Variant = _specular_f0_chain(ior_in, spec_in, _specular_col_scale)

	# All-literal: the whole chain is a constant, so emit it as one adjustable
	# parameter rather than a cloud of arithmetic nodes.
	if f0 is float or f0 is int:
		var pid: int = _add(VisualShaderNodeFloatParameter.new())
		var p: VisualShaderNodeFloatParameter = _node(pid)
		p.parameter_name = "specular"
		p.default_value_enabled = true
		p.default_value = sqrt(maxf(float(f0), 0.0) / GodotMap.GODOT_DIELECTRIC_SCALE)
		# This node owns the uniform declaration; a light-stage copy of it
		# (which the Oren-Nayar node reads) must come through a ParameterRef.
		_param_owners["specular"] = FRAGMENT
		_connect_output(Ref2.new(pid, 0), GodotMap.OUT_SPECULAR)
		return

	var f0_ref: Ref2 = _as_ref(f0)

	# SPECULAR = sqrt(F0 / 0.16); the divide folds into the multiply.
	var scaled: int = _add(VisualShaderNodeFloatOp.new())
	var mul: VisualShaderNodeFloatOp = _node(scaled)
	mul.operator = GodotMap.FOP_MUL
	mul.set_default_input_values([1, 1.0 / GodotMap.GODOT_DIELECTRIC_SCALE])
	_connect(f0_ref, f0_ref.port, scaled, 0)

	var sqrt_id: int = _add(VisualShaderNodeFloatFunc.new())
	var fn: VisualShaderNodeFloatFunc = _node(sqrt_id)
	fn.function = VisualShaderNodeFloatFunc.FUNC_SQRT
	_connect(Ref2.new(scaled, 0), 0, sqrt_id, 0)

	_connect_output(Ref2.new(sqrt_id, 0), GodotMap.OUT_SPECULAR)


## Builds F0 = ((ior-1)/(ior+1))^2 * specular * colour_scale, returning either a
## constant float (everything was literal) or a Ref2 into the graph.
##
## Keeping the value as a Variant matters: _fop() distinguishes a literal from a
## reference, and coercing a constant to a Ref2 would produce node id -1.
func _specular_f0_chain(ior_in: MtlxDocument.MtlxInput, spec_in: MtlxDocument.MtlxInput, col_scale: float) -> Variant:
	var ior: Variant = _literal(ior_in, 1.5)
	var spec: Variant = _literal(spec_in, 1.0)
	var ior_const: bool = ior is float or ior is int
	var spec_const: bool = spec is float or spec is int

	# Everything literal: compute it here and skip the graph entirely, which
	# covers every material in this library whose specular is a constant.
	if ior_const and spec_const:
		var i: float = clampf(float(ior), 1.0, 4.0)
		return pow((i - 1.0) / (i + 1.0), 2.0) * float(spec) * col_scale

	# A constant IOR collapses to ((ior-1)/(ior+1))^2 on its own.
	var term: Variant
	if ior_const:
		var i2: float = clampf(float(ior), 1.0, 4.0)
		term = pow((i2 - 1.0) / (i2 + 1.0), 2.0)
	else:
		var ior_ref: Ref2 = _emit_input_as(ior_in, "", _any)
		var minus: Ref2 = _fop(GodotMap.FOP_SUB, ior_ref, 1.0)
		var plus: Ref2 = _fop(GodotMap.FOP_ADD, ior_ref, 1.0)
		var ratio: Ref2 = _fop(GodotMap.FOP_DIV, minus, plus)
		term = _fop(GodotMap.FOP_MUL, ratio, ratio)

	# Multiply in the specular weight.
	if spec_const:
		if not is_equal_approx(float(spec), 1.0):
			term = _fop(GodotMap.FOP_MUL, term, float(spec))
	elif term is Ref2:
		term = _fop(GodotMap.FOP_MUL, term, _emit_input_as(spec_in, "", _any))

	if not is_equal_approx(col_scale, 1.0) and term is Ref2:
		term = _fop(GodotMap.FOP_MUL, term, col_scale)
	return term


## MaterialX `specular_rotation` (radians) -> Godot `ANISOTROPY_FLOW`.
##
## Godot takes a tangent-space *direction* and builds the frame from it
## (`scene_forward_clustered.glsl`: `tangent = normalize(rot * vec3(flow.x,
## flow.y, 0.0))`), defaulting to (1, 0). So the conversion is exact:
##     flow = (cos(rotation), sin(rotation), 0)
##
## Only 2 of the 276 files set a non-zero rotation, but the default is left
## alone so the graph stays clean for the other 274.
func _fold_anisotropy_flow(surface: MtlxDocument.MtlxElement) -> void:
	var inp: MtlxDocument.MtlxInput = surface.input("specular_rotation")
	if inp == null or inp.is_link():
		# A graph-driven rotation cannot be folded; the default direction
		# matches rotation 0, which is also MaterialX's default.
		return
	var rot: float = float(_literal(inp, 0.0))
	if is_zero_approx(rot):
		return

	var id: int = _add(VisualShaderNodeVec3Constant.new())
	var node: VisualShaderNodeVec3Constant = _node(id)
	node.constant = Vector3(cos(rot), sin(rot), 0.0)
	_connect_output(Ref2.new(id, 0), GodotMap.OUT_ANISOTROPY_FLOW)


## MaterialX `subsurface` -> Godot `SSS_STRENGTH`.
##
## Godot's subsurface scattering is a compute pass that blurs the diffuse buffer,
## and the fragment shader's SSS_STRENGTH is the entire interface to it: the
## value lands in diffuse_buffer.a (scene_forward_clustered.glsl:3074) and becomes
## the blur strength. There is nothing else to fill in.
##
## Two things need care here, and both were found by the test rather than by
## reading:
##
## * Godot's port is a straight multiplier into the blur strength, so a
##   MaterialX weight above 1 over-drives the pass. The weight is documented as
##   0..1 but a file can author anything, and this library writes scalars bare.
## * Writing the port at all enables the subsurface pass, so a file that writes
##   `subsurface = 0` pays for a pass that contributes nothing. Zero is the
##   MaterialX default, so that input is left alone entirely.
##
## `subsurface_color`, `subsurface_radius` and `subsurface_scale` stay dropped:
## SSS_TRANSMITTANCE_COLOR and SSS_TRANSMITTANCE_DEPTH are registered as fragment
## built-ins in shader_types.cpp but are not writable output ports. The node has
## 25 ports and 19-24 are ALPHA_SCISSOR_THRESHOLD, ALPHA_HASH_SCALE,
## ALPHA_ANTIALIASING_EDGE, ALPHA_TEXTURE_COORDINATE, DEPTH and BENT_NORMAL_MAP.
## Verified by writing to each port and reading the name off the generated code;
## see mtlx_port_order.gd.
func _fold_subsurface(surface: MtlxDocument.MtlxElement) -> void:
	var inp: MtlxDocument.MtlxInput = surface.input("subsurface")
	if inp == null:
		return

	if not inp.is_link():
		var raw: Variant = inp.typed_value()
		if raw == null:
			return
		var value: float = float(raw)
		if value <= 0.0:
			# Zero is the default, and writing it would switch the pass on for
			# nothing.
			return
		var clamped := VisualShaderNodeFloatParameter.new()
		clamped.parameter_name = _safe_param_name("subsurface")
		clamped.default_value_enabled = true
		clamped.default_value = clampf(value, 0.0, SSS_STRENGTH_MAX)
		_connect_output(Ref2.new(_add(clamped), 0), GodotMap.OUT_SSS_STRENGTH)
		return

	# Driven by the graph, so the clamp is a real node rather than a constant.
	var src: Ref2 = _emit_input(inp, surface.graph)
	if not src.is_valid():
		return
	var limited := _fop(GodotMap.FOP_MIN, src, SSS_STRENGTH_MAX)
	var floored := _fop(GodotMap.FOP_MAX, limited, 0.0)
	_connect_output(floored, GodotMap.OUT_SSS_STRENGTH)


## Godot's SSS_STRENGTH is not clamped by the engine, so the clamp is ours.
const SSS_STRENGTH_MAX := 1.0


## Screen-space refraction: show what is actually behind a transmissive surface.
##
## Godot's spatial BRDF has no refraction lobe. `transmission` therefore used to
## become ALPHA and nothing else, so clear glass rendered as a uniformly faded
## shell -- see-through in the sense that the background showed through
## everywhere equally, with no displacement at all.
##
## The screen texture makes a real refraction possible. The uniform comes from a
## VisualShaderNodeTexture with source = SOURCE_SCREEN, which emits
##
##     uniform sampler2D <id>_screen_tex : hint_screen_texture;
##
## for a spatial fragment stage (visual_shader_nodes.cpp:778). The parser
## explicitly allows the hint on spatial rather than canvas-only
## (shader_language.cpp:10059), and the renderer supplies the buffer
## (render_forward_clustered.cpp:2369-2373). VisualShaderNodeVectorRefract
## supplies the vector math, since a VisualShader cannot call the language's
## refract() directly -- three inputs (incident, normal, eta), one output.
##
## ## The black-hole bug, and what the engine's own refraction taught
##
## An earlier version kept the material opaque and wrote the refracted sample to
## EMISSION. A material that reads the screen but writes no ALPHA stays in the
## opaque pass -- and the renderer copies the screen texture AFTER that pass
## (render_forward_clustered.cpp:2366). During the draw, the sampler therefore
## still holds the previous frame's copy, which contains the object itself.
## Every frame the surface re-absorbed an image of itself: sky leaked inward
## from the silhouette and compounded, while the centre kept re-sampling its own
## dark body. On a glass canopy the result is a black disc with a glowing ring
## -- a black hole with an accretion disk.
##
## Godot's own BaseMaterial3D refraction cannot do this, and its generated code
## (material.cpp, FEATURE_REFRACTION) is the recipe followed here:
##
## * `ALPHA = 1.0` is written unconditionally -- the engine's comment is
##   "Force transparency on the material (required for refraction)". Writing
##   ALPHA moves the material to the transparent pass, which renders AFTER the
##   screen copy, so the copy no longer contains the object. No feedback.
## * The surface dims by the same amount the background shows
##   (`ALBEDO *= 1.0 - ref_amount`), and the sample is ADDED to EMISSION.
##   Stacking a fully lit surface and a full background sample is what blew the
##   silhouette out into a halo.
## * The sample UV is masked against the depth buffer, blended so a foreground
##   object crossing the displaced sample does not pop in as "background". The
##   engine reconstructs view-space Z through INV_PROJECTION_MATRIX; here the
##   same decision is made by comparing raw window depths, which needs no
##   matrix nodes: the depth texture's .r and FRAGCOORD.z are the same
##   quantity, so "the sampled point is behind me" is exactly
##   `depth_offset > z_frag` either way. The blend window is a tunable
##   parameter rather than the engine's fixed 1 view-metre.
## * The screen sample is blurred by roughness (textureLod, ROUGHNESS * 8) --
##   frosted glass, engine parity, wired through the texture node's lod port.
##
## One approximation remains, and it is the engine's own: the displaced sample
## follows the view-space ray without reprojecting through the frustum. The
## direction is divided by -z (a perspective slope, which the engine's
## `SCREEN_UV - ref_normal.xy * ...` does not even do), so the offset survives
## grazing angles; the magnitude still ignores the focal length and is tuned by
## the `refraction_strength` parameter. Transparent objects behind the glass are
## not in the screen copy, so they do not show through it -- engine parity too.
func _plan_screen_refraction(surface: MtlxDocument.MtlxElement) -> bool:
	if not Config.screen_space_refraction():
		return false

	var transmission: Ref2 = _transmission_ref(surface)
	if not transmission.is_valid():
		return false

	# The transmission and opacity weights decide how the surface and the
	# background are weighted against each other. MaterialX's opacity blends the
	# whole response toward the transmission background, the same shape the
	# engine reaches with `ref_amount = 1.0 - albedo.a`:
	#   background_w = 1 - opacity * (1 - transmission)
	#   surface_w    = 1 - background_w
	var background_w: Ref2 = transmission
	var opacity: Ref2 = _opacity_ref(surface)
	if opacity.is_valid():
		var one_minus_t: Ref2 = _fop(GodotMap.FOP_SUB, 1.0, transmission)
		var kept: Ref2 = _fop(GodotMap.FOP_MUL, opacity, one_minus_t)
		background_w = _fop(GodotMap.FOP_SUB, 1.0, kept)
	_consumed_by_features["transmission"] = true
	_consumed_by_features["transmission_color"] = true
	_consumed_by_features["opacity"] = true
	_refraction_transmission = transmission
	_refraction_background_w = background_w
	_refraction_surface_w = _fop(GodotMap.FOP_SUB, 1.0, background_w)
	return true


## Builds the fragment graph for a planned refraction. Split from
## _plan_screen_refraction because the background sample has to be ADDED to
## whatever the emission fold produced, and that fold runs later.
func _wire_screen_refraction(surface: MtlxDocument.MtlxElement) -> void:
	# Planned earlier; re-deriving it here would emit a second `transmission`
	# uniform (literal parameters are not cached, only element links are).
	var transmission: Ref2 = _refraction_transmission

	# Godot refracts about N with the incident vector pointing into the surface,
	# which is the negated view vector.
	var normal: int = _add_input("normal")
	var view: int = _add_input("view")

	var incident := VisualShaderNodeVectorOp.new()
	incident.set("operator", GodotMap.VOP_MUL)
	incident.set("op_type", VisualShaderNodeVectorOp.OP_TYPE_VECTOR_3D)
	var incident_id: int = _add(incident)
	_connect(Ref2.new(view, 0), 0, incident_id, 0)
	incident.set_default_input_values([1, Vector3(-1, -1, -1)])

	# eta is the ratio of refractive indices, n1 / n2. MaterialX gives the
	# surface IOR directly, so eta = 1 / ior.
	#
	# Guarded, because _fop connects any Ref2 it is handed and an invalid one is
	# not a node -- passing the result of a lookup that found nothing emits a
	# connection from a node that was never added, which the engine rejects with
	# "Condition !g->nodes.has(p_from_node) is true" and no useful context.
	var eta := Ref2.new()
	var ior_ref: Ref2 = _ior_ref(surface)
	if ior_ref.is_valid():
		eta = _fop(GodotMap.FOP_DIV, 1.0, ior_ref)

	var refr := VisualShaderNodeVectorRefract.new()
	var refr_id: int = _add(refr)
	_connect(Ref2.new(incident_id, 0), 0, refr_id, 0)
	_connect(Ref2.new(normal, 0), 0, refr_id, 1)
	if eta.is_valid():
		_connect(eta, 0, refr_id, 2)
	else:
		refr.set_default_input_values([2, 1.0 / 1.5])

	# Perspective slope: the refracted ray's xy per unit of travel away from the
	# camera, which is what the screen-space displacement of the background
	# actually follows. Dividing by -z keeps grazing angles from collapsing the
	# offset; max() guards the divide itself.
	var parts: int = _add(VisualShaderNodeVectorDecompose.new())
	_node(parts).op_type = VisualShaderNodeVectorBase.OP_TYPE_VECTOR_3D
	_connect(Ref2.new(refr_id, 0), 0, parts, 0)
	var neg_z: Ref2 = _fop(GodotMap.FOP_MUL, Ref2.new(parts, 2), -1.0)
	var safe_z: Ref2 = _fop(GodotMap.FOP_MAX, neg_z, 1e-4)
	var slope_x: Ref2 = _fop(GodotMap.FOP_DIV, Ref2.new(parts, 0), safe_z)
	var slope_y: Ref2 = _fop(GodotMap.FOP_DIV, Ref2.new(parts, 1), safe_z)
	var compose: int = _add(VisualShaderNodeVectorCompose.new())
	_node(compose).op_type = VisualShaderNodeVectorBase.OP_TYPE_VECTOR_2D
	_connect(slope_x, 0, compose, 0)
	_connect(slope_y, 0, compose, 1)

	# offset = slope * refraction_strength, exposed so the strength can be
	# tuned per material without rebuilding.
	var strength := VisualShaderNodeFloatParameter.new()
	strength.parameter_name = _safe_param_name("refraction_strength")
	strength.default_value_enabled = true
	strength.default_value = REFRACTION_STRENGTH
	var strength_id: int = _add(strength)

	var scaled := VisualShaderNodeVectorOp.new()
	scaled.set("operator", GodotMap.VOP_MUL)
	scaled.set("op_type", VisualShaderNodeVectorOp.OP_TYPE_VECTOR_2D)
	var scaled_id: int = _add(scaled)
	_connect(Ref2.new(compose, 0), 0, scaled_id, 0)
	_connect(Ref2.new(strength_id, 0), 0, scaled_id, 1)

	var screen_uv := _add_input("screen_uv")
	var offset := VisualShaderNodeVectorOp.new()
	offset.set("operator", GodotMap.VOP_ADD)
	offset.set("op_type", VisualShaderNodeVectorOp.OP_TYPE_VECTOR_2D)
	var offset_id: int = _add(offset)
	_connect(Ref2.new(screen_uv, 0), 0, offset_id, 0)
	_connect(Ref2.new(scaled_id, 0), 0, offset_id, 1)

	# Depth mask: fall back to the undisplaced SCREEN_UV wherever the displaced
	# sample does not land behind the fragment -- a foreground object crossing
	# the sample must not read as background. Both depths are raw window depth,
	# so the comparison needs no projection matrices; the blend window is a
	# parameter because one raw-depth unit spans very different view distances
	# near and far.
	var depth := VisualShaderNodeTexture.new()
	depth.source = VisualShaderNodeTexture.SOURCE_DEPTH
	var depth_id: int = _add(depth)
	_connect(Ref2.new(offset_id, 0), 0, depth_id, 0)
	depth._set_output_ports_expanded(PackedInt32Array([0]))

	var fragcoord := _add_input("fragcoord")
	var frag_parts: int = _add(VisualShaderNodeVectorDecompose.new())
	_node(frag_parts).op_type = VisualShaderNodeVectorBase.OP_TYPE_VECTOR_4D
	_connect(Ref2.new(fragcoord, 0), 0, frag_parts, 0)

	# Behind-me test in raw window depth. Godot 4.3+ uses a REVERSED-Z depth
	# buffer in every renderer -- the opaque pass clears depth to 0.0
	# (render_forward_clustered.cpp:2903) and Compatibility sets glDepthFunc to
	# GL_GEQUAL (rasterizer_scene_gles3.cpp:2873) -- so "farther than me" is a
	# SMALLER value, and the delta is fragment depth minus sample depth. Get
	# this backwards and the mask closes everywhere; the glass renders its
	# undisplaced background and the strength knob does nothing.
	var depth_delta: Ref2 = _fop(GodotMap.FOP_SUB, Ref2.new(frag_parts, 2), Ref2.new(depth_id, 1))

	var softness := VisualShaderNodeFloatParameter.new()
	softness.parameter_name = _safe_param_name("refraction_softness")
	softness.default_value_enabled = true
	softness.default_value = REFRACTION_SOFTNESS
	var softness_id: int = _add(softness)

	var windowed: Ref2 = _fop(GodotMap.FOP_DIV, depth_delta, Ref2.new(softness_id, 0))
	var mask: int = _add(VisualShaderNodeClamp.new())
	_node(mask).set_default_input_values([1, 0.0, 2, 1.0])
	_connect(windowed, windowed.port, mask, 0)

	var mix_uv: int = _add(VisualShaderNodeMix.new())
	_node(mix_uv).op_type = GodotMap.MIX_VECTOR_2D_SCALAR
	_connect(Ref2.new(screen_uv, 0), 0, mix_uv, 0)
	_connect(Ref2.new(offset_id, 0), 0, mix_uv, 1)
	_connect(Ref2.new(mask, 0), 0, mix_uv, 2)

	# The screen sample is blurred by roughness, engine parity
	# (`textureLod(screen_texture, uv, ROUGHNESS * 8.0)` in material.cpp).
	var screen := VisualShaderNodeTexture.new()
	screen.source = VisualShaderNodeTexture.SOURCE_SCREEN
	var screen_id: int = _add(screen)
	_connect(Ref2.new(mix_uv, 0), 0, screen_id, 0)
	if _roughness_ref != null and _roughness_ref.is_valid():
		# Frosted glass, engine parity: the engine samples with
		# textureLod(screen_texture, uv, ROUGHNESS * 8.0). Without a roughness
		# fold to read, the lod stays 0 -- a plain sample is the safe default.
		var blur: Ref2 = _fop(GodotMap.FOP_MUL, _roughness_ref, 8.0)
		_connect(blur, blur.port, screen_id, 1)

	# EMISSION += sampled.rgb * background_w * transmission_color * EXPOSURE.
	#
	# The engine multiplies by EXPOSURE because every other term the fragment
	# adds has the scene's exposure normalisation baked in, and the screen
	# sample reaches around it (scene_shader_forward_clustered.cpp maps
	# EXPOSURE to 1.0 / emissive_exposure_normalization).
	var gain: Ref2 = transmission
	var exposure := _add_input("exposure")
	gain = _fop(GodotMap.FOP_MUL, gain, Ref2.new(exposure, 0))
	gain = _fop(GodotMap.FOP_MUL, gain, _refraction_background_w)
	var tint: MtlxDocument.MtlxInput = surface.input("transmission_color")
	if tint != null:
		var tint_ref: Ref2 = _emit_input(tint, surface.graph)
		if tint_ref.is_valid():
			gain = _vop(GodotMap.VOP_MUL, gain, tint_ref)
	# The screen sample is a vec4 and the gain a scalar or colour, so the
	# multiply stays in 3D mode: Godot coerces the alpha away with it.
	var lit: Ref2 = _vop(GodotMap.VOP_MUL, Ref2.new(screen_id, 0), gain)
	if _emission_ref != null and _emission_ref.is_valid():
		lit = _vop(GodotMap.VOP_ADD, _emission_ref, lit)

	_connect_output(lit, GodotMap.OUT_EMISSION)

	# ALPHA = 1.0, written unconditionally: it is what moves the material into
	# the transparent pass, after the screen copy. See _plan_screen_refraction.
	var opaque := VisualShaderNodeFloatConstant.new()
	opaque.constant = 1.0
	_connect_output(Ref2.new(_add(opaque), 0), GodotMap.OUT_ALPHA)

	_notes.append(
		"transmission rendered as screen-space refraction; the surface joins "
		+ "the transparent pass (and so no longer casts shadows without a "
		+ "depth prepass), dimmed by the amount of background it shows")


## Default strength of the screen-space offset, in SCREEN_UV units per unit of
## ray slope. Small on purpose: it is a displacement of the background sample,
## not a lens.
const REFRACTION_STRENGTH := 0.02

## Width of the depth-mask blend, in raw window-depth units. The engine blends
## over a fixed view-space metre, which raw depth cannot express as one
## constant; this is small enough to read as a mask rather than a gradient and
## is exposed as the `refraction_softness` parameter.
const REFRACTION_SOFTNESS := 0.002


## Adds a fragment-stage input node reading one of the shader's built-ins.
##
## The name is the built-in's *lowercase* key, not the GLSL spelling.
## VisualShaderNodeInput::ports (visual_shader.cpp:3341-3351) holds both:
##
##     { MODE_SPATIAL, TYPE_FRAGMENT, VECTOR_2D, "screen_uv", "SCREEN_UV" }
##                              ^ key          ^ what it emits
##
## so "screen_uv" resolves and "SCREEN_UV" does not. A name that misses the table is
## not an error: the node keeps its default, the generated code shows
## `float n_out = 0.0;` where a vec2 was meant, and the failure is completely
## silent. With NORMAL and VIEW both zero, refract() returns a zero vector, the
## screen offset is zero, and the screen texture is sampled at a constant corner
## pixel -- the graph is wired correctly and the feature does nothing at all.
##
## mtlx_refraction_check could not see this, because it only reads the generated
## code for the words "hint_screen_texture" and "refract(", both of which are
## present. mtlx_refraction_render.gd catches it by holding everything else
## constant and varying only the strength, and measuring whether the background
## behind the sphere moves.
func _add_input(input_name: String) -> int:
	var node := VisualShaderNodeInput.new()
	node.input_name = input_name
	return _add(node)


## VectorOp with a scalar second operand, for the common scale-by-constant case.
func _vop(op: int, a: Ref2, b: Ref2) -> Ref2:
	var id: int = _add(VisualShaderNodeVectorOp.new())
	var node: VisualShaderNodeVectorOp = _node(id)
	node.set("operator", op)
	if a.is_valid():
		_connect(a, a.port, id, 0)
	if b.is_valid():
		_connect(b, b.port, id, 1)
	return Ref2.new(id, 0)


## MaterialX's `ior`, which decides how far the background is displaced.
func _ior_ref(surface: MtlxDocument.MtlxElement) -> Ref2:
	var inp: MtlxDocument.MtlxInput = surface.input("ior")
	if inp == null:
		return Ref2.new()
	var ref: Ref2 = _emit_input(inp, surface.graph)
	if not ref.is_valid():
		return Ref2.new()
	return ref


## MaterialX `opacity` and `transmission` -> Godot `ALPHA`.
##
## Two separate sources of see-through-ness:
##
## * `opacity` is MaterialX's alpha. MaterialX itself reduces the colour to its
##   luminance before use (`luminance` then `extract` in
##   libraries/bxdf/standard_surface.mtlx), so the luminance below is not a
##   choice, it is what the reference implementation does. Connecting the colour
##   straight to ALPHA would instead take the red channel.
##
## * `transmission` is a refraction lobe, and Godot's spatial shader has none.
##   Without this, Glass.mtlx (transmission = 1) renders fully opaque. Alpha is
##   the only way to make it see-through, so transmission is folded in as
##   `1 - transmission`.
##
## Both are skipped when they would leave the material fully opaque, since
## writing ALPHA = 1.0 on all 276 would be noise.
##
## TRANSMISSION_ALPHA_FLOOR exists because a pure `1 - transmission` would make
## clear glass alpha 0 -- completely invisible, with no surface at all. Godot
## cannot refract, so the floor keeps the specular highlights visible, which is
## what sells it as glass. It is an approximation, not physics.
const TRANSMISSION_ALPHA_FLOOR := 0.15

## `include_transmission` is false when screen-space refraction already consumed
## `transmission`. Doing both would show the background twice: once through the
## alpha blend and again as the refracted sample added on top.
func _fold_opacity(surface: MtlxDocument.MtlxElement, include_transmission: bool = true) -> void:
	var alpha: Ref2 = _opacity_ref(surface)
	var transmission: Ref2 = _transmission_ref(surface) if include_transmission else Ref2.new()

	if not alpha.is_valid() and not transmission.is_valid():
		return

	var terms: Array = []
	if alpha.is_valid():
		terms.append(alpha)
	if transmission.is_valid():
		# 1 - transmission, floored.
		var one_minus: Ref2 = _fop(GodotMap.FOP_SUB, 1.0, transmission)
		var clamped: Ref2 = _fop(GodotMap.FOP_MAX, one_minus, TRANSMISSION_ALPHA_FLOOR)
		terms.append(clamped)

	var out_ref: Ref2 = terms[0]
	for i in range(1, terms.size()):
		out_ref = _fop(GodotMap.FOP_MUL, out_ref, terms[i])
	_connect_output(out_ref, GodotMap.OUT_ALPHA)



## Experimental: replace Godot's lighting with a copy that understands MaterialX's
## diffuse_roughness -- and, since 1.2, MaterialX's actual sheen lobe.
##
## Writing anything to the light stage sets LIGHT_CODE_USED, which makes Godot
## skip its entire lighting model (scene_forward_lights_inc.glsl:121). That is why
## this is gated narrowly -- it is only worth doing for a material that has
## diffuse_roughness set and nothing this cannot reproduce.
##
## Returns true when the material was taken over. Callers use that to route
## sheen to the light node instead of Godot's RIM, and to stop reporting
## diffuse_roughness as dropped.
func _try_custom_lighting(surface: MtlxDocument.MtlxElement) -> bool:
	_custom_light_wired = false
	_sheen_wired_light = false
	if not Config.custom_lighting():
		return false

	# Nothing to gain: the default is already exactly Lambert.
	var rough_inp: MtlxDocument.MtlxInput = surface.input("diffuse_roughness")
	if rough_inp == null:
		return false
	if not rough_inp.is_link():
		var v: Variant = rough_inp.typed_value()
		if v == null or GodotMap.is_default("diffuse_roughness", float(v)):
			return false

	# Anything whose lobes this node cannot reproduce. Clearcoat and anisotropy
	# are not readable from a light function at all -- the built-in list in
	# shader_types.cpp does not contain them. Taking such a material would
	# silently drop those lobes.
	#
	# Tested on the enabling input, not on the parameters. coat_roughness is
	# 0.1 in 253 of the 277 files here against a MaterialX default of 0.03, so
	# testing parameters refused every material in the library -- while coat
	# itself is 0 in 253 of them, meaning that lobe is off and the roughness is
	# inert.
	# Subsurface is admitted, after being refused for most of this addon's life.
	#
	# The original reason was that its transmittance is unreachable from a light
	# function. That reason was wrong even when it was written: Godot's scattering
	# is a compute pass over the diffuse buffer, and SSS_STRENGTH is written to
	# diffuse_buffer.a outside the LIGHT_CODE_USED guard
	# (scene_forward_clustered.glsl:3074). A material with subsurface keeps its
	# scattering even when a light function replaces the engine's lighting.
	#
	# Admitting it looked like a regression, because Cream_Onyx rendered 0.10
	# dimmer than on Godot's own lighting. It is not. Cream_Onyx asks for
	# diffuse_roughness = 1.0, and at that value Oren-Nayar is *supposed* to be
	# darker than Lambert:
	#
	#     A = 1.0 - 0.5 * (1.0 / 1.33) = 0.624
	#     B = 0.45 * (1.0 / 1.09)       = 0.413
	#     diffuse_term = A + B * stinv  ->  0.624 .. 1.037
	#
	# A rough diffuse surface reflects less head-on and sends the rest toward
	# grazing angles; that is the lobe's entire purpose. Rendering the same
	# material with diffuse_roughness pinned to 0 measures a delta of 0.0000 against
	# Godot, which is what shows the rest of the transcription is exact and the
	# darkening belongs to the lobe rather than to a fault here.
	#
	# The check that found this -- mtlx_light_path_check -- used to treat any
	# darkening as a failure, which is only true for sigma 0. It now asserts the
	# invariant that actually holds: at sigma 0 the custom path matches Godot.
	#
	# Sheen is admitted where the node can carry it: the node transcribes
	# MaterialX's Imageworks sheen (mx_microfacet_sheen.glsl), fed by uniforms or
	# light-stage nodes. A sheen whose weight/roughness/colour depend on a node
	# the light stage cannot host is refused whole, never half-rendered.
	var sheen_inp: MtlxDocument.MtlxInput = surface.input("sheen")
	var sheen_enabled: bool = _enabled(surface, "sheen")
	if sheen_enabled:
		var sheen_parts := {
			"sheen": sheen_inp,
			"sheen_roughness": surface.input("sheen_roughness"),
			"sheen_color": surface.input("sheen_color"),
		}
		for k in sheen_parts.keys():
			var part: MtlxDocument.MtlxInput = sheen_parts[k]
			if part == null:
				continue  # absent inputs fall back to the node's port defaults
			var part_graph: String = surface.graph
			if not part.is_link():
				continue  # a literal becomes a uniform, always representable
			if not _light_representable(part, part_graph):
				return false
	for enabling in ["coat"]:
		if _enabled(surface, enabling):
			return false
	# Anisotropy has no strength input; any non-zero rotation or anisotropy
	# turns it on.
	if _enabled(surface, "specular_anisotropy"):
		return false
	if _enabled(surface, "specular_rotation"):
		return false

	# sigma cannot be piped in from the fragment stage. VisualShader varyings
	# carry a single mode (visual_shader.cpp:830), so nothing a varying writes in
	# fragment is in scope inside a light function -- the getter emits
	# `var_<name>` for a name that does not exist there.
	#
	# It does not need to be piped, though: a light function runs once per light,
	# so a material constant is the only thing that could have lived there
	# anyway. Emitting it as a constant node in the light stage is both correct
	# and cheaper than a varying.
	#
	# A linked diffuse_roughness is computed in the graph and is therefore not a
	# constant, so it cannot be represented here at all.
	var value: Variant = rough_inp.typed_value()
	if rough_inp.is_link() or value == null:
		return false
	var sigma := VisualShaderNodeFloatConstant.new()
	sigma.constant = maxf(float(value), 0.0)
	var sigma_id: int = _add_light(sigma)

	var light: VisualShaderNodeCustom = OrenNayarLight.new()
	var light_id: int = _add_light(light)
	_connect_light(Ref2.new(sigma_id, 0), 0, light_id, 0)

	# The material's SPECULAR port value drives the dielectric F0, exactly as
	# F0(metallic, specular, albedo) does for the engine's own path
	# (scene_forward_clustered.glsl:2236). A light function has no built-in for
	# that port -- SPECULAR_AMOUNT is the *light's* specular, not the
	# material's -- so the folded value reaches the node through the shared
	# uniform (or, for a graph-driven specular, through the same chain re-emitted
	# in this stage). Port 1 must always be wired: an unconnected custom-node
	# input compiles to an empty string (see _wire_sheen_to_light).
	var spec_ref: Ref2 = _specular_port_in_light(surface)
	if not spec_ref.is_valid():
		spec_ref = Ref2.new(_add_light(_constant_for("float", 0.5)), 0)
	_connect_light(spec_ref, 0, light_id, 1)

	if sheen_enabled:
		if not _wire_sheen_to_light(surface, light_id):
			# The gate vetted the sheen inputs, so this should not be
			# reachable; if a driver changes and it is, the light node must go
			# too -- leaving it half-wired ships a shader that does not compile.
			_teardown_light_stage()
			return false
		_sheen_wired_light = true
		_consumed_by_features["sheen_roughness"] = true
	else:
		# Ports 2-4 still have to be wired: an unconnected custom-node input
		# reaches _get_code as an empty string and the GLSL fails to compile.
		_wire_sheen_defaults_to_light(light_id)

	# The light node's two outputs go to the light stage's own output ports:
	# DIFFUSE_LIGHT = 0, SPECULAR_LIGHT = 1.
	_connect_light(Ref2.new(light_id, 0), 0, OUTPUT_NODE, 0)
	# from_port is passed explicitly and overrides the Ref2, so this must be 1 and
	# not 0 -- otherwise SPECULAR_LIGHT receives the diffuse value and the
	# specular lobe is lost.
	_connect_light(Ref2.new(light_id, 1), 1, OUTPUT_NODE, 1)

	# Post-build self-check: every input of the custom node has to be wired.
	# An unconnected custom-node input reaches _get_code as an empty string --
	# "max(, 0.0)" -- and the shader fails to compile, all of it, not just the
	# broken lobe. Guarded against rather than trusted: a version of this addon
	# left running across an addon update (the editor caches scripts) once
	# saved 22 broken .tres this way, and the mech scene rendered the sky
	# through them as glowing white blotches. The check runs on the final
	# wiring, because nothing after it touches the light stage; on failure the
	# node and its stage are torn down and the material falls back to Godot's
	# own lighting with a note.
	if not _light_stage_self_check(light_id):
		_teardown_light_stage()
		_custom_light_wired = false
		_sheen_wired_light = false
		_consumed_by_features.erase("diffuse_roughness")
		_consumed_by_features.erase("sheen_roughness")
		_notes.append("custom light node had an unwired input after wiring; "
			+ "fell back to Godot's own lighting -- please report this")
		return false

	_custom_light_wired = true
	_consumed_by_features["diffuse_roughness"] = true
	if sheen_enabled:
		_notes.append(
			"diffuse_roughness and sheen evaluated with MaterialX lobes; this "
			+ "replaces Godot's lighting for this material")
	else:
		_notes.append(
			"diffuse_roughness evaluated with an Oren-Nayar lobe; this replaces "
			+ "Godot's lighting for this material")
	return true


## True when the custom light node's every input port has a connection, and at
## least one of its outputs reaches the light-stage output.
func _light_stage_self_check(light_id: int) -> bool:
	var light_stage: VisualShaderNodeCustom = _node(light_id)
	if light_stage == null:
		return false
	# Custom nodes expose their ports through the script callbacks, not the
	# C++ getters VisualShaderNode has: calling get_input_port_count() on one
	# is a nonexistent-function error, which used to abort the whole build.
	var port_count: int = light_stage.call("_get_input_port_count")
	var connected: Dictionary = {}
	for c in _shader.get_node_connections(LIGHT):
		var d: Dictionary = c
		if int(d["to_node"]) != light_id:
			continue
		connected[int(d["to_port"])] = true
	for i in port_count:
		if not connected.has(i):
			return false
	# And its outputs must reach the output node.
	var output_wired: Dictionary = {"0": false, "1": false}
	for c2 in _shader.get_node_connections(LIGHT):
		var d2: Dictionary = c2
		if int(d2["from_node"]) != light_id:
			continue
		if int(d2["to_node"]) != OUTPUT_NODE:
			continue
		output_wired[str(int(d2["from_port"]))] = true
	return output_wired["0"] and output_wired["1"]


## Removes every user node from the light stage, leaving only the implicit
## output. Callers must also forget anything they wired to those nodes.
func _teardown_light_stage() -> void:
	for id in _shader.get_node_list(LIGHT):
		if id == OUTPUT_NODE:
			continue
		_shader.remove_node(LIGHT, id)
		_node_stage.erase(id)


## The material's SPECULAR port value, computed in the light stage.
##
## The fragment fold already emitted the chain (or the single folded parameter);
## re-emitting here reuses those uniforms through ParameterRefs and duplicates
## only the constant and arithmetic nodes, which carry no state.
func _specular_port_in_light(surface: MtlxDocument.MtlxElement) -> Ref2:
	var prev := _stage
	_stage = LIGHT
	var f0: Variant = _specular_f0_chain(
		surface.input("specular_IOR"), surface.input("specular"), _specular_col_scale)
	var out := Ref2.new()
	if f0 is float or f0 is int:
		var node := _parameter_for("float", "specular",
			sqrt(maxf(float(f0), 0.0) / GodotMap.GODOT_DIELECTRIC_SCALE))
		out = Ref2.new(_add(node), 0)
	else:
		var f0_ref: Ref2 = _as_ref(f0)
		if f0_ref.is_valid():
			# SPECULAR = sqrt(F0 / 0.16); the divide folds into the multiply.
			var scaled: int = _add(VisualShaderNodeFloatOp.new())
			var mul: VisualShaderNodeFloatOp = _node(scaled)
			mul.operator = GodotMap.FOP_MUL
			mul.set_default_input_values([1, 1.0 / GodotMap.GODOT_DIELECTRIC_SCALE])
			_connect(f0_ref, f0_ref.port, scaled, 0)

			var sqrt_id: int = _add(VisualShaderNodeFloatFunc.new())
			var fn: VisualShaderNodeFloatFunc = _node(sqrt_id)
			fn.function = VisualShaderNodeFloatFunc.FUNC_SQRT
			_connect(Ref2.new(scaled, 0), 0, sqrt_id, 0)
			out = Ref2.new(sqrt_id, 0)
	_stage = prev
	return out


## Wires the sheen inputs into the light node:
## port 2 = weight, port 3 = roughness (default 0.3), port 4 = colour
## (default white). Everything is emitted in the light stage: literals become
## uniforms owned by this stage, links are re-emitted as light-stage node
## chains (already vetted by _light_representable).
##
## Every port ends up wired, even when only the port default is wanted: a
## script-constructed VisualShaderNodeCustom never gets its port defaults
## filled in (update_input_port_default_values() runs on editor events), so an
## unconnected input reaches _get_code as an empty string and the generated
## GLSL fails to compile. Constants are cheaper than finding that out again.
func _wire_sheen_to_light(surface: MtlxDocument.MtlxElement, light_id: int) -> bool:
	var prev := _stage
	_stage = LIGHT
	var weight: Ref2 = _emit_input_or_null(surface.input("sheen"), surface.graph)
	var rough: Ref2 = _emit_input_or_null(surface.input("sheen_roughness"), surface.graph)
	var color: Ref2 = _emit_input_or_null(surface.input("sheen_color"), surface.graph)

	if not weight.is_valid():
		_stage = prev
		return false
	if not rough.is_valid():
		rough = Ref2.new(_add(_constant_for("float", 0.3)), 0)
	if not color.is_valid():
		color = Ref2.new(_add(_constant_for("color3", Vector3.ONE)), 0)
	_connect_light(weight, weight.port, light_id, 2)
	_connect_light(rough, rough.port, light_id, 3)
	_connect_light(color, color.port, light_id, 4)
	_stage = prev
	return true


## Wires the light node's sheen ports to their MaterialX defaults, for materials
## that do not use the lobe at all.
func _wire_sheen_defaults_to_light(light_id: int) -> void:
	var prev := _stage
	_stage = LIGHT
	var weight := Ref2.new(_add(_constant_for("float", 0.0)), 0)
	var rough := Ref2.new(_add(_constant_for("float", 0.3)), 0)
	var color := Ref2.new(_add(_constant_for("color3", Vector3.ONE)), 0)
	_connect_light(weight, 0, light_id, 2)
	_connect_light(rough, 0, light_id, 3)
	_connect_light(color, 0, light_id, 4)
	_stage = prev


## True when a link's whole upstream chain consists of nodes the light stage
## can host. The emitter's node set is stage-agnostic (constants, arithmetic,
## textures, mixes), so this is mostly a guard against unknown node defs, which
## emit nothing and would silently zero the lobe.
func _light_representable(inp: MtlxDocument.MtlxInput, graph: String, depth: int = 0) -> bool:
	if inp == null or not inp.is_link():
		return true  # a literal becomes a uniform, always representable
	if depth > 64:
		return false  # cyclic or absurd; refuse rather than loop
	var src: MtlxDocument.MtlxElement = _doc.source_element(inp, graph)
	if src == null:
		return false
	if not src.def in LIGHT_EMITTABLE_DEFS:
		return false
	for k in src.inputs.keys():
		var child: MtlxDocument.MtlxInput = src.inputs[k]
		if not _light_representable(child, src.graph, depth + 1):
			return false
	return true


## Every node def the emitter understands. The light stage hosts all of them --
## none of them touch fragment-only output ports -- so representability is
## exactly "the emitter knows this node".
const LIGHT_EMITTABLE_DEFS := [
	"constant", "image", "texcoord", "mix",
	"multiply", "add", "subtract", "divide", "power", "max", "min",
	"extract", "normal", "normalmap", "tangent",
	"clamp", "floor", "invert", "sqrt", "absolutevalue",
	"dot", "normalize", "convert", "combine3", "overlay", "hsvadjust",
	"tiledimage",
]


## Sheen routing: the light node's Imageworks lobe when the custom lighting
## took the material, Godot's RIM otherwise.
##
## The RIM fallback is a close analogue rather than an identity, and its shape
## is wrong in a way that shows: MaterialX's sheen is retroreflective and
## roughness-dependent, while Godot's rim is fresnel-weighted with an exponent
## from the surface roughness. On a black fabric that rim paints a wide white
## ring around every face -- the "black hole with a disk" look the real lobe
## replaces on the custom path.
func _fold_sheen(surface: MtlxDocument.MtlxElement, custom_lit: bool) -> void:
	var inp: MtlxDocument.MtlxInput = surface.input("sheen")
	if inp == null:
		return
	if custom_lit and _sheen_wired_light:
		# The light node carries the lobe; writing RIM too would stack two
		# sheens. RIM is inert under LIGHT_CODE_USED anyway.
		return

	var src: Ref2 = _emit_input_or_null(inp, surface.graph)
	if not src.is_valid():
		return
	_connect_output(src, GodotMap.OUT_RIM)
	_fold_sheen_color(surface)


## Godot's RIM_TINT is a scalar, not a colour.
##
## scene_forward_lights_inc.glsl:193 mixes the rim between white and the albedo
## by it:
##     diffuse_light += rim_light * rim * mix(vec3(1.0), albedo, rim_tint) * light_color;
## so 0 leaves the sheen white and 1 tints it with the base colour. MaterialX's
## sheen_color is a colour, so it has to be reduced to "how far from white is
## this sheen", which is one minus its luminance. A white sheen -- the MaterialX
## default -- therefore yields 0 and stays white, which is the case that has to
## be right.
##
## This loses hue: two different saturated sheens with equal brightness both land
## on the same tint. RIM_TINT is a scalar, so there is nothing better to map.
func _fold_sheen_color(surface: MtlxDocument.MtlxElement) -> void:
	var inp: MtlxDocument.MtlxInput = surface.input("sheen_color")
	if inp == null:
		return
	# The default is opaque white, which is tint 0 and therefore a no-op.
	if not inp.is_link() and GodotMap.is_default("sheen_color", GodotMap._as_vector3(_literal(inp, null))):
		return

	var src: Ref2 = _emit_input_or_null(inp, surface.graph)
	if not src.is_valid():
		return
	var luma: Ref2 = _luminance_ref(src)
	var one_minus: Ref2 = _fop(GodotMap.FOP_SUB, 1.0, luma)
	# Clamp into 0..1, since a saturated sheen has luminance below 1.
	var clamped: Ref2 = _fop(GodotMap.FOP_MIN, one_minus, 1.0)
	var clamped2: Ref2 = _fop(GodotMap.FOP_MAX, clamped, 0.0)
	_connect_output(clamped2, GodotMap.OUT_RIM_TINT)


## The surface's opacity as a scalar, or an invalid ref when it is opaque.
func _opacity_ref(surface: MtlxDocument.MtlxElement) -> Ref2:
	var inp: MtlxDocument.MtlxInput = surface.input("opacity")
	if inp == null:
		return Ref2.new()

	var value: Variant = _literal(inp, null)
	var is_colour: bool = inp.is_link() or value is Vector3 or value is Color
	if not is_colour and value != null and is_equal_approx(float(value), 1.0):
		return Ref2.new()  # opaque, leave ALPHA alone
	if is_colour and not inp.is_link() and GodotMap.is_default("opacity", GodotMap._as_vector3(value)):
		return Ref2.new()  # opaque white, the MaterialX default

	var src: Ref2 = _emit_input_or_null(inp, surface.graph)
	if not src.is_valid():
		return Ref2.new()
	if not is_colour:
		return src

	# Rec.709 luminance, matching MaterialX's own reduction of opacity.
	return _luminance_ref(src)


## A colour reduced to a scalar by Rec.709 luminance.
##
## The weights are MaterialX's, not Godot's: MaterialX reduces colour to a
## scalar with this exact formula (standard_surface.mtlx uses luminance + extract
## on opacity), so matching it is what keeps a converted value identical.
func _luminance_ref(src: Ref2) -> Ref2:
	var wid: int = _add(VisualShaderNodeVec3Constant.new())
	var wnode: VisualShaderNodeVec3Constant = _node(wid)
	wnode.constant = Vector3(0.2126, 0.7152, 0.0722)
	var did: int = _add(VisualShaderNodeDotProduct.new())
	_connect(src, src.port, did, 0)
	_connect(Ref2.new(wid, 0), 0, did, 1)
	return Ref2.new(did, 0)


## The surface's transmission as a scalar, or an invalid ref when it is 0.
func _transmission_ref(surface: MtlxDocument.MtlxElement) -> Ref2:
	var inp: MtlxDocument.MtlxInput = surface.input("transmission")
	if inp == null:
		return Ref2.new()
	var value: Variant = _literal(inp, 0.0)
	if value != null and not inp.is_link() and is_zero_approx(float(value)):
		return Ref2.new()  # not transmissive, the overwhelmingly common case
	var src: Ref2 = _emit_input_or_null(inp, surface.graph)
	return src if src.is_valid() else Ref2.new()


## A float op node with one or both operands supplied; a float value is set as
## the port's default, a Ref2 is wired.
##
## The Ref2's own port is honoured, not assumed to be 0: this chain feeds the
## refraction mask with FRAGCOORD.z (decompose port 2) and the depth texture's
## r (expanded port 1), and a hardwired 0 once made the mask read FRAGCOORD.x
## -- depth minus screen x, which is meaningless and sat below zero almost
## everywhere, so the mask closed and the refraction went inert.
func _fop(op: int, a: Variant, b: Variant) -> Ref2:
	var id: int = _add(VisualShaderNodeFloatOp.new())
	var node: VisualShaderNodeFloatOp = _node(id)
	node.operator = op
	var defaults: Array = []
	if a is float or a is int:
		defaults += [0, float(a)]
	else:
		var a_ref := _as_ref(a)
		_connect(a_ref, a_ref.port, id, 0)
	if b is float or b is int:
		defaults += [1, float(b)]
	else:
		var b_ref := _as_ref(b)
		_connect(b_ref, b_ref.port, id, 1)
	if not defaults.is_empty():
		node.set_default_input_values(defaults)
	return Ref2.new(id, 0)


func _as_ref(v: Variant) -> Ref2:
	if v is Ref2:
		return v
	return Ref2.new()


## The literal value of an input, or null when it is a link.
func _literal(inp: MtlxDocument.MtlxInput, fallback: Variant) -> Variant:
	if inp == null:
		return fallback
	var v: Variant = inp.typed_value()
	return fallback if v == null else v


## scalar strength of specular_color: 1.0 for white or absent, otherwise the
## brightest channel. Godot has one SPECULAR port, so a tint cannot be exact.
func _specular_color_scale(inp: MtlxDocument.MtlxInput) -> float:
	var v: Variant = _literal(inp, Vector3.ONE)
	var c: Vector3 = GodotMap._as_vector3(v)
	if c.is_equal_approx(Vector3.ONE):
		return 1.0
	if inp != null and inp.is_link():
		_notes.append(
			"specular_color is graph-driven; collapsed to a scalar for Godot's SPECULAR port")
	return maxf(c.x, maxf(c.y, c.z))


# ---------------------------------------------------------------------------
# Input resolution
# ---------------------------------------------------------------------------


## Emits whatever drives `inp`, whether a literal, a parameter, or a node.
func _emit_input(inp: MtlxDocument.MtlxInput, graph: String) -> Ref2:
	return _emit_input_as(inp, graph, _any)


func _emit_input_as(inp: MtlxDocument.MtlxInput, graph: String, literal_fn: Callable) -> Ref2:
	if inp == null:
		return Ref2.new()

	var src: MtlxDocument.MtlxElement = _doc.source_element(inp, graph)
	if src != null:
		return _emit_element(src)

	# A literal. Parameters are preferred over constants so the material stays
	# tweakable in the Visual Shader editor after conversion.
	var value: Variant = inp.typed_value()
	if value == null:
		return Ref2.new()
	var type: String = _doc.effective_type(inp, graph)
	if not MtlxValue.is_tweakable(type):
		return Ref2.new()
	var id: int = _add(_parameter_for(type, inp.name, value))
	return Ref2.new(id, 0)


## Wraps a literal in whatever node the caller wants. Used so a scalar weight
## can share the parameter machinery with colours.
func _scalar_or_vector(type: String, name: String, value: Variant) -> VisualShaderNode:
	return _parameter_for(type, name, value)


func _any(type: String, name: String, value: Variant) -> VisualShaderNode:
	return _parameter_for(type, name, value)


## Local variable names Godot's visual shader nodes emit in their generated
## code. A shader parameter becomes a `uniform` of the same name, so a
## parameter called "base" collides with the `float base` that
## VisualShaderNodeColorOp declares and the shader fails to compile with
## "Redefinition of 'base'".
const RESERVED_PARAM_NAMES := [
	"base", "blend", "b", "c", "d", "e", "g", "p", "q", "r", "K",
	"samp", "max1", "max2", "_bv",
	# Locals the Oren-Nayar light node's code declares. A parameter sharing one
	# of these names would shadow the uniform inside light() and fail to
	# compile with "Redefinition".
	"mx_specular_port", "mx_sheen_weight", "mx_sheen_roughness",
	"mx_sheen_color", "mx_sheen_throughput", "mx_sheen_dir_albedo",
	"mx_base_diffuse", "mx_NdotL_s", "mx_brdf",
]


## A parameter name that will not collide with Godot's generated locals.
func _safe_param_name(name: String) -> String:
	if RESERVED_PARAM_NAMES.has(name):
		return name + "_mx"
	return name


## A node for a literal, as a shader parameter.
##
## Parameters are the same uniform whichever stage reads them, but the
## declaration is emitted once per Parameter node, so a name needed by two
## stages (the folded `specular` reaches both the SPECULAR port and the
## Oren-Nayar light node) must have exactly one owner. The first request wins
## ownership; later requests from another stage get a ParameterRef, which emits
## the same uniform without declaring it.
func _parameter_for(type: String, name: String, value: Variant) -> VisualShaderNode:
	var safe := _safe_param_name(name)
	var owner_stage: int = int(_param_owners.get(safe, -1))
	if owner_stage != -1 and owner_stage != _stage:
		var ref := VisualShaderNodeParameterRef.new()
		ref.parameter_name = safe
		return ref
	if owner_stage == -1:
		_param_owners[safe] = _stage
	match type:
		"float", "float1":
			var f := VisualShaderNodeFloatParameter.new()
			f.parameter_name = safe
			f.default_value_enabled = true
			f.default_value = float(value)
			return f
		"color3", "vector3":
			var v := VisualShaderNodeVec3Parameter.new()
			v.parameter_name = safe
			v.default_value_enabled = true
			v.default_value = _to_vec3(value)
			return v
		"color4", "vector4":
			var v4 := VisualShaderNodeVec4Parameter.new()
			v4.parameter_name = safe
			v4.default_value_enabled = true
			v4.default_value = _to_vec4(value)
			return v4
		"vector2":
			var v2 := VisualShaderNodeVec2Parameter.new()
			v2.parameter_name = safe
			v2.default_value_enabled = true
			v2.default_value = _to_vec2(value)
			return v2
		"integer", "int":
			var i := VisualShaderNodeIntParameter.new()
			i.parameter_name = safe
			i.default_value_enabled = true
			i.default_value = int(value)
			return i
		"boolean", "bool":
			var b := VisualShaderNodeBooleanParameter.new()
			b.parameter_name = safe
			b.default_value_enabled = true
			b.default_value = bool(value)
			return b
	return VisualShaderNodeFloatParameter.new()


# ---------------------------------------------------------------------------
# Element emission
# ---------------------------------------------------------------------------


func _emit_element(el: MtlxDocument.MtlxElement) -> Ref2:
	var cache: Dictionary = _cache_light if _stage == LIGHT else _cache
	if cache.has(el):
		return cache[el]

	var ref: Ref2 = _emit_uncached(el)
	cache[el] = ref
	return ref


func _emit_uncached(el: MtlxDocument.MtlxElement) -> Ref2:
	match el.def:
		"constant":
			return _emit_constant(el)
		"image":
			return _emit_image(el)
		"texcoord":
			return _emit_texcoord(el)
		"mix":
			return _emit_mix(el)
		"multiply", "add", "subtract", "divide", "power", "max", "min":
			return _emit_arith(el)
		"extract":
			return _emit_extract(el)
		"normal":
			return _emit_normal(el)
		"normalmap":
			return _emit_normalmap(el)
		"tangent":
			return _emit_tangent(el)
		"clamp", "floor", "invert", "sqrt", "absolutevalue":
			return _emit_unary(el)
		"dot":
			return _emit_dot(el)
		"normalize":
			return _emit_normalize(el)
		"convert":
			return _emit_convert(el)
		"combine3":
			return _emit_combine3(el)
		"overlay":
			return _emit_overlay(el)
		"hsvadjust":
			return _emit_hsvadjust(el)
		"tiledimage":
			return _emit_tiledimage(el)
	# Unrecognised node: report it and leave the consumer with its default
	# rather than emitting a wrong node.
	_notes.append("unsupported MaterialX node <%s> (%s)" % [el.def, el.name])
	return Ref2.new()


func _emit_constant(el: MtlxDocument.MtlxElement) -> Ref2:
	var value: Variant = el.input_value("value")
	if value == null:
		return Ref2.new()
	var id: int = _add(_constant_for(el.type, value))
	return Ref2.new(id, 0)


## Godot's constant nodes all expose their value as a property named
## `constant`, not `value` (vs_nodes/visual_shader_nodes.cpp, *_bind_methods).
func _constant_for(type: String, value: Variant) -> VisualShaderNode:
	match type:
		"color3", "vector3":
			var v := VisualShaderNodeVec3Constant.new()
			v.constant = _to_vec3(value)
			return v
		"color4", "vector4":
			var v4 := VisualShaderNodeVec4Constant.new()
			# `constant` on this node is a legacy Quaternion; the Vector4 value
			# lives in the internal `constant_v4` property
			# (vs_nodes/visual_shader_nodes.cpp, VisualShaderNodeVec4Constant::_bind_methods).
			v4.constant_v4 = _to_vec4(value)
			return v4
		"vector2":
			var v2 := VisualShaderNodeVec2Constant.new()
			v2.constant = _to_vec2(value)
			return v2
		"integer", "int":
			var i := VisualShaderNodeIntConstant.new()
			i.constant = int(value)
			return i
		"boolean", "bool":
			var b := VisualShaderNodeBooleanConstant.new()
			b.constant = bool(value)
			return b
	var f := VisualShaderNodeFloatConstant.new()
	f.constant = float(value)
	return f


## A texture sample.
##
## Output ports are expanded so consumers can take a channel directly without a
## swizzle node: 0 = full texel, 1 = r, 2 = g, 3 = b, 4 = a.
## Godot lays those out that way (visual_shader.cpp, expanded output ports).
func _emit_image(el: MtlxDocument.MtlxElement) -> Ref2:
	var file_inp: MtlxDocument.MtlxInput = el.input("file")
	if file_inp == null:
		return Ref2.new()
	var rel: String = file_inp.value.strip_edges()
	if rel == "":
		return Ref2.new()

	var res_path: String = _resolve_texture(rel)
	if res_path == "":
		if not _missing_textures.has(rel):
			_missing_textures.append(rel)
		return Ref2.new()

	var tex: Texture2D = load(res_path)
	if tex == null:
		_missing_textures.append(rel)
		return Ref2.new()

	var id: int = _add(VisualShaderNodeTexture.new())
	var node: VisualShaderNodeTexture = _node(id)
	node.source = VisualShaderNodeTexture.SOURCE_TEXTURE
	node.texture = tex
	# colorspace, not data type, decides this: an sRGB base colour map and a
	# linear data map can both be type="color3", and only one of them wants
	# : source_color on the sampler.
	node.texture_type = _texture_type_for(file_inp, el)

	var uv: MtlxDocument.MtlxInput = el.input("texcoord")
	if uv != null:
		var uv_src: Ref2 = _emit_input_as(uv, el.graph, _any)
		if uv_src.is_valid():
			_connect(uv_src, uv_src.port, id, 0)

	node._set_output_ports_expanded(PackedInt32Array([0]))
	return Ref2.new(id, 0)


func _texture_type_for(file_inp: MtlxDocument.MtlxInput, el: MtlxDocument.MtlxElement) -> int:
	if file_inp.is_srgb():
		return GodotMap.TEX_COLOR
	# A vector3 image with no colorspace in this library is a tangent-space
	# normal map; that is the only non-colour use for that type.
	if el.type == "vector3" and not file_inp.is_srgb():
		return GodotMap.TEX_NORMAL_MAP
	return GodotMap.TEX_DATA


func _emit_texcoord(el: MtlxDocument.MtlxElement) -> Ref2:
	# MaterialX texcoord indexes the uvset array; index 0 is Godot's primary UV.
	# Godot 4.7 has no dedicated UV node: UV and UV2 are built-ins reached through
	# VisualShaderNodeInput.
	var idx: int = int(el.input_value("index", 0.0))
	var id: int = _add(VisualShaderNodeInput.new())
	var node: VisualShaderNodeInput = _node(id)
	node.input_name = "uv" if idx == 0 else "uv2"
	return Ref2.new(id, 0)


func _emit_mix(el: MtlxDocument.MtlxElement) -> Ref2:
	var fg: Ref2 = _emit_input_or_null(el.input("fg"), el.graph)
	var bg: Ref2 = _emit_input_or_null(el.input("bg"), el.graph)
	var factor: Ref2 = _emit_input_or_null(el.input("mix"), el.graph)

	var type: String = el.type
	var factor_is_scalar: bool = el.input("mix") != null and el.input("mix").type == "float"

	var id: int = _add(VisualShaderNodeMix.new())
	var node: VisualShaderNodeMix = _node(id)
	node.op_type = _mix_op_type(type, factor_is_scalar)

	# MaterialX's mix is fg/bg inverted relative to GLSL's mix():
	#   MaterialX  out = bg * (1 - factor) + fg * factor
	#   Godot      out = mix(A, B, T)   = A * (1 - T) + B * T
	# so bg must land on port A (0) and fg on port B (1).
	#
	# Verified against MaterialX 1.39: the node definition declares
	# <output name="out" defaultinput="bg"/>, and mx_mix_bsdf computes
	# `mix(bg.response, fg.response, mixValue)`.
	# Getting this backwards silently turns every blend into its complement --
	# which is what turned the brick materials' dark blue "LeaksColor" grime
	# into the entire surface.
	if bg.is_valid():
		_connect(bg, bg.port, id, 0)
	if fg.is_valid():
		_connect(fg, fg.port, id, 1)

	# Unconnected ports keep Godot's own defaults; supply neutral values so a
	# half-wired mix still produces something sensible. Ports stay in ascending
	# order, which set_default_input_values requires.
	var defaults: Array = []
	if not bg.is_valid():
		defaults += [0, _neutral_for(type)]
	if not fg.is_valid():
		defaults += [1, _neutral_for(type)]
	if factor.is_valid():
		_connect(factor, factor.port, id, 2)
	else:
		# With no factor, MaterialX yields bg.
		defaults += [2, 0.0]
	if not defaults.is_empty():
		node.set_default_input_values(defaults)
	return Ref2.new(id, 0)


func _mix_op_type(type: String, factor_is_scalar: bool) -> int:
	var is_vector: bool = type.begins_with("vector") or type.begins_with("color")
	match type:
		"vector2":
			return GodotMap.MIX_VECTOR_2D_SCALAR if factor_is_scalar else GodotMap.MIX_VECTOR_2D
		"vector3", "color3":
			return GodotMap.MIX_VECTOR_3D_SCALAR if factor_is_scalar else GodotMap.MIX_VECTOR_3D
		"vector4", "color4":
			return GodotMap.MIX_VECTOR_4D_SCALAR if factor_is_scalar else GodotMap.MIX_VECTOR_4D
	return GodotMap.MIX_SCALAR


## Binary arithmetic, dispatched to the scalar or vector op node.
func _emit_arith(el: MtlxDocument.MtlxElement) -> Ref2:
	var a: Ref2 = _emit_input_or_null(el.input("in1"), el.graph)
	var b: Ref2 = _emit_input_or_null(el.input("in2"), el.graph)

	var is_scalar: bool = el.type == "float" or el.type == "integer"
	var id: int = _add(VisualShaderNodeFloatOp.new() if is_scalar else VisualShaderNodeVectorOp.new())
	var node: VisualShaderNode = _node(id)

	var table: Dictionary = _arith_table(el.def, is_scalar)
	if table.is_empty():
		_notes.append("no operator for <%s> (%s)" % [el.def, el.type])
		return Ref2.new()

	node.set("operator", table["op"])
	if node is VisualShaderNodeVectorOp:
		node.set("op_type", _vector_op_type(el.type))

	if a.is_valid():
		_connect(a, a.port, id, 0)
	if b.is_valid():
		_connect(b, b.port, id, 1)
	return Ref2.new(id, 0)


func _arith_table(def: String, is_scalar: bool) -> Dictionary:
	var so: Dictionary = {
		"add": GodotMap.FOP_ADD, "subtract": GodotMap.FOP_SUB,
		"multiply": GodotMap.FOP_MUL, "divide": GodotMap.FOP_DIV,
		"power": GodotMap.FOP_POW, "max": GodotMap.FOP_MAX, "min": GodotMap.FOP_MIN,
	}
	var vo: Dictionary = {
		"add": GodotMap.VOP_ADD, "subtract": GodotMap.VOP_SUB,
		"multiply": GodotMap.VOP_MUL, "divide": GodotMap.VOP_DIV,
		"power": GodotMap.VOP_POW, "max": GodotMap.VOP_MAX, "min": GodotMap.VOP_MIN,
	}
	var t: Dictionary = so if is_scalar else vo
	if not t.has(def):
		return {}
	return {"op": t[def]}


func _vector_op_type(type: String) -> int:
	match type:
		"vector2":
			return GodotMap.VOP_TYPE_2D
		"vector4", "color4":
			return GodotMap.VOP_TYPE_4D
	return GodotMap.VOP_TYPE_3D


## Channel extraction. The texel port of an expanded texture already exposes
## r/g/b/a, so an image channel costs nothing; anything else needs a swizzle.
func _emit_extract(el: MtlxDocument.MtlxElement) -> Ref2:
	var src_inp: MtlxDocument.MtlxInput = el.input("in")
	if src_inp == null:
		return Ref2.new()
	var src: Ref2 = _emit_input_or_null(src_inp, el.graph)
	if not src.is_valid():
		return Ref2.new()

	var idx: int = int(el.input_value("index", 0.0))
	var src_el: MtlxDocument.MtlxElement = _doc.source_element(src_inp, el.graph)
	if src_el != null and src_el.def == "image":
		# 1..4 map to r,g,b,a on the expanded texture.
		if idx >= 0 and idx <= 3:
			return Ref2.new(src.node, 1 + idx)
	return Ref2.new(src.node, src.port)


## A <normalmap> node: a tangent-space normal sampled from a texture.
##
## Godot's NORMAL_MAP port takes the raw map and decodes it itself -- it
## defaults to vec3(0.5) and does xy = xy*2-1 (see
## scene_forward_clustered.glsl, `normal_map.xy = normal_map.xy * 2.0 - 1.0`).
## So the texture must be sampled and passed straight through; emitting any
## kind of constant here would be wrong, because vec3(1,1,1) decodes to a
## heavily tilted normal rather than a flat one.
func _emit_normalmap(el: MtlxDocument.MtlxElement) -> Ref2:
	var src: Ref2 = _emit_input_or_null(el.input("in"), el.graph)
	if not src.is_valid():
		return Ref2.new()

	# The texture feeding a normalmap needs Godot's : hint_normal sampler so it
	# decodes as a normal (BC5/RGTC aware) rather than as raw data.
	var node: VisualShaderNode = _node(src.node)
	if node is VisualShaderNodeTexture:
		node.texture_type = GodotMap.TEX_NORMAL_MAP

	# MaterialX scales the perturbation; Godot has NORMAL_MAP_DEPTH, which
	# blends between the geometric and mapped normal. Close enough, and only
	# used when a file actually sets scale.
	var scale: float = float(el.input_value("scale", 1.0))
	if not is_equal_approx(scale, 1.0):
		var sid: int = _add(VisualShaderNodeFloatParameter.new())
		var p: VisualShaderNodeFloatParameter = _node(sid)
		p.parameter_name = "normal_scale"
		p.default_value_enabled = true
		p.default_value = clampf(scale, 0.0, 1.0)
		_connect_output(Ref2.new(sid, 0), GodotMap.OUT_NORMAL_MAP_DEPTH)
		_notes.append("normalmap scale routed to NORMAL_MAP_DEPTH (an approximation)")
	return src


## A bare <normal> node: the surface's own geometric normal.
##
## Godot derives this itself, so there is nothing to emit. Returning an invalid
## ref leaves NORMAL_MAP at Godot's flat default, which is exactly right. A
## <normal> that genuinely carries data is handled by _emit_normalmap's path via
## its `in` input.
func _emit_normal(el: MtlxDocument.MtlxElement) -> Ref2:
	return _emit_input_or_null(el.input("in"), el.graph)


## A <tangent> node. Godot builds its own tangent frame, so a tangent from the
## graph has nowhere to go.
func _emit_tangent(el: MtlxDocument.MtlxElement) -> Ref2:
	return _emit_input_or_null(el.input("out"), el.graph)


func _emit_unary(el: MtlxDocument.MtlxElement) -> Ref2:
	var src: Ref2 = _emit_input_or_null(el.input("in"), el.graph)
	if not src.is_valid():
		return Ref2.new()
	match el.def:
		"clamp":
			var id: int = _add(VisualShaderNodeClamp.new())
			_connect(src, src.port, id, 0)
			var lo: Variant = el.input_value("lo")
			var hi: Variant = el.input_value("hi")
			var n: VisualShaderNodeClamp = _node(id)
			if lo != null:
				n.set_default_input_values([1, float(lo)])
			if hi != null:
				var d: Array = n.get_default_input_values()
				d.append(2)
				d.append(float(hi))
				n.set_default_input_values(d)
			return Ref2.new(id, 0)
		"floor":
			var fid: int = _add(VisualShaderNodeFloatFunc.new())
			var f: VisualShaderNodeFloatFunc = _node(fid)
			f.function = VisualShaderNodeFloatFunc.FUNC_FLOOR
			_connect(src, src.port, fid, 0)
			return Ref2.new(fid, 0)
		"invert":
			var iid: int = _add(VisualShaderNodeVectorOp.new())
			var iv: VisualShaderNodeVectorOp = _node(iid)
			iv.operator = GodotMap.VOP_SUB
			iv.op_type = GodotMap.VOP_TYPE_3D
			# invert(color) == 1 - color
			iv.set_default_input_values([0, Vector3.ONE])
			_connect(src, src.port, iid, 1)
			return Ref2.new(iid, 0)
		"sqrt":
			var sid: int = _add(VisualShaderNodeFloatFunc.new())
			var s: VisualShaderNodeFloatFunc = _node(sid)
			s.function = VisualShaderNodeFloatFunc.FUNC_SQRT
			_connect(src, src.port, sid, 0)
			return Ref2.new(sid, 0)
		"absolutevalue":
			var aid: int = _add(VisualShaderNodeFloatFunc.new())
			var a: VisualShaderNodeFloatFunc = _node(aid)
			a.function = VisualShaderNodeFloatFunc.FUNC_ABS
			_connect(src, src.port, aid, 0)
			return Ref2.new(aid, 0)
	return Ref2.new()


func _emit_dot(el: MtlxDocument.MtlxElement) -> Ref2:
	var a: Ref2 = _emit_input_or_null(el.input("in1"), el.graph)
	var b: Ref2 = _emit_input_or_null(el.input("in2"), el.graph)
	var id: int = _add(VisualShaderNodeDotProduct.new())
	if a.is_valid():
		_connect(a, a.port, id, 0)
	if b.is_valid():
		_connect(b, b.port, id, 1)
	return Ref2.new(id, 0)


func _emit_normalize(el: MtlxDocument.MtlxElement) -> Ref2:
	var src: Ref2 = _emit_input_or_null(el.input("in"), el.graph)
	if not src.is_valid():
		return Ref2.new()
	var id: int = _add(VisualShaderNodeVectorFunc.new())
	var n: VisualShaderNodeVectorFunc = _node(id)
	n.function = VisualShaderNodeVectorFunc.FUNC_NORMALIZE
	n.set_op_type(VisualShaderNodeVectorFunc.OP_TYPE_VECTOR_3D)
	_connect(src, src.port, id, 0)
	return Ref2.new(id, 0)


func _emit_convert(el: MtlxDocument.MtlxElement) -> Ref2:
	var src: Ref2 = _emit_input_or_null(el.input("in"), el.graph)
	if not src.is_valid():
		return Ref2.new()
	# scalar <-> vector conversion is implicit in Godot: connecting a float to
	# a vec3 splats it, and a vec3 into a float takes .x.
	return src


func _emit_combine3(el: MtlxDocument.MtlxElement) -> Ref2:
	var x: Ref2 = _emit_input_or_null(el.input("in1"), el.graph)
	var y: Ref2 = _emit_input_or_null(el.input("in2"), el.graph)
	var z: Ref2 = _emit_input_or_null(el.input("in3"), el.graph)
	var id: int = _add(VisualShaderNodeVectorCompose.new())
	var n: VisualShaderNodeVectorCompose = _node(id)
	n.set_default_input_values([0, 0.0, 1, 0.0, 2, 0.0])
	if x.is_valid():
		_connect(x, x.port, id, 0)
	if y.is_valid():
		_connect(y, y.port, id, 1)
	if z.is_valid():
		_connect(z, z.port, id, 2)
	return Ref2.new(id, 0)


func _emit_overlay(el: MtlxDocument.MtlxElement) -> Ref2:
	var bg: Ref2 = _emit_input_or_null(el.input("bg"), el.graph)
	var fg: Ref2 = _emit_input_or_null(el.input("fg"), el.graph)
	var id: int = _add(VisualShaderNodeColorOp.new())
	var n: VisualShaderNodeColorOp = _node(id)
	n.operator = GodotMap.COP_OVERLAY
	if bg.is_valid():
		_connect(bg, bg.port, id, 0)
	if fg.is_valid():
		_connect(fg, fg.port, id, 1)
	return Ref2.new(id, 0)


## hsvadjust: convert to HSV, add to hue, scale saturation and value, convert
## back.
##
## The spec (MaterialX.StandardNodes.md, node-hsvadjust) defines this as
## RGB -> HSV, then hue += amount.x, saturation *= amount.y, value *= amount.z,
## then HSV -> RGB. Hue wraps at the 0..1 boundaries and amount.x of 1.0 is a
## no-op, since 1.0 is a full 360 degree turn.
##
## This needed no custom GLSL after all: VisualShaderNodeColorFunc has
## FUNC_RGB2HSV and FUNC_HSV2RGB, so the whole node is four native nodes. An
## earlier version of this file claimed it was not representable and passed the
## value through as identity, which was wrong -- the conversions Godot was
## missing were on the node, not the function list.
func _emit_hsvadjust(el: MtlxDocument.MtlxElement) -> Ref2:
	var colour: Ref2 = _emit_input_or_null(el.input("in"), el.graph)
	if not colour.is_valid():
		return Ref2.new()
	var amount: Ref2 = _emit_input_or_null(el.input("amount"), el.graph)
	if not amount.is_valid():
		return colour  # nothing to adjust by; identity

	# colour -> hsv
	var to_hsv: int = _add(VisualShaderNodeColorFunc.new())
	var th: VisualShaderNodeColorFunc = _node(to_hsv)
	th.function = VisualShaderNodeColorFunc.FUNC_RGB2HSV
	_connect(colour, colour.port, to_hsv, 0)

	# Split both vectors so each channel can be adjusted on its own.
	var hsv_parts: int = _add(VisualShaderNodeVectorDecompose.new())
	_node(hsv_parts).op_type = VisualShaderNodeVectorBase.OP_TYPE_VECTOR_3D
	_connect(Ref2.new(to_hsv, 0), 0, hsv_parts, 0)
	var amount_parts: int = _add(VisualShaderNodeVectorDecompose.new())
	_node(amount_parts).op_type = VisualShaderNodeVectorBase.OP_TYPE_VECTOR_3D
	_connect(amount, amount.port, amount_parts, 0)

	# hue += amount.x, wrapped. fract() is what implements the wrap-around.
	var hue: Ref2 = _component_op(hsv_parts, 0, GodotMap.FOP_ADD, amount_parts, 0)
	var wrapped: int = _add(VisualShaderNodeFloatFunc.new())
	var wrap_fn: VisualShaderNodeFloatFunc = _node(wrapped)
	wrap_fn.function = VisualShaderNodeFloatFunc.FUNC_FRACT
	_connect(hue, hue.port, wrapped, 0)

	# saturation *= amount.y, value *= amount.z
	var sat: Ref2 = _component_op(hsv_parts, 1, GodotMap.FOP_MUL, amount_parts, 1)
	var val: Ref2 = _component_op(hsv_parts, 2, GodotMap.FOP_MUL, amount_parts, 2)

	var rebuilt: int = _add(VisualShaderNodeVectorCompose.new())
	_node(rebuilt).op_type = VisualShaderNodeVectorBase.OP_TYPE_VECTOR_3D
	_connect(Ref2.new(wrapped, 0), 0, rebuilt, 0)
	_connect(sat, 0, rebuilt, 1)
	_connect(val, 0, rebuilt, 2)

	# hsv -> colour
	var to_rgb: int = _add(VisualShaderNodeColorFunc.new())
	var tr: VisualShaderNodeColorFunc = _node(to_rgb)
	tr.function = VisualShaderNodeColorFunc.FUNC_HSV2RGB
	_connect(Ref2.new(rebuilt, 0), 0, to_rgb, 0)
	return Ref2.new(to_rgb, 0)


## One channel of two decomposed vectors, put through a float operation.
func _component_op(a_id: int, a_idx: int, op: int, b_id: int, b_idx: int) -> Ref2:
	var id: int = _add(VisualShaderNodeFloatOp.new())
	var node: VisualShaderNodeFloatOp = _node(id)
	node.operator = op
	_connect(Ref2.new(a_id, 0), a_idx, id, 0)
	_connect(Ref2.new(b_id, 0), b_idx, id, 1)
	return Ref2.new(id, 0)


func _emit_tiledimage(el: MtlxDocument.MtlxElement) -> Ref2:
	return _emit_image(el)


# ---------------------------------------------------------------------------
# Graph plumbing
# ---------------------------------------------------------------------------


func _emit_input_or_null(inp: MtlxDocument.MtlxInput, graph: String) -> Ref2:
	if inp == null:
		return Ref2.new()
	return _emit_input_as(inp, graph, _any)


func _neutral_for(type: String) -> Variant:
	match type:
		"vector2":
			return Vector2.ZERO
		"vector3", "color3":
			return Vector3.ZERO
		"vector4", "color4":
			return Vector4.ZERO
	return 0.0


func _add(node: VisualShaderNode) -> int:
	var id: int = _next_id
	_shader.add_node(_stage, node, Vector2.ZERO, id)
	_node_stage[id] = _stage
	_next_id += 1
	return id


## Adds a node to the light stage regardless of _stage. Kept as a name because
## the custom-lighting call sites read better with it.
func _add_light(node: VisualShaderNode) -> int:
	var prev := _stage
	_stage = LIGHT
	var id: int = _add(node)
	_stage = prev
	return id


func _node(id: int) -> VisualShaderNode:
	return _shader.get_node(int(_node_stage.get(id, FRAGMENT)), id)


## Wires `from`'s output into `to_node`'s input `to_port`.
##
## All four endpoints are explicit on purpose: an earlier version folded the
## destination node into a default of 0 (the output node), which made
## "_connect(ref, 0, port)" ambiguous with "_connect(ref, 0, node, port)" and
## silently wired operands into the shader output.
func _connect(from: Ref2, from_port: int, to_node: int, to_port: int) -> void:
	var stage: int = int(_node_stage.get(from.node, FRAGMENT))
	_shader.connect_nodes_forced(stage, from.node, from_port, to_node, to_port)



## True when a subsurface input is driven away from its default.
##
## subsurface is a float; subsurface_scale and subsurface_color are vectors.
## is_default() compares like with like, so the declared type is picked up from
## the input rather than guessed.
func _drives(surface: MtlxDocument.MtlxElement, name: String) -> bool:
	var inp: MtlxDocument.MtlxInput = surface.input(name)
	if inp == null:
		return false
	if inp.is_link():
		return true
	var value: Variant = inp.typed_value()
	if value == null:
		return false
	if inp.type == "float":
		return not GodotMap.is_default(name, float(value))
	return not GodotMap.is_default(name, GodotMap._as_vector3(value))


## Connects within the light stage. Kept for readability at the call sites that
## wire the light node's outputs; the stage now comes from the from-node itself.
func _connect_light(from: Ref2, from_port: int, to_node: int, to_port: int) -> void:
	_connect(from, from_port, to_node, to_port)


## Wires into the implicit output node, whose ports are the ALBEDO/METALLIC/...
## indices in GodotMap.
func _connect_output(from: Ref2, out_port: int) -> void:
	_connect(from, from.port, OUTPUT_NODE, out_port)


## Lays the graph out left to right so it is readable in the editor. Purely
## cosmetic, but a graph with every node at the origin is unusable.
func _apply_layout() -> void:
	var by_depth: Dictionary = {}
	for id in _shader.get_node_list(FRAGMENT):
		by_depth[_depth_of(id)] = true

	var depth_x: Dictionary = {}
	for id in _shader.get_node_list(FRAGMENT):
		var d: int = _depth_of(id)
		if not depth_x.has(d):
			depth_x[d] = Vector2(float(d) * 220.0 - 1400.0, 0.0)

	# Second pass: stack nodes that share a depth.
	var per_depth: Dictionary = {}
	for id in _shader.get_node_list(FRAGMENT):
		var d: int = _depth_of(id)
		var n: int = per_depth.get(d, 0)
		per_depth[d] = n + 1
		var base: Vector2 = depth_x[d]
		_shader.set_node_position(FRAGMENT, id, base + Vector2(0.0, float(n) * 190.0 - float(per_depth[d] - 1) * 95.0))


## Longest distance from the graph's outputs, so inputs sit on the left.
func _depth_of(id: int) -> int:
	var memo: Dictionary = {}
	return _depth_rec(id, memo, {})


func _depth_rec(id: int, memo: Dictionary, visiting: Dictionary) -> int:
	if memo.has(id):
		return memo[id]
	if visiting.has(id):
		return 0
	visiting[id] = true

	var best: int = 0
	for c in _shader.get_node_connections(FRAGMENT):
		var d: Dictionary = c
		if int(d["to_node"]) == id:
			var up: int = _depth_rec(int(d["from_node"]), memo, visiting) + 1
			best = maxi(best, up)
	memo[id] = best
	return best


## Finds the res:// path for a texture referenced by a .mtlx.
##
## MaterialX paths are case-sensitive, but these files are not always correct
## about it -- Wood_Beech_Raw.mtlx asks for "Wood_Beech_Raw_Mask.png" while the
## file on disk is "Wood_Beech_Raw_mask.png". That resolves on Windows and
## macOS and fails on Linux, so an exact miss falls back to a case-insensitive
## search.
##
## Static and shared with MtlxFormatLoader so the dependencies Godot is told
## about are exactly the files the shader ends up using. If the two resolved
## paths differently the editor would reload on the wrong edits.
static func resolve_texture(rel: String, base_dir: String, texture_roots: PackedStringArray) -> String:
	var candidates: PackedStringArray = PackedStringArray()
	if rel.begins_with("res://"):
		candidates.append(rel)
	else:
		for root in texture_roots:
			candidates.append(root.path_join(rel))
		candidates.append(base_dir.path_join(rel))

	for c in candidates:
		if ResourceLoader.exists(c):
			return c

	# No exact match; look for a case-only difference.
	for c in candidates:
		var actual: String = find_ignoring_case(c)
		if actual != "":
			return actual
	return ""


## Looks in the directory the path names for a case-insensitive match on the
## file name.
static func find_ignoring_case(res_path: String) -> String:
	var dir: String = res_path.get_base_dir()
	var want: String = res_path.get_file().to_lower()
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return ""
	for f in d.get_files():
		if f.to_lower() == want:
			return dir.path_join(f)
	return ""


func _resolve_texture(rel: String) -> String:
	var actual: String = resolve_texture(rel, _base_dir, _texture_roots)
	# A different file name means the case had to be bent to find it.
	if actual != "" and actual.get_file() != rel.get_file():
		_notes.append("texture case differs: '%s' resolved to '%s'" % [rel, actual.get_file()])
	return actual


func _to_vec3(v: Variant) -> Vector3:
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


func _to_vec4(v: Variant) -> Vector4:
	if v is Vector4:
		return v
	if v is Vector3:
		var a: Vector3 = v
		return Vector4(a.x, a.y, a.z, 1.0)
	if v is Color:
		var c: Color = v
		return Vector4(c.r, c.g, c.b, c.a)
	if v is float or v is int:
		var f: float = float(v)
		return Vector4(f, f, f, f)
	return Vector4.ZERO


func _to_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Vector3:
		var a: Vector3 = v
		return Vector2(a.x, a.y)
	if v is float or v is int:
		var f: float = float(v)
		return Vector2(f, f)
	return Vector2.ZERO



## True when a lobe's enabling input is driven above zero.
##
## For the float lobes (coat, sheen, subsurface) that is a literal or link above
## zero. A link counts as enabled: its value is not knowable here, and guessing
## zero would silently drop a lobe that is in use.
func _enabled(surface: MtlxDocument.MtlxElement, name: String) -> bool:
	var inp: MtlxDocument.MtlxInput = surface.input(name)
	if inp == null:
		return false
	if not inp.is_link():
		var value: Variant = inp.typed_value()
		return value != null and absf(float(value)) > 1e-4

	# A link is followed to whatever drives it. Most of these are links to a
	# constant, and treating every link as "enabled" refused the entire
	# library -- Aluminum.mtlx is a plain metal whose specular_anisotropy just
	# happens to come through a node.
	var src: MtlxDocument.MtlxElement = _doc.source_element(inp, surface.graph)
	if src != null and src.def == "constant":
		var v: Variant = src.input_value("value")
		return v != null and absf(float(v)) > 1e-4

	# Driven from something whose value is not knowable here -- a texture, or a
	# chain we do not resolve. Refused, because guessing would silently drop a
	# lobe.
	return true

