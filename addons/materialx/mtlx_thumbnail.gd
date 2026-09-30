@tool
class_name MtlxThumbnail
extends RefCounted

## Renders a small shaded-sphere image of a MaterialX material.
##
## Kept separate from MtlxPreviewGenerator so the rendering is plain GDScript
## with no editor dependency and can be exercised headlessly.
##
## This is a real, if simplified, render: it samples the material's actual
## base-colour, roughness and normal maps and shades them, so the result
## reflects the material rather than being a generic icon. It is not a PBR
## render and will not match the engine exactly -- for that, use the live
## preview in the MaterialX dock.
##
## Only the dominant map of each kind is used; a material whose maps are
## combined inside the graph gets a shaded ball of its base colour, which is
## still more useful than nothing.

## Key light direction in view space.
const LIGHT_DIR := Vector3(-0.45, 0.62, 0.65)
const AMBIENT := 0.18
const BACKGROUND := Color(0.16, 0.17, 0.19)


## Renders `path` at `px_size` square. Returns null if the file cannot be read.
static func render(path: String, px_size: int) -> Image:
	if px_size <= 0:
		return null

	var doc: MtlxDocument = MtlxDocument.load_from_file(path)
	if doc == null or doc.materials.is_empty():
		return null
	var surface: MtlxDocument.MtlxElement = doc.find_surface(doc.materials[0])
	if surface == null:
		return null

	var maps: Dictionary = collect_maps(doc, surface, path.get_base_dir())
	return render_sphere(px_size, maps)


# ---------------------------------------------------------------------------
# Map collection
# ---------------------------------------------------------------------------


## Gathers the material's base colour, roughness and normal, from either a
## literal or a texture.
##
## Roles come from MaterialX's colorspace and data type: an sRGB color3 is base
## colour, a linear vector3 is a normal, a float/vector4 is a data mask.
static func collect_maps(doc: MtlxDocument, surface: MtlxDocument.MtlxElement, base_dir: String) -> Dictionary:
	var albedo: Vector3 = Vector3(0.8, 0.8, 0.8)
	var albedo_in: MtlxDocument.MtlxInput = surface.input("base_color")
	if albedo_in != null and albedo_in.typed_value() != null:
		albedo = GodotMap._as_vector3(albedo_in.typed_value())

	var rough: float = 0.3
	var rough_in: MtlxDocument.MtlxInput = surface.input("specular_roughness")
	if rough_in != null and rough_in.typed_value() != null:
		rough = clampf(float(rough_in.typed_value()), 0.04, 1.0)

	var out: Dictionary = {
		"albedo": albedo,
		"roughness": rough,
		"metallic": clampf(float(surface.input_value("metalness", 0.0)), 0.0, 1.0),
		"albedo_img": null,
		"rough_img": null,
		"normal_img": null,
	}

	# Which images actually feed each surface input. This has to walk past the
	# intermediate maths nodes, because these files almost never wire a map
	# straight to the surface: base_color usually runs through a mix, roughness
	# through a clamp or a max of several channels, and normal through a
	# normalmap. Stopping at the first node finds no image at all.
	var albedo_want: PackedStringArray = reachable_images(doc, surface, "base_color")
	var rough_want: PackedStringArray = reachable_images(doc, surface, "specular_roughness")
	var normal_want: PackedStringArray = reachable_images(doc, surface, "normal")

	for el in doc.elements:
		if el.def != "image":
			continue
		var file_inp: MtlxDocument.MtlxInput = el.input("file")
		if file_inp == null or file_inp.value.strip_edges() == "":
			continue

		var is_normal: bool = el.type == "vector3" and not file_inp.is_srgb()
		var is_data: bool = el.type == "float" or el.type == "vector4"
		var is_colour: bool = file_inp.is_srgb()

		var slot: String = ""
		if is_colour and el.name in albedo_want:
			slot = "albedo_img"
		elif is_normal and el.name in normal_want:
			slot = "normal_img"
		elif is_data and el.name in rough_want:
			slot = "rough_img"
		if slot == "" or out[slot] != null:
			continue

		var tex: Texture2D = _load_texture(base_dir.path_join(file_inp.value.strip_edges()))
		if tex != null:
			out[slot] = tex

	# Fall back to role-by-type when the graph walk came up empty, which
	# happens when a material feeds a map in a way this deliberately-simple
	# traversal does not follow. A plausible map beats a blank ball.
	for slot in ["albedo_img", "rough_img", "normal_img"]:
		if out[slot] != null:
			continue
		for el in doc.elements:
			if el.def != "image":
				continue
			var file_inp: MtlxDocument.MtlxInput = el.input("file")
			if file_inp == null or file_inp.value.strip_edges() == "":
				continue
			var want_normal: bool = slot == "normal_img"
			var want_data: bool = slot == "rough_img"
			var is_normal: bool = el.type == "vector3" and not file_inp.is_srgb()
			var is_data: bool = el.type == "float" or el.type == "vector4"
			var ok: bool = false
			if want_normal:
				ok = is_normal
			elif want_data:
				ok = is_data
			else:
				ok = file_inp.is_srgb()
			if not ok:
				continue
			var tex: Texture2D = _load_texture(base_dir.path_join(file_inp.value.strip_edges()))
			if tex != null:
				out[slot] = tex
				break

	return out


## Names of the <image> elements reachable from a standard_surface input.
##
## Breadth-first so the nearest map wins, bounded so a cyclic graph cannot hang.
static func reachable_images(doc: MtlxDocument, surface: MtlxDocument.MtlxElement, input_name: String, max_depth: int = 10) -> PackedStringArray:
	var found := PackedStringArray()
	var inp: MtlxDocument.MtlxInput = surface.input(input_name)
	if inp == null:
		return found

	var seen: Dictionary = {}
	# Each entry is [input, graph, depth].
	var queue: Array = [[inp, surface.graph, 0]]
	while not queue.is_empty():
		var item: Array = queue.pop_front()
		var cur: MtlxDocument.MtlxInput = item[0]
		var graph: String = item[1]
		var depth: int = item[2]
		if depth > max_depth:
			continue

		var src: MtlxDocument.MtlxElement = doc.source_element(cur, graph)
		if src == null:
			continue
		var key: String = "%s@%s" % [src.name, src.graph]
		if seen.has(key):
			continue
		seen[key] = true

		if src.def == "image":
			if not found.has(src.name):
				found.append(src.name)
			continue

		for child_name in _forward_inputs(src.def):
			var child: MtlxDocument.MtlxInput = src.input(child_name)
			if child != null and child.is_link():
				queue.append([child, src.graph, depth + 1])
	return found


## Which of a node's inputs lead downstream, i.e. which can reach a texture.
## Ordered so the visually dominant term comes first (mix's foreground, then
## background).
static func _forward_inputs(def: String) -> PackedStringArray:
	match def:
		"mix", "overlay", "hsvadjust":
			return PackedStringArray(["fg", "bg", "in"])
		"normalmap", "clamp", "floor", "invert", "sqrt", "absolutevalue", "normalize", "convert":
			return PackedStringArray(["in"])
		"extract":
			return PackedStringArray(["in"])
		"multiply", "add", "subtract", "divide", "power", "max", "min", "dot":
			return PackedStringArray(["in1", "in2", "in"])
		"combine3":
			return PackedStringArray(["in1", "in2", "in3"])
	return PackedStringArray()


static func _load_texture(res_path: String) -> Texture2D:
	if not res_path.begins_with("res://"):
		return null
	if not ResourceLoader.exists(res_path):
		return null
	return load(res_path) as Texture2D


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


## Shades a UV sphere with the material's maps.
##
## Lambert diffuse plus a Blinn-Phong lobe whose exponent comes from roughness,
## an ambient term, and the normal map perturbing the geometric normal.
static func render_sphere(px_size: int, maps: Dictionary) -> Image:
	if px_size <= 0:
		return null

	var albedo_img: Image = readable_image(maps.get("albedo_img"))
	var rough_img: Image = readable_image(maps.get("rough_img"))
	var normal_img: Image = readable_image(maps.get("normal_img"))

	var tint: Vector3 = GodotMap._as_vector3(maps.get("albedo", Vector3(0.8, 0.8, 0.8)))
	var metallic: float = float(maps.get("metallic", 0.0))
	var rough_flat: float = float(maps.get("roughness", 0.3))

	var out := Image.create(px_size, px_size, false, Image.FORMAT_RGB8)
	var light: Vector3 = LIGHT_DIR.normalized()
	var view := Vector3(0.0, 0.0, 1.0)
	var halfway: Vector3 = (light + view).normalized()
	var f: float = float(px_size) * 0.5
	var radius: float = f * 0.92

	for y in px_size:
		for x in px_size:
			var nx: float = (float(x) + 0.5 - f) / radius
			var ny: float = (f - float(y) - 0.5) / radius
			var d2: float = nx * nx + ny * ny
			if d2 > 1.0:
				out.set_pixel(x, y, BACKGROUND)
				continue

			var n := Vector3(nx, ny, sqrt(1.0 - d2)).normalized()
			var u: float = 0.5 + atan2(n.x, n.z) / TAU
			var v: float = 0.5 - asin(clampf(n.y, -1.0, 1.0)) / PI

			var albedo := tint
			if albedo_img != null:
				# Decode sRGB, matching the : source_color sampler the shader
				# declares, so the thumbnail's colour matches the material's.
				albedo = tint * sample(albedo_img, u, v, true)

			var rough: float = rough_flat
			if rough_img != null:
				rough = clampf(sample(rough_img, u, v, false).x, 0.04, 1.0)

			var shade_n: Vector3 = n
			if normal_img != null:
				shade_n = perturb(n, normal_img, u, v)

			var ndotl: float = maxf(shade_n.dot(light), 0.0)
			var shininess: float = clampf(2.0 / pow(rough, 4.0) - 2.0, 1.0, 2048.0)
			var spec: float = pow(maxf(shade_n.dot(halfway), 0.0), shininess) * (shininess + 8.0) / 25.13

			# Metal suppresses diffuse and tints its highlight, as in the engine.
			var lit: Vector3 = albedo * (ndotl * (1.0 - metallic * 0.85) + AMBIENT)
			lit += albedo * (spec * lerpf(0.04, 1.0, metallic) * 3.0)

			out.set_pixel(x, y, Color(
				clampf(lit.x, 0.0, 1.0),
				clampf(lit.y, 0.0, 1.0),
				clampf(lit.z, 0.0, 1.0)))

	return out


## Rotates the geometric normal by the tangent-space normal map.
static func perturb(n: Vector3, img: Image, u: float, v: float) -> Vector3:
	var t: Vector3 = sample(img, u, v, false) * 2.0 - Vector3.ONE
	var up := Vector3.UP if absf(n.y) < 0.99 else Vector3.RIGHT
	var tangent: Vector3 = up.cross(n).normalized()
	var bitangent: Vector3 = n.cross(tangent).normalized()
	return (tangent * t.x + bitangent * t.y + n * maxf(t.z, 0.0)).normalized()


## A CPU-readable copy of a texture, or null when it cannot be sampled here.
static func readable_image(tex: Variant) -> Image:
	if not (tex is Texture2D):
		return null
	var img: Image = (tex as Texture2D).get_image()
	if img == null:
		return null
	if img.is_compressed():
		# Compressed textures normally need the renderer to read back, which is
		# not available on a preview worker thread; decompress if we can.
		if img.decompress() != OK:
			return null
	return img


## Bilinear sample as an RGB vector.
static func sample(img: Image, u: float, v: float, srgb: bool) -> Vector3:
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w <= 0 or h <= 0:
		return Vector3.ONE

	var fx: float = clampf(u, 0.0, 0.9999) * float(w) - 0.5
	var fy: float = clampf(v, 0.0, 0.9999) * float(h) - 0.5
	var x0: int = clampi(int(floor(fx)), 0, w - 1)
	var y0: int = clampi(int(floor(fy)), 0, h - 1)
	var x1: int = mini(x0 + 1, w - 1)
	var y1: int = mini(y0 + 1, h - 1)
	var ax: float = fx - floor(fx)
	var ay: float = fy - floor(fy)

	var top: Vector3 = texel(img, x0, y0, srgb).lerp(texel(img, x1, y0, srgb), ax)
	var bottom: Vector3 = texel(img, x0, y1, srgb).lerp(texel(img, x1, y1, srgb), ax)
	return top.lerp(bottom, ay)


static func texel(img: Image, x: int, y: int, srgb: bool) -> Vector3:
	var c: Color = img.get_pixel(x, y)
	var v := Vector3(c.r, c.g, c.b)
	if srgb:
		v = Vector3(srgb_to_linear(v.x), srgb_to_linear(v.y), srgb_to_linear(v.z))
	return v


## sRGB electro-optical transfer function.
##
## Godot exposes this to shaders but not to GDScript, and it is needed so a
## colour map is decoded exactly as the `: source_color` sampler decodes it.
## Without this the thumbnails look washed out next to the real material.
static func srgb_to_linear(c: float) -> float:
	if c <= 0.04045:
		return c / 12.92
	return pow((c + 0.055) / 1.055, 2.4)