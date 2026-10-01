extends SceneTree

## Renders one material twice -- custom lighting forced on, then off -- and
## reports the luminance of each, so a material that goes dark on the custom path
## is caught numerically instead of hiding in a contact sheet.
##
## Gold is the case that motivated this: it has diffuse_roughness 0.5, so it is
## one of the few materials the custom path reaches, and it rendered at 0.016
## luminance -- essentially black -- for a bright gold dielectric.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const FLAG := "materialx/custom_lighting"
const SIZE := Vector2i(256, 256)
const RES := 256

## The six named materials are joined by whatever corpus materials the custom
## lighting path actually reaches, so relaxing the gate to admit subsurface
## materials is covered here rather than assumed. A material that darkens when the
## custom path takes over is the failure this is looking for.
const NAMED := [
	"res://materials/Gold.mtlx",
	"res://materials/Gold_Foil.mtlx",
	"res://materials/Perforated_Metal.mtlx",
	"res://materials/TH_Blue_Denim_Fabric.mtlx",
	"res://materials/Black_Upholstery.mtlx",
	"res://materials/Glazed_Cube_Pattern_Tiles.mtlx",
]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var saved: Variant = ProjectSettings.get_setting(FLAG, true)
	var saved_present := ProjectSettings.has_setting(FLAG)

	var subjects: PackedStringArray = PackedStringArray(NAMED)
	subjects.append_array(_custom_lighting_corpus())

	print("checking %d material(s)\n" % subjects.size())
	print("%-34s %10s %10s %9s" % ["material", "custom", "builtin", "delta"])
	var dark := 0
	for path in subjects:
		ProjectSettings.set_setting(FLAG, true)
		var on := await _centre_luminance(path)
		ProjectSettings.set_setting(FLAG, false)
		var off := await _centre_luminance(path)

		var delta: float = on - off
		# A custom path that darkens the material is the failure this is looking
		# for; a brighter result is the point of the feature.
		if delta < -0.05:
			dark += 1
		print("%-34s %10.4f %10.4f %+9.4f%s" % [
			path.get_file(), on, off, delta, "   <-- DARKER" if delta < -0.05 else ""])

	if saved_present:
		ProjectSettings.set_setting(FLAG, saved)
	else:
		ProjectSettings.set_setting(FLAG, null)

	print("\nmaterials darkened by the custom path: %d / %d" % [dark, subjects.size()])
	quit(1 if dark > 0 else 0)


## Mean luminance over a disc at the centre of the frame, where the sphere is.
func _centre_luminance(path: String) -> float:
	var result := Emitter.build_file(path, PackedStringArray(["res://materials"]))
	if not result.ok:
		push_warning("%s did not build: %s" % [path.get_file(), result.message])
		return -1.0

	var vp := SubViewport.new()
	vp.size = SIZE
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	vp.own_world_3d = true
	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.16, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.78)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	vp.world_3d = world

	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.position = Vector3(0, 0, 3.1)
	cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
	vp.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(-26.0), 0.0)
	light.light_energy = 2.4
	light.shadow_enabled = false
	vp.add_child(light)

	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	var mat := ShaderMaterial.new()
	mat.shader = result.shader
	mesh.material_override = mat
	vp.add_child(mesh)

	root.add_child(vp)
	for i in 20:
		await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	await RenderingServer.frame_post_draw

	var sum := 0.0
	var n := 0
	for y in range(RES / 2 - 20, RES / 2 + 20, 2):
		for x in range(RES / 2 - 20, RES / 2 + 20, 2):
			var c := img.get_pixel(x, y)
			sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return sum / maxf(n, 1.0)


## Every corpus material that the custom lighting path takes over. Found by
## building with the setting on and looking for the light node, so the list cannot
## drift from what the gate actually admits.
func _custom_lighting_corpus() -> PackedStringArray:
	ProjectSettings.set_setting("materialx/custom_lighting", true)
	var out := PackedStringArray()
	var d := DirAccess.open("res://materials")
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".mtlx"):
			continue
		var path := "res://materials/" + f
		var result := Emitter.build_file(path, PackedStringArray(["res://materials"]))
		if not result.ok:
			continue
		for id in result.shader.get_node_list(2):
			if result.shader.get_node(2, id) is VisualShaderNodeCustom:
				out.append(path)
				break
	return out

