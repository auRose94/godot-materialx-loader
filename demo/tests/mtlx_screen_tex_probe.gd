extends SceneTree

## Confirms a VisualShader can sample the screen texture, which is what
## screen-space refraction needs.
##
## I previously concluded this was impossible, on two true but irrelevant
## observations: no spatial GLSL shipped with the engine uses hint_screen_texture,
## and none of the spatial fragment output ports are samplers. Neither is
## evidence. The engine's own spatial shaders have no reason to read the screen,
## and a VisualShader declares uniforms through nodes rather than through its
## output node.
##
## The uniform comes from VisualShaderNodeTexture.source. visual_shader_nodes.cpp
## emits `uniform sampler2D <id>_screen_tex : hint_screen_texture;` for
## SOURCE_SCREEN on a spatial fragment stage, and the renderer supplies it --
## render_forward_clustered.cpp:2369-2373 allocates and copies the screen buffer
## whenever a shader reports using it.
##
## VisualShaderNodeVectorRefract is the node for the vector math: three inputs
## (incident, normal, eta) and one output. A VisualShader cannot call the shader
## language's refract() directly.

const GodotMap := preload("res://addons/materialx/godot_map.gd")

const FRAGMENT := 1  # VisualShader.TYPE_FRAGMENT


func _init() -> void:
	var sh := VisualShader.new()

	var screen := VisualShaderNodeTexture.new()
	screen.source = VisualShaderNodeTexture.SOURCE_SCREEN
	sh.add_node(FRAGMENT, screen, Vector2(0, 0), 2)

	var uv := VisualShaderNodeInput.new()
	uv.input_name = "ScreenUV"
	sh.add_node(FRAGMENT, uv, Vector2(-200, 0), 3)

	sh.connect_nodes(FRAGMENT, 3, 0, 2, 0)
	sh.connect_nodes(FRAGMENT, 2, 0, 0, GodotMap.OUT_EMISSION)

	print("=== generated spatial shader ===")
	for line in sh.code.split("\n"):
		var s := line.strip_edges()
		if not s.is_empty():
			print("  " + s)

	var has_screen := sh.code.find("hint_screen_texture") >= 0
	print("\nscreen sampler in generated code: %s" % has_screen)
	quit(0 if has_screen else 1)
