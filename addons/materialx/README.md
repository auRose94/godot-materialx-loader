# MaterialX Loader

Loads MaterialX `.mtlx` files into Godot as Visual Shaders.

This file is the technical reference: why each conversion is the way it is,
with sources. For installation and everyday use see the
[repository README](../../README.md).

Two ways to use it:

* **Directly** — `load("res://materials/Aluminum.mtlx")` returns a `VisualShader`.
  No conversion step, no intermediate files.
* **Batch** — the editor dock converts a folder of `.mtlx` to `.tres` and reports
  what could not be represented.

Targets **Godot 4.7**. Verified against 4.7.2-stable (`ed1daf0bf`).

---

## Install

The plugin is already enabled in `project.godot`. To enable it by hand:
**Project → Project Settings → Plugins → MaterialX Loader**.

## Use

The dock appears on the right-hand side. It defaults to **preview only**, so
nothing is written until you untick that.

* **Convert .mtlx to .tres** — writes a `ShaderMaterial` as `<name>.tres` next
  to each `.mtlx`, ready to drop on a mesh.
  This **overwrites** any existing conversion, so point the dock at a scratch
  folder first if you want to keep the old ones to diff against.
* **Repair texture imports** — fixes the `.import` settings of the textures the
  `.mtlx` files reference (see below).
* **Live preview** — pick a material and see the *converted shader* rendered on a
  sphere. This is the accurate view; see below.

The Source folder is remembered per project
(`Project Settings → materialx/materials_folder`): the dock reopens on the last
committed value, and an empty field means auto-detect again.

## Previews

One mechanism: `MtlxLivePreview` puts the converted shader on a sphere in a
SubViewport and lets the engine render it. That is exactly what a scene shows, so
it is the right tool for comparing against reference renders, and it is what the
dock uses for the material you have selected.

There is deliberately **no FileSystem thumbnail generator.** There used to be one:
a CPU sphere renderer as a fallback, a GPU baker that preferred the real render,
a periodic timer, an on-disk cache and a failure backoff, all so a `.mtlx` would
show a material ball in the FileSystem dock. It existed because the editor does
not know what a `.mtlx` is.

Converting writes a `ShaderMaterial`, which the editor previews itself and
correctly. So the pipeline was doing the same job twice -- once approximately on
the CPU, then properly on the GPU -- to produce something the export path already
produced for free. Until a `.mtlx` is converted it shows the generic icon.

## What changed, and why it matters

Counts below were measured against the MaterialX standard library as it stands
in this workspace: **277 `.mtlx` files**. Re-derive them with
`tests/mtlx_corpus_check.gd`.

### 0. Metals were black, because the project had no environment

This is the single biggest thing separating these materials from their reference
renders, and it is **not** a shader bug.

A metal has no diffuse response: all of its appearance is reflection. With no
environment configured there is nothing for it to reflect, so gold, copper and
chrome render as near-black silhouettes with only a specular dot from the direct
lights.

`environment/default_environment.tres` now exists and is wired up in
`project.godot`. It uses a `ProceduralSkyMaterial` with near-neutral greys, giving
image-based lighting without needing an HDRI in the project and without tinting
every material.

Measured on a 128px preview sphere, before and after:

| material | no environment | with sky |
|---|---|---|
| Gold | 0.035 / 0.036 / 0.040 (black) | **0.354 / 0.308 / 0.198** |
| Nickel | 0.149 / 0.130 / 0.129 | 0.191 / 0.179 / 0.182 |

Reproduce with `tools/mtlx_live_check.gd` under `xvfb-run`. It needs a real GPU:
headless Godot uses the dummy renderer, whose SubViewport has no framebuffer.

### 1. Transparent materials rendered opaque

`Glass.mtlx` is transparent in MaterialX because of `transmission = 1`, not
`opacity` — it does not set `opacity` at all, so that stays at its opaque white
default. Godot's spatial shader has no refraction lobe, so nothing was wired and
glass came out solid.

Two paths now exist, chosen by `materialx/screen_space_refraction`.

**Off (default):** transmission folds into `ALPHA` as `1 - transmission`. Two
details:

* MaterialX reduces `opacity` to its **luminance** before using it (`luminance`
  then `extract` in `libraries/bxdf/standard_surface.mtlx`), so the converter
  does the same instead of taking the red channel.
* A pure `1 - transmission` would give clear glass alpha 0 — completely
  invisible. Since Godot cannot refract, `TRANSMISSION_ALPHA_FLOOR = 0.15` keeps
  specular highlights visible, which is what sells it as glass. That constant is
  an approximation, not physics.

**On:** the surface refracts the screen texture, following the recipe of Godot's
own `BaseMaterial3D` refraction (`material.cpp`, FEATURE_REFRACTION):

* `ALPHA = 1.0` is written unconditionally — the engine's comment is "Force
  transparency on the material (required for refraction)". Writing ALPHA moves
  the material to the transparent pass, which renders *after* the screen copy,
  so the copy no longer contains the object. The first version of this path
  stayed opaque, sampled the previous frame's copy of itself, and compounded
  that into a black disc with a glowing ring — a black hole with an accretion
  disk.
* The surface dims by the amount of background it shows
  (`ALBEDO *= 1 - background_w`, with `background_w = 1 - opacity ×
  (1 - transmission)`), and the sample is added to EMISSION. Stacking a fully
  lit surface and a full background sample was the halo.
* The displaced UV is masked against the depth buffer, blended over
  `refraction_softness` raw window-depth units, so a foreground object crossing
  the sample does not pop in as background. Godot 4.3+ uses a reversed-Z depth
  buffer in every renderer, so "farther than me" is a *smaller* raw value — the
  comparison is fragment depth minus sample depth. Getting this backwards
  closes the mask everywhere and the strength knob does nothing, which is how
  the test caught it.
* The screen sample is blurred by roughness (`textureLod`, ROUGHNESS × 8) —
  frosted glass, engine parity.
* The offset follows the refracted ray's perspective slope (xy over −z), so it
  survives grazing angles; magnitude ignores the focal length and is tuned by
  the `refraction_strength` parameter.
* The engine multiplies the sample by `EXPOSURE` (the scene's emissive exposure
  normalisation reaches everything else the fragment adds); the node graph reads
  the same built-in.

Affects `Glass.mtlx` and `Semitransparent_Silicone.mtlx`. `Chains.mtlx` and
`Perforated_Metal.mtlx` instead use an opacity mask.

### 2. Specular reflectance was 4x too strong on 254 of 277 materials

MaterialX `standard_surface` builds its dielectric from a **physical IOR**:

```
F0 = ((ior - 1) / (ior + 1))^2
```

(`MaterialX 1.39`, `libraries/pbrlib/genglsl/lib/mx_microfacet_specular.glsl:184`,
`mx_ior_to_f0`)

Godot's spatial output takes a **scalar artistic port** whose internal dielectric
term is quadratic in that port:

```
dielectric = 0.16 * SPECULAR * SPECULAR
```

(`Godot 4.7.2`, `servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl:82`)

So the correct conversion is a square root, not a copy:

```
F0        = ((ior - 1) / (ior + 1))^2 * specular * specular_color
SPECULAR  = sqrt(F0 / 0.16)
```

The previous converter passed MaterialX `specular` straight into the port. With
`specular = 1.0` — which **254 of the 277** files declare — that yields
`0.16 * 1^2 = 0.16` instead of `0.04`, i.e. **four times too reflective** on
91% of the library. Every dielectric in the set looked wetter and shinier than
the reference renders.

Measured (`tools/mtlx_specular_check.gd`):

| material | IOR | specular | F0 | SPECULAR (new) | port (old) | old F0 | error |
|---|---|---|---|---|---|---|---|
| Aluminum_Brushed | 1.50 | 1.00 | 0.0400 | 0.5000 | 1.00 | 0.1600 | **4.00x** |
| Aluminum | 1.45 | 0.50 | 0.0169 | 0.3247 | 0.50 | 0.0400 | 2.37x |
| Brick_Irregular | 1.50 | 1.00 | 0.0400 | 0.5000 | 1.00 | 0.1600 | **4.00x** |
| Gold | 1.45 | 0.50 | 0.0160 | 0.3160 | 0.50 | 0.0400 | 2.50x |

Because 7 files drive `specular_IOR` from the graph and 6 drive `specular_color`,
this is computed **in the shader**, not at conversion time. Constants fold to a
single adjustable parameter; only genuinely varying inputs get arithmetic nodes.

### 3. Normal maps were not being sampled at all

`normal` and `normalmap` both routed to a handler that emitted a constant
`vec3(1,1,1)`. Since Godot decodes `NORMAL_MAP` as
`xy = xy * 2 - 1` with a flat default of `vec3(0.5)`, that constant is a
strongly tilted normal, not a flat one — and the texture was never read.

Fixed: `<normalmap>` samples its texture and passes it through, and the texture
is declared `: hint_normal` so Godot decodes it as a normal (BC5/RGTC aware).
A bare `<normal>` now emits nothing, leaving `NORMAL_MAP` at Godot's flat
default, which is the correct result.

**243 of 277** materials now sample a real normal map; the other 15 drive it
through a Mix/VectorOp/VectorCompose because they genuinely blend normals.

### 4. Texture import settings

A roughness map imported with `compress/mode=2` is block-compressed **as colour**,
which throws away the precision those maps need. The repair step:

| usage | fix |
|---|---|
| colour (`baseColor`, `emission`) | `source_color=true` (sRGB decode) |
| data (roughness / metallic / AO / masks) | `compress/mode=3` (VRAM Uncompressed), `source_color=false`, `detect_3d/compress_to=1` |
| normal | `compress/normal_map=1` (BC5/RGTC), `source_color=false` |

Usage is inferred from MaterialX's `colorspace` attribute and whether the image
feeds a `<normalmap>` — not from the data type, since an sRGB base colour and a
linear ORM map can both be `type="color3"`.

### 5. Every `mix` node was inverted — this is what turned the bricks blue

MaterialX's `mix` is **not** GLSL's `mix`:

```
MaterialX   mix(fg, bg, t) = bg * (1 - t) + fg * t
Godot       mix(A, B, T)   = A  * (1 - T) + B  * T
```

Confirmed two ways in MaterialX 1.39: the node definition declares
`<output name="out" defaultinput="bg"/>` (`stdlib_defs.mtlx`), and
`mx_mix_bsdf` computes `mix(bg.response, fg.response, mixValue)`.

So `bg` must land on port A and `fg` on port B. The converter had them the
other way round, which complements **every** blend in the library (424 `mix`
nodes).

The visible symptom was the brick materials. `Bricks.mtlx` mixes a dark blue
grime colour over the brick:

```xml
<constant name="LeaksColor" type="color3">
  <input name="value" type="color3" value=" 0.036603, 0.050212, 0.112805" />
```

with the blend factor `mask.a * floor(mask.a + MaskSpread)`. The mask's alpha
runs 0.00–0.95 and `MaskSpread` is 0, so `floor(alpha)` is 0 and the factor is
0 — the source intends **brick**. Inverted, factor 0 returned `LeaksColor`
instead, and every brick rendered solid navy.

Note the source files are themselves questionable here: `MaskSpread = 0` means
the grime effect can never trigger, so the intended value was probably 1.0.
The converter now reproduces the file faithfully, which means brick rather than
blue — but if you want the grime, `MaskSpread` needs raising at source.

`overlay` was checked for the same class of error and was already correct
(Godot's ColorOp uses `base = input0, blend = input1`, and GLSLFX's overlay
treats `bg` as the backdrop). One real loss: Godot's ColorOp ignores MaterialX's
blend *amount*, so overlay is applied at full strength.

### 6. Shader parameters collided with Godot's generated locals

`VisualShaderNodeColorOp` emits locals literally named `base` and `blend`
(`modules/visual_shader/vs_nodes/visual_shader_nodes.cpp:2420`). A parameter named
`base` becomes `uniform float base`, and the shader fails to compile with
`Redefinition of 'base'`. MaterialX's `base` input is now renamed to `base_mx`
when it would collide; the full reserved list is in `mtlx_emitter.gd`.

---

## Honest limits

Godot's spatial shader has **one fixed metallic-roughness BRDF**. MaterialX
`standard_surface` is a layered Autodesk Standard Surface model. The graph is
reproduced exactly and every value that has a Godot equivalent is exact, but the
following have no representation at all. They are **reported per material**
rather than silently approximated — an input left at its MaterialX default is
not reported, since it costs nothing visually.

Current state across the 277 files:

| input | materials | why |
|---|---|---|
| `diffuse_roughness` | 10 (was 33) | feeds MaterialX's Oren-Nayar diffuse lobe, which the custom light node evaluates on 23 materials; the rest are refused by the gate (coat, anisotropy, or a computed value) |
| `subsurface_color` | 17 | Godot's SSS takes radius/depth, not a colour |
| `subsurface_radius` / `_scale` | 8 / 8 | Godot's SSS radius is per-object |
| `transmission_depth` / `_scatter` | 2 / 2 | no volume absorption in screen-space refraction |
| `sheen_roughness` | 0 on the custom path (the node takes it); 1 otherwise | Godot's rim has no roughness term |
| `coat_color` | 2 | Godot's clearcoat has no tint |
| `specular_rotation` | 2 | no anisotropy rotation on the output |
| `opacity` | 2 | wiring `ALPHA` would make every material transparent |
| `hsvadjust` | 12 | implemented: RGB2HSV/HSV2RGB are native ColorFunc functions |

`diffuse_roughness` is the one most likely to be visible: it is what makes rough
dielectrics (brick, concrete, fabric) look flat rather than shiny.

So "pixel perfect" against MaterialX reference renders is **not achievable** in a
Godot spatial shader. What this gets you is exact graph structure, exact textures
and channel routing, and exact values for everything Godot models — with the
remainder listed rather than guessed at.

## Known rough edges

* `Wood_Beech_Raw.mtlx` references `Wood_Beech_Raw_Mask.png` / `_Normal.png` but
  the files on disk are lowercase. This works on Windows/macOS and fails on
  Linux, so there is a case-insensitive fallback that logs what it resolved.
* ~~`hsvadjust` passes through unchanged~~ -- this was wrong. `VisualShaderNodeColorFunc` has `FUNC_RGB2HSV` and `FUNC_HSV2RGB`, so it is now implemented with four native nodes.
* A `.mtlx` exporting several `<surfacematerial>` nodes converts only the first.

---

## Layout

| file | role |
|---|---|
| `plugin.gd` | `EditorPlugin`; registers the loader and the dock |
| `mtlx_format_loader.gd` | `ResourceFormatLoader` so `.mtlx` loads as a `VisualShader` |
| `mtlx_document.gd` | XML → scoped element/input graph, with link resolution |
| `mtlx_value.gd` | MaterialX typed-value decoding |
| `mtlx_emitter.gd` | graph → `VisualShader` via `add_node` / `connect_nodes_forced` |
| `godot_map.gd` | every verified port index, enum and conversion, with sources |
| `mtlx_live_preview.gd` | GPU-rendered preview panel (real shader) |
| `mtlx_converter.gd` | the editor dock |
| `mtlx_texture_fixer.gd` | texture import-setting repair |

### Why a format loader and not an importer

Godot 4.7 registers `ResourceImporter` as **abstract**
(`core/register_core_types.cpp:293`), so a custom importer cannot be written in
GDScript. `ResourceFormatLoader` is registered concrete and
`ResourceLoader.add_resource_format_loader()` is exposed, which is what makes
direct `.mtlx` loading possible.

### Why the runtime API instead of writing `.tres` text

`VisualShader.add_node()` and `connect_nodes_forced()` are bound methods
(`modules/visual_shader/visual_shader.cpp:3185`, `:3202`), so the graph is built
through the engine and Godot owns serialisation. That removes a second
implementation of the `.tres` format that could drift. Two constraints worth
knowing: `add_node` rejects ids `< 2`, and node 0 is the implicit
`VisualShaderNodeOutput` — which is why output ports appear in a `.tres` only as
bare integers, never as `ALBEDO`/`ROUGHNESS` names.

## Tests

Run from the `demo/` project — the scripts preload each other through
`res://tests/`, so that is the project they must run in. A library in another
project can be checked without editing by passing its directory after `--` (an
absolute path works for conversion; rendering needs a GPU, see below):

```bash
cd demo
godot-mono --headless --script tests/mtlx_corpus_check.gd -- /path/to/library
```

| script | checks |
|---|---|
| `tests/mtlx_loader_check.gd` | `.mtlx` loads as a `VisualShader` |
| `tests/mtlx_mix_check.gd` | `mix` fg/bg polarity (the blue-brick bug) |
| `tests/mtlx_specular_check.gd` | specular conversion against each file's declared IOR |
| `tests/mtlx_corpus_check.gd` | whole library; dangling connections, missing textures, drops |
| `tests/mtlx_refraction_check.gd` | the refraction graph: screen + depth samplers, the ALPHA pass trick, the mask |
| `tests/mtlx_refraction_render.gd` | the background actually moves with `refraction_strength` (needs a GPU) |
| `tests/mtlx_light_gate_check.gd` | what the custom-lighting gate admits and refuses |
| `tests/mtlx_light_path_check.gd` | sigma≈0 equivalence against Godot's lighting, plus a specular-sensitive dielectric (needs a GPU) |
| `tests/mtlx_light_equiv_check.gd` | diffuse/specular error of the custom node, lobes separated by albedo differencing (needs a GPU) |
| `tests/mtlx_material_export_check.gd` | the written `.tres` round-trips as a ShaderMaterial with its graph intact |
| `tests/mtlx_fixer_check.gd` | import repair (dry run is side-effect free), save/load round trip |
| `tests/mtlx_dock_layout_check.gd` | dock minimum size, scrollability, preview visibility |
| `tests/mtlx_live_check.gd` | renders the live preview (needs a real GPU; see below) |
| `tests/mtlx_trace.gd` | one material's graph + generated code (`-- res://materials/X.mtlx`) |
| `tests/mtlx_hero_shot.gd` | renders the README contact sheet to `docs/preview.png` |

Current status: **277/277 convert, 0 shader errors, 0 dangling connections, 0
missing textures.**

One caveat on testing: `mtlx_live_check.gd` needs a real rendering device.
Headless Godot uses the dummy driver, whose SubViewport has no framebuffer, so
it reports `NO IMAGE` under `--headless`. Run it windowed (or under `xvfb-run`)
to exercise the GPU path.

## Later: a GDExtension

This is GDScript on purpose — no build step, so the semantic mapping could be
iterated against reference renders quickly. The converter is isolated in
`MtlxEmitter` + `GodotMap` with no Godot-editor dependencies, so it ports to C++
against `godot-cpp` + `MaterialXCore`/`MaterialXFormat` when a native build is
worth it, which would add spec validation and unit handling. Note that a
GDExtension must match the engine's float/double precision.