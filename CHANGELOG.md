# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
