@tool
class_name MtlxTextureFixer
extends RefCounted

## Corrects Godot import settings for textures referenced by MaterialX files.
##
## The reason this matters: a MaterialX library distinguishes colour maps from
## data maps by `colorspace`, and Godot distinguishes them by how the texture
## is imported *and* by the sampler hint the shader declares. Two mistakes are
## common and both are invisible until something looks wrong:
##
##  1. `compress/mode=2` (VRAM Compressed) on a roughness/AO/metallic map.
##     That is block compression chosen for colour, which throws away the
##     precision those maps need and bands badly. Godot's own answer for 3D
##     textures is `detect_3d/compress_to=1`, i.e. VRAM Uncompressed.
##  2. sRGB left on a data map, or missing on a colour map. sRGB decoding a
##     roughness map changes every value in it.
##
## Nothing here is destructive: settings are written to the .import sidecar and
## can be reverted by reimporting.


## What a texture is used for, inferred from how MaterialX refers to it.
enum Usage {
	COLOR,      ## base colour / emission
	DATA,       ## roughness, metallic, AO, masks
	NORMAL,     ## tangent-space normal map
	UNKNOWN,
}

## Scans a .mtlx and reports the usage of every texture it references.
## Returns { "res://path": Usage }
static func scan(path: String) -> Dictionary:
	var out: Dictionary = {}
	var doc: MtlxDocument = MtlxDocument.load_from_file(path)
	if doc == null:
		return out

	for el in doc.elements:
		if el.def != "image":
			continue
		var file_inp: MtlxDocument.MtlxInput = el.input("file")
		if file_inp == null:
			continue
		var rel: String = file_inp.value.strip_edges()
		if rel == "":
			continue
		var res: String = _to_res_path(path, rel)
		if res == "":
			continue
		out[res] = _usage_for(doc, el, file_inp)
	return out


## How a given image node is ultimately used, which decides whether it needs
## normal-map import settings. A texture read as tangent-space normal data by
## a normalmap node needs `compress/normal_map`; one read as a plain vector
## does not.
static func _usage_for(doc: MtlxDocument, image: MtlxDocument.MtlxElement, file_inp: MtlxDocument.MtlxInput) -> Usage:
	if file_inp.is_srgb():
		return Usage.COLOR

	var as_normal: bool = _feeds_normalmap(doc, image)
	if as_normal and image.type == "vector3":
		return Usage.NORMAL
	return Usage.DATA


## Walks forward from an image to see whether a <normalmap> consumes it.
static func _feeds_normalmap(doc: MtlxDocument, image: MtlxDocument.MtlxElement) -> bool:
	var name: String = image.name
	for el in doc.elements:
		if el.def != "normalmap":
			continue
		var inp: MtlxDocument.MtlxInput = el.input("in")
		if inp == null:
			continue
		var src: MtlxDocument.MtlxElement = doc.source_element(inp, el.graph)
		if src != null and src.name == name:
			return true
	# An extract of the image feeding a normalmap counts too.
	for el in doc.elements:
		if el.def != "extract":
			continue
		var inp: MtlxDocument.MtlxInput = el.input("in")
		if inp == null:
			continue
		var src: MtlxDocument.MtlxElement = doc.source_element(inp, el.graph)
		if src == null or src.name != name:
			continue
		for other in doc.elements:
			if other.def != "normalmap":
				continue
			var oi: MtlxDocument.MtlxInput = other.input("in")
			if oi == null:
				continue
			var osrc: MtlxDocument.MtlxElement = doc.source_element(oi, other.graph)
			if osrc != null and osrc.name == el.name:
				return true
	return false


## Applies correct import settings to one texture. Returns true if anything
## changed. `save` writes the .import sidecar; pass false to dry-run.
static func apply(res_path: String, usage: Usage, save: bool = false) -> Dictionary:
	var changes: Dictionary = {}
	if not FileAccess.file_exists(res_path):
		changes["error"] = "texture not found: " + res_path
		return changes

	# Godot derives the .import sidecar path from the source path.
	var import_path: String = res_path + ".import"
	if not FileAccess.file_exists(import_path):
		# Not yet imported; the importer will pick up `detect_3d` on its own.
		return changes

	var text: String = FileAccess.get_file_as_string(import_path)
	var params: Dictionary = {}
	var order: PackedStringArray = []
	for line in text.split("\n"):
		var t: String = line.strip_edges()
		if "=" in t and not t.begins_with("["):
			var kv: PackedStringArray = t.split("=", true, 1)
			params[kv[0]] = kv[1]
		elif t.begins_with("["):
			order.append(t)

	match usage:
		Usage.COLOR:
			# Colour data: sRGB on, and VRAM compression is acceptable.
			if params.get("source_color", "") != "true":
				params["source_color"] = "true"
				changes["source_color"] = "true"
		Usage.DATA:
			# Data map: never sRGB, and uncompressed so values stay precise.
			if params.get("source_color", "") == "true":
				params["source_color"] = "false"
				changes["source_color"] = "false"
			if params.get("compress/mode", "") == "2":
				# 3 = VRAM Uncompressed: keeps precision without BC artifacts.
				params["compress/mode"] = "3"
				changes["compress/mode"] = "3 (was 2, VRAM Uncompressed for a data map)"
			if params.get("detect_3d/compress_to", "") == "0":
				params["detect_3d/compress_to"] = "1"
				changes["detect_3d/compress_to"] = "1"
		Usage.NORMAL:
			if params.get("source_color", "") == "true":
				params["source_color"] = "false"
				changes["source_color"] = "false"
			if params.get("compress/normal_map", "") != "1":
				params["compress/normal_map"] = "1"
				changes["compress/normal_map"] = "1 (BC5/RGTC normal compression)"
			if params.get("detect_3d/compress_to", "") == "0":
				params["detect_3d/compress_to"] = "1"
				changes["detect_3d/compress_to"] = "1"

	if changes.is_empty():
		return changes

	if save:
		_set_option(text, "source_color", params.get("source_color", ""))
		_set_option(text, "compress/mode", params.get("compress/mode", ""))
		_set_option(text, "compress/normal_map", params.get("compress/normal_map", ""))
		_set_option(text, "detect_3d/compress_to", params.get("detect_3d/compress_to", ""))
		var f: FileAccess = FileAccess.open(import_path, FileAccess.WRITE)
		if f == null:
			changes["error"] = "could not write " + import_path
			return changes
		f.store_string(text)
		f.close()
	return changes


static func _set_option(text: String, key: String, value: String) -> String:
	if value == "":
		return text
	# The keys here are literal option names with no regex metacharacters, so
	# anchoring them directly is safe.
	var re := RegEx.new()
	re.compile("(?m)^%s=.*$" % key)
	if re.search(text) != null:
		return re.sub(text, "%s=%s" % [key, value], true)
	# Append to the [params] section if the key is absent.
	return text + "\n%s=%s" % [key, value]


static func _to_res_path(mtlx_path: String, rel: String) -> String:
	if rel.begins_with("res://"):
		return rel
	var dir: String = mtlx_path.get_base_dir()
	return dir.path_join(rel)


## Convenience: fix every texture referenced by a .mtlx, returning a summary.
static func fix_file(mtlx_path: String, save: bool = true) -> Dictionary:
	var scan_result: Dictionary = scan(mtlx_path)
	var report: Dictionary = {"changed": [], "unchanged": 0, "missing": []}
	for res_path in scan_result.keys():
		var usage: Usage = scan_result[res_path]
		var changes: Dictionary = apply(res_path, usage, save)
		if changes.has("error"):
			report["missing"].append({"path": res_path, "error": changes["error"]})
		elif changes.is_empty():
			report["unchanged"] += 1
		else:
			report["changed"].append({"path": res_path, "usage": usage, "changes": changes})
	return report