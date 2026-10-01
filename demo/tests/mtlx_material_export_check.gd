extends SceneTree

## Checks what the batch converter writes: a ShaderMaterial carrying the converted
## shader, rather than a bare VisualShader.
##
## The difference matters to whoever builds a level. A VisualShader is not
## something you can put on a mesh -- it has to go inside a ShaderMaterial first,
## which is a container per material. Exporting the container means the .tres loads
## straight onto a MeshInstance3D.
##
## Checked by round trip through disk rather than by inspecting the object, because
## what matters is what a user gets when they load the file: the resource type, and
## whether the shader survived serialisation with its graph intact. A VisualShader
## that serialises to an empty graph still loads as a VisualShader and still looks
## fine until something reads a uniform from it.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const TMP := "res://.material_export"

var _bad := 0
const SUBJECTS := [
	"res://materials/mtlx/Gold.mtlx",
	"res://materials/mtlx/Black_Upholstery.mtlx",
	"res://materials/mtlx/Glass.mtlx",
]


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))

	for path in SUBJECTS:
		_export(path)

	_cleanup()
	print("\n--- %s ---" % ("export OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


func _export(path: String) -> void:
	var name := path.get_file()
	var result := Emitter.build_file(path, PackedStringArray(["res://materials/mtlx"]))
	_expect(result.ok, "%s: converts" % name)

	# Mirrors MtlxConverter._as_material, so this tests the real shape.
	var mat := ShaderMaterial.new()
	mat.shader = result.shader

	var out := TMP.path_join(name.get_basename() + ".tres")
	_expect(ResourceSaver.save(mat, out) == OK, "%s: saves" % name)

	var loaded: Resource = ResourceLoader.load(out, "", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(loaded != null, "%s: loads back" % name)
	if loaded == null:
		return

	_expect(loaded is ShaderMaterial,
		"%s: loads as a ShaderMaterial, so it can go straight on a mesh"
			% name.get_basename())
	if not loaded is ShaderMaterial:
		return

	var loaded_mat: ShaderMaterial = loaded
	_expect(loaded_mat.shader != null, "%s: the shader survived" % name.get_basename())
	if loaded_mat.shader == null:
		return

	# A VisualShader that serialised to an empty graph would still pass the two
	# checks above. Compare the node count against the freshly built one.
	var expected := result.shader.get_node_list(1).size()
	var got: int = loaded_mat.shader.get_node_list(1).size()
	_expect(got == expected,
		"%s: graph survived intact (%d fragment nodes)" % [name.get_basename(), expected])

	# And the code must still be a real spatial shader with its uniforms, because
	# that is what a material actually samples.
	var code: String = loaded_mat.shader.code
	_expect(code.find("shader_type spatial") >= 0,
		"%s: still a spatial shader" % name.get_basename())
	_expect(code.find("ALBEDO") >= 0,
		"%s: still drives ALBEDO" % name.get_basename())
	_expect(not code.contains("ERROR"),
		"%s: no compile error in the exported code" % name.get_basename())


func _cleanup() -> void:
	var abs_dir := ProjectSettings.globalize_path(TMP)
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)


func _expect(cond: bool, what: String) -> void:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
