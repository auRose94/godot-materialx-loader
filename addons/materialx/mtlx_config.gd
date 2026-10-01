@tool
class_name MtlxConfig
extends RefCounted

## Plugin settings, stored in the project's own settings rather than hardcoded.
##
## Every setting has a default that works with no configuration at all, which is
## the point: the addon must be usable in a project it has never seen. Textures
## resolve relative to the .mtlx file by default, so the common case -- a
## MaterialX library unpacked into the project -- needs no setup.
##
## Settings appear under Project > Project Settings with the key names below.
##
## Note: EditorPlugin.add_project_plugin_setting() is a Godot 3 API and does not
## exist in 4.x, so this registers through ProjectSettings.add_property_info(),
## which is what gives the Project Settings window a correctly typed entry.

const PREFIX := "materialx/"

## Extra directories to search for textures, tried before the .mtlx's own
## directory. Empty by default: relative-to-source resolution is nearly always
## right, and a wrong root is worse than none.
const TEXTURE_ROOTS := PREFIX + "texture_roots"
## Bake GPU thumbnails automatically as materials appear or change.
const AUTO_BAKE := PREFIX + "auto_bake_previews"
## Edge length of a baked thumbnail, in pixels.
const PREVIEW_SIZE := PREFIX + "preview_size"
## Experimental: evaluate MaterialX diffuse_roughness with an Oren-Nayar lobe.
##
## Off by default. When on, a material that drives diffuse_roughness away from
## the default (and does not use subsurface scattering) gets Godot's whole
## lighting model reimplemented in the light stage, with the Lambert term
## replaced. At diffuse_roughness 0 that is identical to Godot's own path, so
## this is a real substitution rather than an approximation -- but it is still
## a copy of engine code, and engine code changes. Treat it as a preview of
## what this addon could do, not as settled behaviour.
const EXPERIMENTAL_CUSTOM_LIGHTING := PREFIX + "experimental_custom_lighting"

## Smallest useful thumbnail. Below this the bake costs the same and looks worse.
const MIN_PREVIEW_SIZE := 32
const MAX_PREVIEW_SIZE := 512


## Registers every setting with its default and a type, so it shows up in the
## Project Settings window with a sensible editor rather than as raw text.
##
## Writes to the project file, but only for settings that were absent: a value
## the user has already changed is never touched. Returns true if it wrote
## anything, so the caller can decide whether a save was needed.
##
## Everything works without this at all -- the getters below fall back to the
## same defaults -- so a project that never saves these is unaffected.
static func install_defaults() -> bool:
	var wrote := false
	wrote = _set_if_missing(TEXTURE_ROOTS, PackedStringArray(), {
		"type": TYPE_PACKED_STRING_ARRAY,
	}) or wrote
	wrote = _set_if_missing(AUTO_BAKE, true, {
		"type": TYPE_BOOL,
	}) or wrote
	wrote = _set_if_missing(PREVIEW_SIZE, 128, {
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "%d,%d,8" % [MIN_PREVIEW_SIZE, MAX_PREVIEW_SIZE],
	}) or wrote
	return wrote


static func _set_if_missing(key: String, value: Variant, info: Dictionary) -> bool:
	var added := false
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, value)
		added = true
	info["name"] = key
	# PROPERTY_USAGE_DEFAULT is STORAGE|EDITOR, and the EDITOR half is what makes
	# the setting appear in the Project Settings window at all.
	info["usage"] = PROPERTY_USAGE_DEFAULT
	ProjectSettings.add_property_info(info)
	return added


static func texture_roots() -> PackedStringArray:
	var v: Variant = ProjectSettings.get_setting(TEXTURE_ROOTS, PackedStringArray())
	if v is PackedStringArray:
		return v
	if v is Array:
		return PackedStringArray(v)
	return PackedStringArray()


static func auto_bake() -> bool:
	return bool(ProjectSettings.get_setting(AUTO_BAKE, true))


static func preview_size() -> int:
	# Clamped because the baker allocates a render target of this size, and the
	# result is downscaled to the dock's thumbnail anyway.
	var raw := int(ProjectSettings.get_setting(PREVIEW_SIZE, 128))
	return clampi(raw, MIN_PREVIEW_SIZE, MAX_PREVIEW_SIZE)


static func experimental_custom_lighting() -> bool:
	return bool(ProjectSettings.get_setting(EXPERIMENTAL_CUSTOM_LIGHTING, false))
