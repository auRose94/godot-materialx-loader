@tool
class_name MtlxDocument
extends RefCounted

## A parsed MaterialX document.
##
## MaterialX is XML, but the interesting structure is the graph: elements
## (nodes) live either at document scope or inside a <nodegraph>, and inputs
## point at other elements either by bare `nodename` (same scope) or by
## `nodegraph` + `output` (crossing into a subgraph's output). Resolution is
## therefore scoped, and both scopes are kept here.
##
## This deliberately parses only the subset the loader needs. It does not
## validate against the MaterialX spec; a full validator is what linking
## libMaterialX would buy you.

## One <input> on an element.
class MtlxInput extends RefCounted:
	var name: String = ""
	var type: String = ""
	## Raw `value` attribute, still a String. Use typed_value() to decode.
	var value: String = ""
	## Set when this input is driven by another element instead of a literal.
	var nodename: String = ""
	var nodegraph: String = ""
	var output: String = ""
	var channels: String = ""
	var colorspace: String = ""
	var interstage: bool = false

	## True when this input is a link rather than a literal.
	func is_link() -> bool:
		return nodename != "" or (nodegraph != "" and output != "")

	## Typed literal, or null when this input is a link or unparseable.
	func typed_value() -> Variant:
		if is_link():
			return null
		return MtlxValue.parse(type, value)

	## Normalised: MaterialX spells sRGB as "srgb_texture" or "srgb", and uses
	## the empty string (or "lin_rec709"-style names) for data.
	func is_srgb() -> bool:
		return colorspace == "srgb_texture" or colorspace == "srgb"

## One element: <constant>, <image>, <mix>, <standard_surface>, ...
class MtlxElement extends RefCounted:
	var name: String = ""
	## The tag, e.g. "image", "multiply", "standard_surface".
	var def: String = ""
	## The `type` attribute (a MaterialX *data* type, not a node type).
	var type: String = ""
	## Elements declared inside this one (nodegraph contents).
	var children: Array[MtlxElement] = []
	var inputs: Dictionary = {}  # String -> MtlxInput
	## The <nodegraph> this element belongs to; "" for document scope.
	var graph: String = ""

	## True for an <output> element, which is a pass-through, not a real node.
	func is_output() -> bool:
		return def == "output"

	func input(p_name: String) -> MtlxInput:
		return inputs.get(p_name, null)

	func input_value(p_name: String, fallback: Variant = null) -> Variant:
		var inp: MtlxInput = inputs.get(p_name, null)
		if inp == null:
			return fallback
		var v: Variant = inp.typed_value()
		return fallback if v == null else v

	## Every input, sorted by name, so emission is deterministic.
	func sorted_inputs() -> Array:
		var keys: Array = inputs.keys()
		keys.sort()
		return keys.map(func(k): return inputs[k])


var version: String = ""
## Top-level elements, in document order.
var roots: Array[MtlxElement] = []
## Every element, document scope and nested.
var elements: Array[MtlxElement] = []
## The <surfacematerial> nodes: what this file actually exports.
var materials: Array[MtlxElement] = []
## Non-fatal problems, surfaced to the user instead of failing the import.
var warnings: PackedStringArray = []


## Looks up an element by name, preferring `p_graph` scope then document
## scope. Returns null when nothing matches.
func resolve(p_name: String, p_graph: String) -> MtlxElement:
	if p_name == "":
		return null
	if p_graph != "":
		for e in elements:
			if e.graph == p_graph and e.name == p_name:
				return e
	for e in elements:
		if e.graph == "" and e.name == p_name:
			return e
	# Last resort: any scope. MaterialX files in the wild rely on this.
	for e in elements:
		if e.name == p_name:
			return e
	return null


## Follows an input to the element that drives it.
##
## Handles both link forms: `nodename` within the same scope, and
## `nodegraph`+`output` crossing into a subgraph (where the named element is
## an <output> that itself points at a real node). Returns null for literals.
func source_element(inp: MtlxInput, from_graph: String) -> MtlxElement:
	if inp == null or not inp.is_link():
		return null
	if inp.nodename != "":
		return resolve(inp.nodename, from_graph)
	var outs: MtlxElement = resolve(inp.output, inp.nodegraph)
	if outs == null:
		warnings.append("missing output '%s' in nodegraph '%s'" % [inp.output, inp.nodegraph])
		return null
	if not outs.is_output():
		# Tolerate files that name a node where an output was expected.
		return outs
	var up: MtlxInput = outs.input("nodename")
	if up == null:
		return null
	return resolve(up.value, inp.nodegraph)


## The type an input actually produces, following links to the driving node.
## Used to pick between scalar/vector/colour Godot nodes.
func effective_type(inp: MtlxInput, from_graph: String) -> String:
	if inp == null:
		return ""
	if inp.is_link():
		var src: MtlxElement = source_element(inp, from_graph)
		if src != null and src.type != "":
			return src.type
	return inp.type


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


## Parses a file. Returns null when the file is missing or not usable.
static func load_from_file(path: String) -> MtlxDocument:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	return parse_text(text)


static func parse_text(text: String) -> MtlxDocument:
	var doc := MtlxDocument.new()

	var parser := XMLParser.new()
	if parser.open_buffer(text.to_utf8_buffer()) != OK:
		doc.warnings.append("could not parse XML")
		return doc

	# Open elements, innermost last. An <input> never has children, so it is
	# attached without being pushed.
	var stack: Array[MtlxElement] = []

	# XMLParser.read() is the node-at-a-time cursor; seek() wants an absolute
	# offset, so the loop is driven by read() and `continue` still advances.
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var tag: String = parser.get_node_name()
				var parent: MtlxElement = stack[stack.size() - 1] if stack.size() > 0 else null

				if tag == "input":
					if parent != null:
						parent.inputs[_attr(parser, "name")] = _make_input(parser)
					continue

				if tag == "materialx":
					doc.version = _attr(parser, "version")
					continue

				var el := MtlxElement.new()
				el.name = _attr(parser, "name")
				el.def = tag
				el.type = _attr(parser, "type")
				# A node inside a <nodegraph> belongs to that graph's scope.
				el.graph = parent.name if parent != null and parent.def == "nodegraph" else ""

				if el.is_output():
					# An <output>'s upstream link is an attribute, not a child
					# <input>. Normalising it here means everything downstream
					# can treat outputs like any other input-bearing element.
					var up: String = _attr(parser, "nodename")
					if up != "":
						var link := MtlxInput.new()
						link.name = "nodename"
						link.type = el.type
						link.value = up
						el.inputs["nodename"] = link

				doc._attach(parent, el)
				stack.append(el)

			XMLParser.NODE_ELEMENT_END:
				if stack.size() > 0:
					stack.pop_back()

	return doc


## XMLParser takes attribute *indexes*, not names, so this looks the name up.
static func _attr(parser: XMLParser, p_name: String) -> String:
	for i in parser.get_attribute_count():
		if parser.get_attribute_name(i) == p_name:
			return parser.get_attribute_value(i)
	return ""


static func _make_input(parser: XMLParser) -> MtlxInput:
	var inp := MtlxInput.new()
	inp.name = _attr(parser, "name")
	inp.type = _attr(parser, "type")
	inp.value = _attr(parser, "value")
	inp.nodename = _attr(parser, "nodename")
	inp.nodegraph = _attr(parser, "nodegraph")
	inp.output = _attr(parser, "output")
	inp.channels = _attr(parser, "channels")
	inp.colorspace = _attr(parser, "colorspace")
	inp.interstage = _attr(parser, "interstage") == "true"
	return inp


func _attach(parent: MtlxElement, el: MtlxElement) -> void:
	elements.append(el)
	if parent != null:
		parent.children.append(el)
	else:
		roots.append(el)
	if el.def == "surfacematerial":
		materials.append(el)


## The standard_surface (or pbrsurface) behind a <surfacematerial>, following
## its `surfaceshader` input. Returns null when there is not exactly one.
func find_surface(material: MtlxElement) -> MtlxElement:
	var inp: MtlxInput = material.input("surfaceshader")
	if inp == null:
		return null
	if inp.is_link():
		var src: MtlxElement = source_element(inp, material.graph)
		if src != null and src.def != "surfacematerial":
			return src
		return null
	# A literal only happens in malformed files; treat the sole surface as it.
	if elements.size() == 1:
		return elements[0]
	return null


## Every <nodegraph> element, for callers that need to walk one directly.
func nodegraphs() -> Array[MtlxElement]:
	var out: Array[MtlxElement] = []
	for e in roots:
		if e.def == "nodegraph":
			out.append(e)
	return out