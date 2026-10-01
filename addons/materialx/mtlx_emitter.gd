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
var _cache: Dictionary = {}  # MtlxElement -> Ref2
var _notes: PackedStringArray = []
var _dropped: Dictionary = {}
var _missing_textures: PackedStringArray = []
## Resource directory the .mtlx lives in, for resolving relative file paths.
var _base_dir: String = "res://"
## Where textures are found, tried in order.
var _texture_roots: PackedStringArray = []


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
	_fold_into_output(surface, ["base", "base_color"], GodotMap.OUT_ALBEDO, Vector3.ONE, "base")
	_fold_into_output(surface, ["emission", "emission_color"], GodotMap.OUT_EMISSION, Vector3.ZERO, "emission")
	_fold_specular(surface)
	_fold_anisotropy_flow(surface)
	# Refraction claims `transmission` when it is enabled, so _fold_opacity
	# must be told whether it is still responsible for it.
	var refracted: bool = _try_screen_refraction(surface)
	_fold_opacity(surface, not refracted)
	_fold_sheen_color(surface)
	_fold_subsurface(surface)
	_try_custom_lighting(surface)

	# Inputs handled by the folds above rather than by the direct port loop.
	const FOLDED_INPUTS := [
		"base", "base_color", "emission", "emission_color",
		"specular", "specular_IOR", "specular_color",
		"specular_rotation", "opacity", "transmission", "sheen_color",
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
		_connect_output(src, port)

	# Report only the unmapped inputs the file actually asked for. Anything
	# left at its standard_surface default costs nothing visually, so listing
	# it would bury the real losses in noise.
	for key in surface.inputs.keys():
		var name: String = key
		if GodotMap.SURFACE_PORTS.has(name):
			continue
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


func _fold_into_output(surface: MtlxDocument.MtlxElement, names: Array, out_port: int, neutral: Vector3, param_base: String) -> void:
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

	if not wired:
		# Nothing but the neutral value; drop the node.
		_shader.remove_node(FRAGMENT, mul_id)
		_next_id -= 1
		return
	_connect_output(Ref2.new(mul_id, 0), out_port)


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

	var col_scale: float = _specular_color_scale(col_in)
	var f0: Variant = _specular_f0_chain(ior_in, spec_in, col_scale)

	# All-literal: the whole chain is a constant, so emit it as one adjustable
	# parameter rather than a cloud of arithmetic nodes.
	if f0 is float or f0 is int:
		var pid: int = _add(VisualShaderNodeFloatParameter.new())
		var p: VisualShaderNodeFloatParameter = _node(pid)
		p.parameter_name = "specular"
		p.default_value_enabled = true
		p.default_value = sqrt(maxf(float(f0), 0.0) / GodotMap.GODOT_DIELECTRIC_SCALE)
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
## The result goes to EMISSION rather than ALPHA. That keeps the material in the
## opaque pass, which matters: a material that reads the screen counts as
## alpha-bearing to the renderer (scene_shader_forward_clustered.cpp:255) and
## then only casts shadows with a depth prepass. Writing ALPHA instead would
## walk straight into that, and into the sorting problems of a blended shell.
##
## Two approximations, both deliberate and both documented:
##
## * The refracted vector is in view space, and SCREEN_UV is in screen space.
##   Only the xy of the refracted direction is used, scaled by a parameter, which
##   drifts at grazing angles. A true projection needs the screen-space normal and
##   the viewport scale, which are not reachable as a single node value.
## * The sample is not masked against the depth buffer, so near a silhouette it
##   can pull in background from behind the object. SOURCE_DEPTH would fix that
##   at the cost of a second sampler and a wider node graph.
func _try_screen_refraction(surface: MtlxDocument.MtlxElement) -> bool:
	if not Config.screen_space_refraction():
		return false

	var transmission: Ref2 = _transmission_ref(surface)
	if not transmission.is_valid():
		return false

	# Godot refracts about N with the incident vector pointing into the surface,
	# which is the negated view vector.
	var normal: int = _add_input("Normal")
	var view: int = _add_input("View")

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

	# offset = refract_dir.xy * refraction_strength, exposed so the strength can be
	# tuned per material without rebuilding.
	var strength := VisualShaderNodeFloatParameter.new()
	strength.parameter_name = _safe_param_name("refraction_strength")
	strength.default_value_enabled = true
	strength.default_value = REFRACTION_STRENGTH
	var strength_id: int = _add(strength)

	# SCREEN_UV is a vec2, so the refracted direction is truncated to its xy by
	# running the VectorOp in 2D mode. A VectorCompose node would be the obvious
	# choice and is wrong: it takes one vector and splits it into components, not
	# the other way round.
	var xy := VisualShaderNodeVectorOp.new()
	xy.set("operator", GodotMap.VOP_ADD)
	xy.set("op_type", VisualShaderNodeVectorOp.OP_TYPE_VECTOR_2D)
	var xy_id: int = _add(xy)
	_connect(Ref2.new(refr_id, 0), 0, xy_id, 0)
	xy.set_default_input_values([1, Vector2.ZERO])

	var scaled := VisualShaderNodeVectorOp.new()
	scaled.set("operator", GodotMap.VOP_MUL)
	scaled.set("op_type", VisualShaderNodeVectorOp.OP_TYPE_VECTOR_2D)
	var scaled_id: int = _add(scaled)
	_connect(Ref2.new(xy_id, 0), 0, scaled_id, 0)
	_connect(Ref2.new(strength_id, 0), 0, scaled_id, 1)

	var screen_uv := _add_input("ScreenUV")
	var offset := VisualShaderNodeVectorOp.new()
	offset.set("operator", GodotMap.VOP_ADD)
	offset.set("op_type", VisualShaderNodeVectorOp.OP_TYPE_VECTOR_2D)
	var offset_id: int = _add(offset)
	_connect(Ref2.new(screen_uv, 0), 0, offset_id, 0)
	_connect(Ref2.new(scaled_id, 0), 0, offset_id, 1)

	var screen := VisualShaderNodeTexture.new()
	screen.source = VisualShaderNodeTexture.SOURCE_SCREEN
	var screen_id: int = _add(screen)
	_connect(Ref2.new(offset_id, 0), 0, screen_id, 0)

	# EMISSION = sampled.rgb * transmission, optionally tinted by transmission_color.
	var gain: Ref2 = transmission
	var tint: MtlxDocument.MtlxInput = surface.input("transmission_color")
	if tint != null:
		var tint_ref: Ref2 = _emit_input(tint, surface.graph)
		if tint_ref.is_valid():
			gain = _vop(GodotMap.VOP_MUL, gain, tint_ref)
	# The screen sample is a vec4 and the gain a scalar or colour, so the
	# multiply stays in 3D mode: Godot coerces the alpha away with it.
	var lit: Ref2 = _vop(GodotMap.VOP_MUL, Ref2.new(screen_id, 0), gain)

	_connect_output(lit, GodotMap.OUT_EMISSION)

	_notes.append(
		"transmission rendered as screen-space refraction; the surface stays "
		+ "opaque and samples what is behind it")
	return true


## Default strength of the screen-space offset, in SCREEN_UV units. Small on
## purpose: it is a displacement of the background sample, not a lens.
const REFRACTION_STRENGTH := 0.02


## Adds a fragment-stage input node reading one of the shader's built-ins.
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
## diffuse_roughness.
##
## Writing anything to the light stage sets LIGHT_CODE_USED, which makes Godot
## skip its entire lighting model (scene_forward_lights_inc.glsl:121). That is why
## this is gated so narrowly -- it is only worth doing for a material that has
## diffuse_roughness set and nothing this cannot reproduce.
##
## Returns true when the material was taken over. Callers use that to stop
## reporting diffuse_roughness as dropped.
func _try_custom_lighting(surface: MtlxDocument.MtlxElement) -> bool:
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

	# Anything whose lobes this node cannot reproduce. Clearcoat, rim and
	# anisotropy are not readable from a light function at all -- the built-in
	# list in shader_types.cpp does not contain them. Taking such a material
	# would silently drop those lobes.
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
	for enabling in ["coat", "sheen"]:
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

	# The light node's two outputs go to the light stage's own output ports:
	# DIFFUSE_LIGHT = 0, SPECULAR_LIGHT = 1.
	_connect_light(Ref2.new(light_id, 0), 0, OUTPUT_NODE, 0)
	# from_port is passed explicitly and overrides the Ref2, so this must be 1 and
	# not 0 -- otherwise SPECULAR_LIGHT receives the diffuse value and the
	# specular lobe is lost.
	_connect_light(Ref2.new(light_id, 1), 1, OUTPUT_NODE, 1)

	_notes.append(
		"diffuse_roughness evaluated with an Oren-Nayar lobe; this replaces "
		+ "Godot's lighting for this material")
	return true


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
func _fop(op: int, a: Variant, b: Variant) -> Ref2:
	var id: int = _add(VisualShaderNodeFloatOp.new())
	var node: VisualShaderNodeFloatOp = _node(id)
	node.operator = op
	var defaults: Array = []
	if a is float or a is int:
		defaults += [0, float(a)]
	else:
		_connect(_as_ref(a), 0, id, 0)
	if b is float or b is int:
		defaults += [1, float(b)]
	else:
		_connect(_as_ref(b), 0, id, 1)
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
]


## A parameter name that will not collide with Godot's generated locals.
func _safe_param_name(name: String) -> String:
	if RESERVED_PARAM_NAMES.has(name):
		return name + "_mx"
	return name


func _parameter_for(type: String, name: String, value: Variant) -> VisualShaderNode:
	var safe := _safe_param_name(name)
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
	if el in _cache:
		return _cache[el]

	var ref: Ref2 = _emit_uncached(el)
	_cache[el] = ref
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
	_shader.add_node(FRAGMENT, node, Vector2.ZERO, id)
	_next_id += 1
	return id


## Adds a node to the light stage. Node ids are shared across stages, so the same
## counter is safe.
func _add_light(node: VisualShaderNode) -> int:
	var id: int = _next_id
	_shader.add_node(LIGHT, node, Vector2.ZERO, id)
	_next_id += 1
	return id


func _node(id: int) -> VisualShaderNode:
	return _shader.get_node(FRAGMENT, id)


## Wires `from`'s output into `to_node`'s input `to_port`.
##
## All four endpoints are explicit on purpose: an earlier version folded the
## destination node into a default of 0 (the output node), which made
## "_connect(ref, 0, port)" ambiguous with "_connect(ref, 0, node, port)" and
## silently wired operands into the shader output.
func _connect(from: Ref2, from_port: int, to_node: int, to_port: int) -> void:
	_shader.connect_nodes_forced(FRAGMENT, from.node, from_port, to_node, to_port)



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


## Connects within the light stage.
func _connect_light(from: Ref2, from_port: int, to_node: int, to_port: int) -> void:
	_shader.connect_nodes_forced(LIGHT, from.node, from_port, to_node, to_port)


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

