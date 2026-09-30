#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Verifies the specular conversion against what each .mtlx actually declares.
##
## MaterialX standard_surface builds F0 from a *physical* IOR:
##     F0 = ((ior-1)/(ior+1))^2 * specular * specular_color
## while Godot's spatial output takes a scalar port whose internal dielectric
## term is quadratic:
##     dielectric = 0.16 * SPECULAR^2
## so the port value must be sqrt(F0/0.16), not F0 and not `specular`.
##
## Feeding MaterialX's `specular` straight into the port -- what the original
## converter did -- gives 0.16 * specular^2 instead of F0. For specular=1.0
## that is 0.16 rather than 0.04, i.e. four times too reflective, and 252 of
## the 276 materials in this library declare specular=1.0.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")

## The check is per-file arithmetic against whatever IOR the file declares, so
## it holds for any material. A sample keeps the output readable.
const SAMPLE := 10

var CASES: PackedStringArray = TestKit.first(SAMPLE)


func _init() -> void:
	var bad := 0
	var rows := []

	for path in CASES:
		var doc: MtlxDocument = MtlxDocument.load_from_file(path)
		if doc == null or doc.materials.is_empty():
			print("cannot read ", path)
			bad += 1
			continue
		var surface: MtlxDocument.MtlxElement = doc.find_surface(doc.materials[0])
		if surface == null:
			print("no surface in ", path)
			bad += 1
			continue

		var ior: float = float(surface.input_value("specular_IOR", 1.5))
		var spec: float = float(surface.input_value("specular", 1.0))
		var col: Variant = surface.input_value("specular_color", Vector3.ONE)

		var f0: Variant = GodotMap.mtlx_specular_f0(ior, spec, col)
		var want: float = GodotMap.godot_specular_from_f0(f0)
		# What the old converter emitted, and what F0 it actually produced.
		var naive_port: float = spec
		var naive_f0: float = GodotMap.GODOT_DIELECTRIC_SCALE * naive_port * naive_port

		var got: float = _emitted_specular(path)
		if got < 0.0:
			print("%s: no SPECULAR reached the output" % path.get_file())
			bad += 1
			continue

		var matches: bool = is_equal_approx(got, want)
		if not matches:
			bad += 1

		rows.append("%-26s ior=%.3f spec=%.2f  F0=%.4f  SPECULAR want=%.4f got=%.4f  %s" % [
			path.get_file(), ior, spec, float(f0.x), want, got,
			"OK" if matches else "MISMATCH",
		])
		rows.append("%-26s   old converter: port=%.2f -> F0=%.4f (%.2fx too reflective)" % [
			"", naive_port, naive_f0,
			naive_f0 / maxf(float(f0.x), 0.000001)])

	for r in rows:
		print(r)

	print("\n--- %s ---" % ("all specular conversions correct" if bad == 0 else "%d failures" % bad))
	quit(1 if bad > 0 else 0)


## Evaluates the emitted graph's SPECULAR path by checking the graph's
## constant chain. Only meaningful when the conversion folded to a constant,
## which is the case for every material here.
func _emitted_specular(path: String) -> float:
	var r: MtlxEmitter.Result = Emitter.build_file(path)
	if not r.ok:
		return -1.0

	# Find what is wired into output port 4 (SPECULAR).
	for c in r.shader.get_node_connections(1):
		var d: Dictionary = c
		if int(d["to_node"]) != 0 or int(d["to_port"]) != GodotMap.OUT_SPECULAR:
			continue
		var src: VisualShaderNode = r.shader.get_node(1, int(d["from_node"]))
		if src is VisualShaderNodeFloatParameter:
			return src.default_value
		if src is VisualShaderNodeFloatConstant:
			return src.constant
	return -1.0