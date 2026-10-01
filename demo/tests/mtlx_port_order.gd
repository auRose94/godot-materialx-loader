extends SceneTree

## Maps spatial fragment output port index to port name, empirically.
##
## GodotMap hard-codes these indices and they cannot be derived from
## shader_types.cpp, whose registration order interleaves readable built-ins
## (FRONT_FACING, NORMAL, UV, ...) with writable outputs. VisualShaderNodeOutput
## exposes neither an input count nor a property list for its ports, so the only
## trustworthy source is Godot's own generated code.
##
## Write a constant to one port, let Godot generate, and read the port name off
## the assignment. Confirmed this way: port 18 is BACKLIGHT, which is what
## GodotMap claims and what no ordering table in the source agrees with.
##
## This matters for subsurface: every listing puts SSS_TRANSMITTANCE_COLOR,
## _DEPTH and _BOOST between SSS_STRENGTH and BACKLIGHT, so if they were output
## ports the indices would shift and a hand-maintained table would be wrong.

const FROM := 15
const TO := 26


func _init() -> void:
	for port in range(FROM, TO):
		print("  port %2d -> %s" % [port, _port_name(port)])
	quit(0)


func _port_name(port: int) -> String:
	var sh := VisualShader.new()
	var value := VisualShaderNodeFloatConstant.new()
	value.constant = 0.375
	sh.add_node(1, value, Vector2.ZERO, 2)
	sh.connect_nodes(1, 2, 0, 0, port)

	for line in sh.code.split("\n"):
		var s := line.strip_edges()
		# The generated fragment body writes `PORT_NAME = ...(n_out2p0);`, so the
		# name comes from Godot rather than from a table kept here by hand.
		if s.find("n_out2p0") >= 0 and s.find("0.375") < 0:
			return s.split("=")[0].strip_edges()
	return "(unconnected or not an output port)"
