extends SceneTree

## Explains why the custom-lighting gate refuses each material in the corpus.
##
## The gate refuses any material where _enabled() returns true for coat, sheen,
## subsurface, specular_anisotropy or specular_rotation. _enabled() refuses a
## link it cannot trace to a <constant>, so the interesting question is which
## input refuses, and what the driver actually turned out to be.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const Doc := preload("res://addons/materialx/mtlx_document.gd")

const DIR := "res://materials"
const GATE_INPUTS := [
	"coat", "sheen", "subsurface", "specular_anisotropy", "specular_rotation",
]

## input name -> how many materials refused because of it.
var _blame := {}
## The concrete driver that caused a refusal, as "def:type".
var _drivers := {}
var _unresolved := 0
var _refused := 0
var _total := 0
var _qualifying := 0


func _init() -> void:
	var files := _list(DIR)
	print("probing gate over %d file(s)\n" % files.size())

	for path in files:
		_total += 1
		var doc: Doc = Doc.load_from_file(path)
		if doc == null or doc.materials.is_empty():
			continue
		var surface: Doc.MtlxElement = doc.find_surface(doc.materials[0])
		if surface == null:
			continue
		_doc = doc

		# Same enabling test the gate applies, in the gate's own order.
		if not _worth_it(surface):
			continue
		_qualifying += 1

		var blocker := _first_blocker(surface)
		if blocker == "":
			_qualifying -= 1
			_refused += 0
			continue
		_refused += 1
		_blame[blocker] = int(_blame.get(blocker, 0)) + 1

	print("materials reaching the lobe check : %d" % (_total - (_total - _refused - _qualifying)))
	print("refused by a lobe the node lacks  : %d" % _refused)
	print("accepted by the lobe check        : %d" % _qualifying)

	print("\n=== which input refuses, and what drives it ===")
	for k in _blame.keys():
		print("  %-22s %d" % [k, _blame[k]])

	print("\n=== distinct drivers, by 'def:type' ===")
	var keys := _drivers.keys()
	keys.sort_custom(func(a, b): return int(_drivers[a]) > int(_drivers[b]))
	for k in keys:
		print("  %-46s %d" % [k, _drivers[k]])
	if _unresolved > 0:
		print("\n  (%d link(s) did not resolve to any element at all)" % _unresolved)

	quit(0)


## Mirrors _try_custom_lighting's first test: is diffuse_roughness worth a
## custom lobe at all?
func _worth_it(surface: Doc.MtlxElement) -> bool:
	var inp: Doc.MtlxInput = surface.input("diffuse_roughness")
	if inp == null:
		return false
	if not inp.is_link():
		var v: Variant = inp.typed_value()
		return v != null and not GodotMap.is_default("diffuse_roughness", float(v))
	return true


## The first input, in gate order, that _enabled() refuses. Empty when none do.
func _first_blocker(surface: Doc.MtlxElement) -> String:
	for name in GATE_INPUTS:
		var inp: Doc.MtlxInput = surface.input(name)
		if inp == null:
			continue
		if not inp.is_link():
			var v: Variant = inp.typed_value()
			if v != null and absf(float(v)) > 1e-4:
				_record(name, "literal=%s" % str(v))
				return name
			continue
		var src: Doc.MtlxElement = _doc.source_element(inp, surface.graph)
		if src != null and src.def == "constant":
			var v: Variant = src.input_value("value")
			if v != null and absf(float(v)) > 1e-4:
				_record(name, "constant=%s" % str(v))
				return name
			continue
		# Refused. Classify the driver for the aggregate below.
		if src == null:
			_unresolved += 1
			_record(name, "UNRESOLVED nodename=%s nodegraph=%s output=%s" % [
				inp.nodename, inp.nodegraph, inp.output])
		else:
			_record(name, "%s:%s" % [src.def, src.type])
		return name
	return ""


var _doc: Doc



func _record(input_name: String, driver: String) -> void:
	# Attribute the driver to the input that refused, so the report reads.
	var key := "%-22s %s" % [input_name, driver]
	_drivers[key] = int(_drivers.get(key, 0)) + 1


func _list(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".mtlx"):
			out.append(dir_path.path_join(f))
	return out
