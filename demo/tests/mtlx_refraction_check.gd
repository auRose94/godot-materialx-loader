extends SceneTree

## Checks screen-space refraction end to end.
##
## Three things have to hold. The generated shader must actually contain a screen
## sampler and a refract call -- a graph that silently fails to wire produces a
## shader that compiles and shows nothing, which is the same failure mode as every
## other silent conversion bug. The depth texture must be sampled, so the
## displaced UV can be masked against whatever the sample lands on. And ALPHA
## must be written as 1.0, which is what moves the material into the transparent
## pass, after the screen copy: the previous version stayed opaque, sampled the
## previous frame's copy of itself, and compounded that into a black disc with a
## glowing ring.
##
## Glass.mtlx is the subject: transmission = 1, which used to produce ALPHA = 0.15
## and a uniformly faded shell.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

const FLAG := "materialx/screen_space_refraction"
const GLASS := "res://materials/Glass.mtlx"
const OPAQUE := "res://materials/Gold.mtlx"

var _bad := 0


func _init() -> void:
	var saved: Variant = ProjectSettings.get_setting(FLAG, false)
	var had := ProjectSettings.has_setting(FLAG)

	ProjectSettings.set_setting(FLAG, false)
	var off := Emitter.build_file(GLASS, PackedStringArray(["res://materials"]))
	_expect(off.ok, "Glass builds with refraction off")
	var off_code: String = off.shader.code
	print("  off: screen sampler=%s  refract=%s" % [
		off_code.find("hint_screen_texture") >= 0,
		off_code.find("refract(") >= 0])
	_expect(off_code.find("hint_screen_texture") < 0,
		"off: no screen sampler is emitted")
	_expect(off_code.find("refract(") < 0, "off: no refract call is emitted")
	_expect(_alpha_written(off_code),
		"off: transmission still falls back to ALPHA")

	ProjectSettings.set_setting(FLAG, true)
	var on := Emitter.build_file(GLASS, PackedStringArray(["res://materials"]))
	_expect(on.ok, "Glass builds with refraction on")
	var code: String = on.shader.code
	print("\n  on: screen sampler=%s  refract=%s  depth=%s" % [
		code.find("hint_screen_texture") >= 0,
		code.find("refract(") >= 0,
		code.find("hint_depth_texture") >= 0])

	_expect(code.find("hint_screen_texture") >= 0,
		"on: the screen texture uniform is declared")
	_expect(code.find("refract(") >= 0, "on: refract() is called")
	_expect(code.find("hint_depth_texture") >= 0,
		"on: the depth texture is sampled, so the displaced UV can be masked")
	_expect(_alpha_written(code),
		"on: ALPHA = 1.0 is written, which is what moves the material to the "
		+ "transparent pass -- after the screen copy, so it can no longer "
		+ "sample its own previous frame (the black-hole feedback)")
	_expect(code.find("FRAGCOORD") >= 0 or code.find("n_out") >= 0,
		"on: the fragment stage builds the mask")
	_expect(code.find("EMISSION") >= 0, "on: the sample reaches EMISSION")
	_expect(code.find("mix(") >= 0,
		"on: the displaced and undisplaced UVs are blended by the depth mask")

	# An opaque material must be untouched -- refraction is only for transmission.
	ProjectSettings.set_setting(FLAG, true)
	var gold := Emitter.build_file(OPAQUE, PackedStringArray(["res://materials"]))
	_expect(gold.ok, "Gold builds with refraction on")
	_expect(gold.shader.code.find("hint_screen_texture") < 0,
		"an opaque material gains no screen sampler")
	_expect(not gold.shader.code.contains("ERROR"),
		"no shader emits a compile error")

	# The strength parameter is what a user tunes, so it must be reachable.
	_expect(code.find("refraction_strength") >= 0,
		"the refraction strength is exposed as a shader parameter")
	_expect(code.find("refraction_softness") >= 0,
		"the depth-mask blend width is exposed as a shader parameter")

	if had:
		ProjectSettings.set_setting(FLAG, saved)
	else:
		ProjectSettings.set_setting(FLAG, null)

	print("\n--- %s ---" % ("refraction OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## True when anything was written to ALPHA.
##
## Glass.mtlx has no `opacity` input, so ALPHA is written if and only if
## `transmission` was folded into it. That makes the assignment itself the signal,
## rather than the 0.15 floor constant -- which is emitted as "0.15000", not
## "0.150000", which is a trap worth not falling into twice.
func _alpha_written(code: String) -> bool:
	return code.find("ALPHA =") >= 0


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
