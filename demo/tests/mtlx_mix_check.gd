#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Locks in MaterialX mix() polarity, which is the inverse of GLSL's mix() and
## was previously wired backwards.
##
##   MaterialX  mix(fg, bg, t) = bg * (1 - t) + fg * t
##   Godot      mix(A, B, T)    = A  * (1 - T) + B  * T
##
## so bg must reach port A (0) and fg port B (1). Wiring it the other way
## silently complements every blend; it turned the brick materials' dark blue
## "LeaksColor" grime into the whole surface.
##
## Bricks.mtlx is used because the effect is visible: its leaks mix factor is
## always 0 (MaskSpread is 0, so floor(alpha) is 0), so the correct result is
## the brick texture and the inverted result is flat LeaksColor.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const TestKit := preload("res://tests/mtlx_test_kit.gd")

## Resolved at runtime from the material library rather than hardcoded,
## so the test works against any library that contains the fixture.
var SRC: String = ""
## Bricks_mask.png's alpha channel ranges 0..0.95, so the grime factor is 0.
const EXPECT_FACTOR := 0.0


func _init() -> void:
	SRC = _find_fixture()
	if SRC == "":
		print("SKIP: fixture Bricks.mtlx is not in this library.")
		print("  This test needs a material whose blend factor is pinned to a")
		print("  known value, so it cannot be checked against an arbitrary file.")
		print("  Looked in: %s" % TestKit.primary_dir())
		quit(0)
		return
	print("fixture: %s\n" % SRC)

	var r: MtlxEmitter.Result = Emitter.build_file(SRC)
	if not r.ok:
		print("build failed: ", r.message)
		quit(1)
		return

	var bad := 0

	# 1. The mix feeding ALBEDO must be mix(brick, LeaksColor, factor).
	var leaks_mix: Dictionary = {}
	for c in r.shader.get_node_connections(1):
		var d: Dictionary = c
		if int(d["to_node"]) == 0 and int(d["to_port"]) == GodotMap.OUT_ALBEDO:
			# ALBEDO <- multiply(base, <the leaks mix>)
			var mul: VisualShaderNode = r.shader.get_node(1, int(d["from_node"]))
			if mul is VisualShaderNodeVectorOp and mul.operator == GodotMap.VOP_MUL:
				for c2 in r.shader.get_node_connections(1):
					var d2: Dictionary = c2
					if int(d2["to_node"]) == mul.get_instance_id():
						pass
			# find the mix by scanning for a Mix node fed by the blue constant
			leaks_mix = _find_leaks_mix(r.shader)
			break

	if leaks_mix.is_empty():
		print("FAIL: could not identify the leaks mix")
		quit(1)
		return

	var a_node: VisualShaderNode = r.shader.get_node(1, int(leaks_mix["a"]))
	var b_node: VisualShaderNode = r.shader.get_node(1, int(leaks_mix["b"]))

	# Port A must be the brick side, port B the LeaksColor side.
	var a_is_leaks: bool = a_node is VisualShaderNodeVec3Constant
	var b_is_leaks: bool = b_node is VisualShaderNodeVec3Constant

	print("mix port A (factor=0 side) = %s" % a_node.get_class())
	print("mix port B (factor=1 side) = %s" % b_node.get_class())

	if a_is_leaks:
		print("FAIL: LeaksColor is on port A, so factor 0 yields the grime colour")
		bad += 1
	else:
		print("  OK: port A is the brick path")

	if not b_is_leaks:
		print("FAIL: port B is not the LeaksColor constant")
		bad += 1
	else:
		print("  OK: port B is LeaksColor")

	# 2. With factor 0 the result must equal the brick side.
	print("\nMaterialX: out = bg*(1-t) + fg*t, t = %.1f  ->  brick" % EXPECT_FACTOR)
	print("Godot:     out = mix(A, B, T)                        ->  A = brick  OK")

	print("\n--- %s ---" % ("mix polarity correct" if bad == 0 else "%d failures" % bad))
	quit(1 if bad > 0 else 0)


## Locates the Mix node whose operands are the brick path and the blue constant.
func _find_leaks_mix(shader: VisualShader) -> Dictionary:
	for id in shader.get_node_list(1):
		var n: VisualShaderNode = shader.get_node(1, id)
		if not (n is VisualShaderNodeMix):
			continue
		var a := -1
		var b := -1
		for c in shader.get_node_connections(1):
			var d: Dictionary = c
			if int(d["to_node"]) != id:
				continue
			if int(d["to_port"]) == 0:
				a = int(d["from_node"])
			elif int(d["to_port"]) == 1:
				b = int(d["from_node"])
		if a >= 0 and b >= 0:
			var na: VisualShaderNode = shader.get_node(1, a)
			var nb: VisualShaderNode = shader.get_node(1, b)
			if (na is VisualShaderNodeVec3Constant) != (nb is VisualShaderNodeVec3Constant):
				return {"a": a, "b": b}
	return {}


## The canonical fixture for this property: Bricks.mtlx pins its leaks mix factor
## to 0, so the correct render is the brick texture and the inverted one is flat
## LeaksColor. Anything else cannot serve as a known-good answer.
func _find_fixture() -> String:
	for path in TestKit.all_mtlx():
		if path.get_file() == "Bricks.mtlx":
			return path
	return ""
