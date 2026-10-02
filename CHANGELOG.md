# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] — 2026-10-01

### Added

- **Transparent materials render both faces and cast shadows.** Every
  material whose conversion writes ALPHA now carries `cull_disabled`, and
  `depth_prepass_alpha` as well — unless the material reads the screen buffer
  for refraction — so the back wall of a shell shades and the shadow the
  engine used to skip for any ALPHA-writing material returns, cut where ALPHA
  drops below 0.1 in the shadow passes. The render modes reach the shader
  through VisualShader's dynamic `modes/`/`flags/` properties (no class API
  exists) and survive the .tres round trip. On the corpus, `Chains` and
  `Perforated_Metal` gain the shadows; the two refraction materials (`Glass`,
  `Semitransparent_Silicone`) keep `cull_disabled` only, because they also
  join the opaque pass there and Compatibility has no colour-pass guard for a
  surface on both lists — a prepass made the glass rasterise into its own
  screen sample, the black hole again. The engine's own refraction casts no
  shadow either.

### Fixed

- **Screen-space refraction compounded its own output into a "black hole with a
  disk".** A material that reads the screen but writes no ALPHA stays in the
  opaque pass, and the renderer copies the screen texture *after* that pass —
  so during the draw the sampler still held the previous frame's copy, which
  contains the object itself. Every frame the surface re-absorbed an image of
  itself: sky leaked inward from the silhouette and compounded into a glowing
  ring, while the centre kept re-sampling its own dark body. The fix mirrors
  Godot's own `BaseMaterial3D` refraction (material.cpp, FEATURE_REFRACTION):

  - `ALPHA = 1.0` is written unconditionally, which moves the material to the
    transparent pass, after the screen copy — no feedback.
  - The surface dims by the amount of background it shows
    (`ALBEDO *= 1 - background`), and the sample is *added* to EMISSION.
    Stacking a fully lit surface and a full background sample was the halo.
  - The displaced UV is masked against the depth buffer (engine parity): a
    foreground object crossing the sample no longer reads as background. The
    engine reconstructs view-space Z through a matrix; here the same decision
    is made by comparing raw window depths, which needs no matrix nodes — with
    the sign that Godot 4.3+'s reversed-Z depth buffer requires (the opaque
    pass clears depth to 0.0). The blend width is the `refraction_softness`
    parameter.
  - The screen sample is blurred by roughness (`textureLod`, ROUGHNESS × 8),
    engine parity, so rough glass blurs what it shows.
  - The offset now follows the refracted ray's perspective slope (xy divided
    by −z), so it no longer collapses at grazing angles; magnitude still
    ignores the focal length and remains tuned by `refraction_strength`.
  - `opacity` participates as `1 − opacity × (1 − transmission)`, the shape
    the engine reaches with `ref_amount = 1.0 - albedo.a`.

  Glass now renders as a lens — see the refraction render test, which measures
  the background actually moving — and the transmission no longer needs the
  0.15 alpha floor on this path.

- **The custom light node built the dielectric F0 from the wrong quantity.**
  A light function has no built-in for the material's SPECULAR port
  (`SPECULAR_AMOUNT` is the *light's* specular), and the node computed
  `0.16 × SPECULAR_AMOUNT²` — F0 0.16 regardless of the material, four times
  too reflective for a standard dielectric. The node now takes the port value
  as an input, fed through the same uniform the fragment's SPECULAR port reads
  (a `ParameterRef` shares the uniform without redeclaring it), or through the
  same chain re-emitted in the light stage for a graph-driven specular.

- **f90 was computed from one channel.** Godot clamps
  `dot(f0, vec3(50.0 × 0.33))` — the channel *sum*; the node used only `f0.g`,
  which dimmed the Fresnel peak on dielectrics by up to a third.

- **The custom light node's backlight term was Godot 3's formula.** Godot 4
  adds `(1/π − diffuse_brdf_NL) × backlight`; the node had the wrap-lighting
  form from the previous engine. Dead code today (nothing writes BACKLIGHT),
  corrected to keep the transcription honest.

### Changed

- **`sheen` on the custom-lighting path is now MaterialX's actual sheen lobe**
  (Imageworks, `mx_microfacet_sheen.glsl`, verbatim), replacing the
  `sheen → RIM` approximation for materials the light node takes over: weight,
  `sheen_roughness` and `sheen_color` feed the node, and the base diffuse is
  dimmed by the lobe's directional albedo the way MaterialX's `<layer>` stacks
  it. The RIM fallback remains for materials without `diffuse_roughness`, and
  its README entry now records what it looked like: Godot's rim paints a wide
  white ring around every face of a dark fabric — the other half of the
  "black hole" reports.

  The gate admits sheen materials when their inputs are representable in the
  light stage (literals, uniforms, or node chains the stage can host) and
  still refuses them otherwise; it has not got weaker.

  On the corpus this takes `diffuse_roughness` from "dropped on 33 materials"
  to "evaluated on 23", and `sheen_roughness` from dropped to used.

- **The custom-lighting equivalence test now actually exercises the node.**
  Writing the sigma-0 variant to exactly 0.0 made the gate refuse the material,
  so both renders were Godot's own lighting and the delta was zero by
  construction — which is how the F0 bug above survived. The variant is now
  written at 0.0001 (within 1e-7 of Lambert, but non-default), and a second,
  specular-sensitive comparison (a dielectric with a broad, centred highlight)
  asserts the dielectric directly. With the fixes, both lobes measure below
  the test's quantisation floor; reintroducing the old F0 measures +0.089.

- The demo environment's sun disk shrank from 45° to 8°. A sun that broad read
  as a halo around anything in front of it, which is what the README preview
  showed.

- Corpus and gate tests accept the library directory after `--`, as the README
  always claimed they did. The hero shot finds the repo and the demo relative
  to its own script instead of a stale mount path, and takes `--out=`.

### Fixed (test infrastructure)

- `_fop` connected every operand from output port 0, ignoring the port a Ref2
  carried. The refraction mask read `FRAGCOORD.x` where `FRAGCOORD.z` was
  meant and closed everywhere; anything else feeding a non-zero port (an
  expanded texture channel, a decompose output) silently took the wrong one.
- Parameters shared across stages are now declared once, by an owner, and
  referenced elsewhere through `ParameterRef` — two `Parameter` nodes with one
  name emit two `uniform` declarations and fail to compile.
- Every input of the custom light node is wired explicitly, because a
  script-constructed `VisualShaderNodeCustom` never gets its port defaults
  filled in and an unconnected input compiles to an empty expression.

### Added (unreleased, 1.4.1)

- **The batch converter now refuses to save a shader that does not compile.**
  An update cycle where the editor kept running an older copy of the addon
  scripts (the editor caches scripts until the project reloads) once wrote 22
  `.tres` whose embedded light node had unwired inputs ("`max(, 0.0)`"); the
  materials then failed to compile and the mech scene rendered the sky through
  their surfaces as glowing white blotches. Two guards now exist: the emitter
  verifies its light-stage wiring after building and falls back to Godot's own
  lighting with a report note, and the dock checks the generated code for the
  failure signature before saving. If the dock ever reports *stale addon
  scripts*, reload the project and reconvert.
- Headless conversions (outside the editor) do not get the editor's
  UID-for-path callback, so an overwritten `.tres` gets a fresh `uid://` even
  though scenes may reference the old one. If you convert from a script,
  re-check the `.tres` headers or let the editor rescan.
- **The dock's source folder is remembered, per project.** The dock re-suggested
  a folder from a FileSystem scan on every launch, so a project whose materials
  live anywhere but the first folder found had to retype the path each session.
  A `materialx/materials_folder` project setting now seeds the Source folder
  field, and the dock saves the field to it when you commit the text (Enter, or
  focus leaving the field). Empty means auto-detect, which is all a project that
  never touches the field ever gets — the setting exists only once you actually
  choose. Clearing the field returns the project to auto-detect, and a saved
  folder that no longer exists falls back to auto-detect rather than pointing
  the dock at nothing.
- **Project-wide conversion into one export folder.** The per-folder converter
  writes `.tres` next to each `.mtlx`, which scatters a converted library
  across the source tree and mixes the two. *Convert project to export folder*
  reads every `.mtlx` in the project — recursively, but never `res://addons`
  and never the export folder itself — and writes them **flat** into
  `materialx/export_path` as `<basename>.tres`: one folder of `ShaderMaterial`s
  the FileSystem dock previews by itself, browsable without a single `.mtlx`
  source mixed in. Duplicate basenames (two `Iron.mtlx` in different folders)
  get a numbered suffix (`Iron-2.tres`) in sorted scan order rather than one
  silently overwriting the other. Dry runs log the full source-to-target map
  and write nothing; the export folder is its own per-project setting,
  committed and saved like the source folder.

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
