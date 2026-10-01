# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-09-30

### Removed

- **The thumbnail pipeline.** `.mtlx` files no longer bake or cache material
  previews, and the FileSystem dock shows the generic icon for one until you
  convert it. Gone with it: `mtlx_preview_generator.gd`,
  `mtlx_preview_baker.gd`, `mtlx_auto_baker.gd` and `mtlx_thumbnail.gd`, the
  dock's bake controls, and the `materialx/auto_bake_previews` and
  `materialx/preview_size` settings.

  It existed only because the editor does not know what a `.mtlx` is. Converting
  writes a `ShaderMaterial`, which the editor previews itself and correctly, so
  the pipeline was solving a problem the export path had already solved — and
  doing it twice: once on the CPU as an approximation that could not see materials
  whose colour comes from packed masks, then again on the GPU, with a cache, a
  watchdog and a failure backoff to keep it from spinning.

  The settings are dropped rather than left in place, because a setting that no
  longer reads anything looks configurable and is not.

  The dock's **live preview** stays. It is a different thing: it shows the
  converted shader for a material you are working on, before there is anything to
  export.

## [1.2.0] — 2026-09-30

### Changed

- **Convert now writes a `ShaderMaterial`, not a bare `VisualShader`.** The
  exported `.tres` loads straight onto a mesh's surface material override. A
  `VisualShader` cannot be dropped on a mesh, so before this every user who wanted
  a material had to build a container by hand for each one — tedious if a level
  editor is generating materials rather than authoring them.

  The converted shader is embedded as a sub-resource, so the file is
  self-contained. It is also larger than a bare shader resource, since a converted
  graph serialises in full.

### Fixed

- **Refraction was wired but inert.** `VisualShaderNodeInput` takes the built-in's
  lowercase key, not its GLSL spelling — `VisualShaderNodeInput::ports` carries
  both (`visual_shader.cpp:3341-3351`). `"Normal"`, `"View"` and `"ScreenUV"` missed
  the table, which is not an error: the node kept its default and the generated
  code showed `float n_out = 0.0;` where a `vec2` was meant. `NORMAL` and `VIEW`
  were both zero, `refract()` returned a zero vector, the offset was zero, and the
  screen texture was sampled at a constant corner pixel. Still default-off: the
  offset responds to `refraction_strength`, but at the shipped default of 0.02 the
  displacement is below what an 8-bit capture resolves.

## [1.1.0] — 2026-09-30

### Fixed

- **The custom light node multiplied by albedo twice.** Godot applies albedo
  after the light loop, not inside it (`scene_forward_clustered.glsl:3048`), so
  a material with a non-zero `diffuse_roughness` was rendering with its base
  colour squared. Rendering the node against Godot's own path measured it: a
  mean error of 0.024 per channel across the frame, against 0.006 once fixed.
  The node now follows Godot's structure, which also means ambient occlusion and
  the metallic blend must *not* be applied there — the renderer does both, and
  the node is inside the loop.

### Changed

- **Oren-Nayar diffuse is on by default**, and the setting is no longer called
  experimental. It was off by default *and* undocumented, which made a working
  feature invisible: no settings table entry, no README section, nothing but a
  dock checkbox nobody would think to look for.

  The lobe is MaterialX's own answer and Godot has no equivalent, so leaving it
  off silently rendered those materials with Lambert and dropped the roughness
  the file asked for. The Oren-Nayar term matches MaterialX's
  `mx_oren_nayar_diffuse` verbatim.

  `materialx/experimental_custom_lighting` becomes
  `materialx/custom_lighting`. An existing value is migrated on first load, so
  upgrading never silently changes how a project renders.

- The limitation that `diffuse_roughness` is dropped has been rewritten. It was
  accurate when the setting was off and wrong the moment it was on.

### Added

- A README section on what the Oren-Nayar path actually does, and what it costs:
  the material's lighting comes from this addon rather than from Godot, and
  ambient is not darkened by the directional albedo because Godot computes it in
  the fragment stage where a light function cannot reach it.
- `mtlx_config_check.gd`, guarding the new default and the key migration.
- `mtlx_light_equiv_check.gd`, which renders the node against Godot's own path
  and separates the diffuse and specular lobes by differencing two albedo
  values. This is what caught the double-albedo bug.
- `mtlx_gate_count.gd` and `mtlx_gate_diag.gd`, which show what the gate
  actually accepts and why, rather than asserting that it accepts everything.

## [1.0.0] — 2026-09-30

### Added (unreleased)

- **`sheen` → `RIM`, `sheen_color` → `RIM_TINT`.** Godot has both ports, and
  writing to them defines `LIGHT_RIM_USED`, so no material flag is needed.
  Sheen and rim are both grazing-angle lobes, so this is an analogue rather than
  an identity. `RIM_TINT` is a scalar (`mix(white, albedo, rim_tint)`), so a
  colour is reduced to one minus its Rec.709 luminance — white, the MaterialX
  default, correctly yields a no-op.
- **`hsvadjust` is implemented.** Previously reported as "not representable",
  which was wrong: `VisualShaderNodeColorFunc` already has `FUNC_RGB2HSV` and
  `FUNC_HSV2RGB`, so the node is four native nodes and no custom GLSL. Hue
  wrapping uses `fract`, as the spec requires. Affects 12 materials in the
  reference library.

First public release.

### Added

- **Direct `.mtlx` loading.** A `ResourceFormatLoader` makes `.mtlx` files load
  as `VisualShader` resources with no conversion step. Godot 4.7 registers
  `ResourceImporter` as abstract, so a format loader is the only script-level
  extension point available.
- **Material thumbnails.** `.mtlx` files show a shaded sphere in the FileSystem
  dock. Rendered on the GPU from the actual converted shader, with a CPU
  approximation as a fallback for previews the editor requests before a bake
  exists.
- **Automatic thumbnail baking.** `MtlxAutoBaker` renders stale materials in the
  background, one per frame, on load and on change.
- **Preview cache management.** The on-disk thumbnail cache is invalidated after
  every bake, plus **Rebuild all previews** / **Delete all previews** buttons.
  Without this, a baked thumbnail never appears, because the cache is keyed on
  the file's MD5.
- **Batch conversion** to `.tres`, which is the supported path for exported
  builds.
- **Texture import repair.** Infers each texture's role (colour, normal, data)
  and applies the matching import settings — sRGB decoding for colour maps,
  BC5 compression for tangent-space normal maps.
- **Live preview** panel showing the real converted shader on a sphere.
- **Project settings** under `materialx/`: texture roots, auto-bake, preview size.
- **Demo project** and a 14-script test suite, including one that reproduces the
  auto-bake runaway and one that checks `mix()` polarity against a fixture.

### Fixed

Seven conversion errors were found and fixed against the MaterialX and Godot
sources rather than by eye. Details and citations are in
[`addons/materialx/README.md`](addons/materialx/README.md).

- **Specular reflectance was 4× too strong** on 254 of 277 materials. MaterialX
  builds F0 from a physical IOR; Godot's specular port is quadratic in its input,
  so the port value is `sqrt(F0 / 0.16)`.
- **`mix()` polarity was inverted** on every blend. MaterialX's `mix(fg, bg, t)`
  is the reverse of GLSL's `mix(A, B, T)`, so `bg` must reach port A.
- **Normal maps were never sampled.** They were emitted as `vec3(1, 1, 1)`,
  making every normal-mapped material read as flat.
- **Normal map decoding ignored Godot's `xy*2-1` convention** for flat inputs.
- **Parameter name collision** with the locals `VisualShaderNodeColorOp` emits.
- **`opacity`** now converts through Rec. 709 luminance; **`transmission`** folds
  into `ALPHA`.
- **Metals rendered black** with no environment configured. Not a conversion
  bug: a metal has no diffuse response, so it needs something to reflect.

### Fixed during hardening

- **Auto-bake could run forever.** A material whose bake failed was never marked
  baked, so it stayed in the stale set and the periodic re-check re-queued the
  whole library on every pass, indefinitely. Failed materials now back off for
  two minutes, cleared early if the file changes.
- **A wedged bake could stop baking silently.** If the bake coroutine errored
  mid-flight, the busy flag was never cleared, so the queue never advanced while
  still reporting as running. A watchdog now releases it.
- **Nested `<image>` elements were not reported as dependencies.**
  `MtlxDocument.elements` holds top-level nodes only, so an image inside a
  `<nodegraph>` was invisible to the editor, which would not reload the material
  when that texture changed.
- **Dependencies were resolved twice per query** — a full shader conversion
  followed by a re-parse. Texture resolution is now a single shared function, so
  the loader and the emitter cannot disagree about which file a material uses.
- **`MtlxRuntime` was documented but never existed.** The format loader's docs
  promised a runtime class; an exported build has no editor and therefore no
  plugin, so `.mtlx` does not load at runtime. The docs now point at `.tres`
  conversion, which is the real answer.

[1.0.0]: https://github.com/auRose94/godot-materialx-loader/releases/tag/v1.0.0
