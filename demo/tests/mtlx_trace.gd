#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Prints the generated shader code and the node graph for one .mtlx, so a
## material's ALBEDO path can be traced end to end.
##
## Usage: mtlx_trace.gd <res://some/Name.mtlx>   (defaults to the first material found)

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")


func _init() -> void:
	var path: String = TestKit.first(1)[0]
	for a in OS.get_cmdline_user_args():
		path = a
		break

	var r: MtlxEmitter.Result = Emitter.build_file(path)
	if not r.ok:
		print("build failed: ", r.message)
		quit(1)
		return

	print("=== %s ===\n" % path.get_file())
	print("--- nodes ---")
	for id in r.shader.get_node_list(1):
		var n: VisualShaderNode = r.shader.get_node(1, id)
		print("%3d  %-32s %s" % [id, n.get_class(), _detail(n)])

	print("\n--- connections ---")
	for c in r.shader.get_node_connections(1):
		var d: Dictionary = c
		print("  %3d:%d -> %d:%d" % [d["from_node"], d["from_port"], d["to_node"], d["to_port"]])

	print("\n--- generated code ---")
	print(r.shader.code)

	for n in r.notes:
		print("note: ", n)
	quit(0)


func _detail(n: VisualShaderNode) -> String:
	if n is VisualShaderNodeTexture:
		var t: VisualShaderNodeTexture = n
		return "type=%d tex=%s" % [t.texture_type, t.texture.resource_path if t.texture else "-"]
	if n is VisualShaderNodeMix:
		return "op_type=%d defaults=%s" % [n.op_type, str(n.get_default_input_values())]
	if n is VisualShaderNodeVectorOp:
		return "op=%d op_type=%d defaults=%s" % [n.operator, n.op_type, str(n.get_default_input_values())]
	if n is VisualShaderNodeFloatOp:
		return "op=%d defaults=%s" % [n.operator, str(n.get_default_input_values())]
	if n is VisualShaderNodeFloatFunc:
		return "func=%d" % n.function
	if n is VisualShaderNodeVectorFunc:
		return "func=%d" % n.function
	if n is VisualShaderNodeFloatParameter:
		return "%s=%f" % [n.parameter_name, n.default_value]
	if n is VisualShaderNodeVec3Parameter:
		return "%s=%s" % [n.parameter_name, str(n.default_value)]
	if n is VisualShaderNodeVec3Constant:
		return "const=%s" % str(n.constant)
	if n is VisualShaderNodeFloatConstant:
		return "const=%f" % n.constant
	if n is VisualShaderNodeVectorCompose:
		return "defaults=%s" % str(n.get_default_input_values())
	if n is VisualShaderNodeDotProduct:
		return ""
	if n is VisualShaderNodeClamp:
		return "defaults=%s" % str(n.get_default_input_values())
	if n is VisualShaderNodeInput:
		return n.input_name
	return ""