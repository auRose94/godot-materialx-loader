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
## Removed: the thumbnail pipeline. materialx/auto_bake_previews and
## materialx/preview_size are dropped rather than left in place, because a setting
## that no longer reads anything is worse than an absent one -- it looks
## configurable and is not.
## Evaluate MaterialX diffuse_roughness with an Oren-Nayar lobe.
##
## On by default, because the lobe is MaterialX's own answer and Godot has no
## equivalent: leaving it off silently renders those materials with Lambert and
## loses the roughness the file asked for.
##
## The cost is real. A material that uses this has Godot's whole lighting model
## reimplemented in the light stage, so this addon -- not the engine -- is
## responsible for the result. Turning it off falls back to Godot's own BRDF,
## which is the escape hatch if Godot fixes a lighting bug and you would rather
## have that than this.
##
## Two things the custom node cannot do, both engine limits rather than oversights:
##
## - At diffuse_roughness 0 MaterialX's Oren-Nayar term is exactly 1.0, which is
##   Lambert, so for a material that sets it the substitution is faithful rather
##   than approximate.
## - MaterialX also scales *indirect* diffuse by the directional albedo
##   (mx_oren_nayar_diffuse_bsdf.glsl:34). Godot computes ambient in the fragment
##   stage, outside the light function, so a material with a high
##   diffuse_roughness keeps an ambient term that is not darkened to match its
##   direct light. Only affects the materials this setting actually reaches.
const CUSTOM_LIGHTING := PREFIX + "custom_lighting"
## The name this setting had while it was opt-in, kept so an existing project
## does not silently switch behaviour when it upgrades.
const LEGACY_CUSTOM_LIGHTING := PREFIX + "experimental_custom_lighting"
## Refract the scene behind a transmissive surface, in place of fading it out.
##
## Off by default while it settles. Godot has no refraction lobe in its spatial
## BRDF, so a MaterialX `transmission` used to become ALPHA and nothing else --
## clear glass came out as a uniformly faded shell with a specular highlight on
## it. Reading the screen texture lets the surface show what is actually behind
## it, displaced along the refracted vector.
##
## The cost is that this material now reads the screen, which Godot treats as
## alpha-bearing (scene_shader_forward_clustered.cpp:255): it stops casting
## shadows unless the shader uses a depth prepass. That is the engine's rule, not
## a choice this addon makes.
const SCREEN_SPACE_REFRACTION := PREFIX + "screen_space_refraction"

## Settings the removed thumbnail pipeline read. A key that no longer reads
## anything is worse than an absent one -- it looks configurable and is not --
## so projects that still carry them have them dropped on first load.
const DEAD_KEYS := [
	PREFIX + "auto_bake_previews",
	PREFIX + "preview_size",
]

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
	# Migrated first, so the old key's value lands in the new key before
	# _set_if_missing gives it the new default. Doing this afterwards would mean
	# the new key always already exists, and a project that deliberately chose
	# "off" would be switched on by the upgrade.
	_drop_legacy()
	# Registered even though it has a good default, or it never appears in the
	# Project Settings window at all.
	wrote = _set_if_missing(CUSTOM_LIGHTING, true, {
		"type": TYPE_BOOL,
	}) or wrote
	wrote = _set_if_missing(SCREEN_SPACE_REFRACTION, false, {
		"type": TYPE_BOOL,
	}) or wrote
	_drop_dead()
	return wrote


## A project that set the old key keeps its value rather than picking up the new
## default, so upgrading never silently changes how materials render. The key
## itself is removed, since leaving it would show a dead entry in Project
## Settings.
static func _drop_legacy() -> void:
	if not ProjectSettings.has_setting(LEGACY_CUSTOM_LIGHTING):
		return
	if not ProjectSettings.has_setting(CUSTOM_LIGHTING):
		ProjectSettings.set_setting(CUSTOM_LIGHTING,
			bool(ProjectSettings.get_setting(LEGACY_CUSTOM_LIGHTING, true)))
	ProjectSettings.set_setting(LEGACY_CUSTOM_LIGHTING, null)


## Same treatment for keys of features that no longer exist. They are inside the
## addon's own namespace, so removing them touches nothing the user owns.
static func _drop_dead() -> void:
	for key in DEAD_KEYS:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)


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


static func custom_lighting() -> bool:
	return bool(ProjectSettings.get_setting(CUSTOM_LIGHTING, true))


static func screen_space_refraction() -> bool:
	return bool(ProjectSettings.get_setting(SCREEN_SPACE_REFRACTION, false))
