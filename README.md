# MaterialX Loader for Godot

Load [MaterialX](https://materialx.org) `.mtlx` files into Godot as
[Visual Shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html),

No C++ build. Copy the `addons/materialx` folder into your project and enable it.

![Nine converted MaterialX materials on spheres, rendered by Godot under a procedural sky](docs/preview.png)

*Nine `.mtlx` files converted and rendered unmodified: Gold, Glass, Rubber and
Grid_Paint in the top row, then Black Upholstery, Glazed Cube Pattern Tiles,
TH Blue Denim Fabric, Gold Foil and Perforated Metal. Every material on this
page went through the same converter — tiling normal maps, height, clearcoat,
sheen and all.**

---

## What it does

Drop a `.mtlx` file anywhere in your project and it becomes a `VisualShader`:

- **Loads directly.** `load("res://art/Bricks.mtlx")` returns a `VisualShader`.
  No import step, no manual conversion.
- **Correct conversion.** Specular reflectance, `mix()` polarity, sRGB handling
  and tangent-space normal maps are converted against the MaterialX and Godot
  specs rather than by eye. Seven of those conversions were silently wrong
  before; the reasoning is in
  [`addons/materialx/README.md`](addons/materialx/README.md).
- **Batch conversion.** Convert a whole folder to `.tres` and repair the import
  settings of the textures those materials use.
- **Live preview.** Pick a material, see the actual converted shader on a sphere.

## Requirements

Godot **4.7**. Verified against 4.7.2.stable. Earlier 4.x releases are not
claimed, because the port indices and enum values this relies on have moved
between minors.

## Install

1. Copy `addons/materialx/` into your project's `addons/` folder.
2. Enable **MaterialX Loader** in *Project → Project Settings → Plugins*.

That is the whole setup. Textures are resolved relative to the `.mtlx` file, so
an unpacked MaterialX library works with no further configuration.

## Project settings

All optional; the defaults work with no configuration.

| Setting | Default | Meaning |
|---|---|---|
| `materialx/texture_roots` | `[]` | Extra directories to search for textures, tried before the `.mtlx`'s own directory. Leave empty for relative-to-source resolution. |
| `materialx/custom_lighting` | `true` | Evaluate `diffuse_roughness` with an Oren-Nayar lobe — and `sheen` with MaterialX's actual sheen lobe — inside a custom light function. On by default because those lobes are MaterialX's own answer and Godot has no equivalent; turning it off falls back to Godot's Lambert and rim. See [Oren-Nayar diffuse](#oren-nayar-diffuse) for what this costs. |
| `materialx/screen_space_refraction` | `false` | Render `transmission` as real refraction of the scene behind the surface, instead of fading it out with `ALPHA`. The surface joins the transparent pass, dims itself by the amount of background it shows, and the displaced sample is masked against the depth buffer. Tunables per material: `refraction_strength` (offset size) and `refraction_softness` (mask blend width). |
| `materialx/materials_folder` | `""` | The folder the dock's Source folder field starts on. Empty auto-detects a folder holding `.mtlx` files; the dock saves the field here when you commit it (Enter, or clicking elsewhere), so the next session reopens on your choice. Clearing the field returns to auto-detect. |

Materials with a non-zero `diffuse_roughness` have Godot's whole lighting model
replaced in the light stage, so for those the addon, not the engine, is
responsible for the result. If you would rather have Godot's own BRDF, that
setting is the escape hatch.

`materialx/custom_lighting` was `materialx/experimental_custom_lighting` and
defaulted to off before 1.1.0. An existing value is migrated on first load, so
upgrading never silently changes how your materials render. Dead keys from
removed features (`auto_bake_previews`, `preview_size`, the old lighting key)
are dropped from `project.godot` on first load.

## Using the dock

The dock appears on the right-hand side of the editor. It defaults to
**preview only**, so nothing is written until you ask for it.

The **Source folder** both buttons work from is remembered per project: the
field starts on the saved choice (or auto-detect), and committing an edit —
Enter, or clicking elsewhere — saves it, so the dock reopens where you left it.

- **Convert .mtlx to .tres** — batch-convert a folder. This is the path to use
  for an exported build (see below).
- **Repair texture imports** — fix the import settings of the textures a
  material references. A colour map used as `base_color` needs sRGB decoding; a
  tangent-space normal map needs BC5 compression. Getting these wrong makes
  materials look subtly flat or washed out.

## Exporting

An exported game has no editor and therefore no plugin, so **`.mtlx` will not
load at runtime**. Run **Convert .mtlx to .tres** and ship the generated
`.tres`, which is what a build should use anyway: it moves the conversion cost
out of load time.

Each `.tres` is a **`ShaderMaterial` with the converted `VisualShader` embedded**
in it, not a bare shader. That is deliberate: a `VisualShader` is not something you
can drop on a mesh, so every user would otherwise have to hand-build a
`ShaderMaterial` per material just to hold it. As exported, the file loads
straight onto a `MeshInstance3D`'s **Surface Material Override**, which is what a
level editor wants.

The shader is embedded rather than referenced, so the file is self-contained and
carries no path back to the `.mtlx`. The trade-off is size: a converted graph is
serialised in full, so these files are considerably larger than a bare shader
resource.

Note that `ShaderMaterial` has exactly three properties in Godot 4.7 — `shader`,
`render_priority` and `next_pass` (`material.cpp:491-540`). `cull_mode`,
`depth_draw_mode` and the depth-prepass flags all live on `BaseMaterial3D`, which
is not a substitute here: it has its own BRDF and **no `shader` property at all**,
so a `VisualShader` cannot be attached to one.

## Metals look black

Not a conversion bug. A metal has no diffuse response — all of its appearance is
reflection — so with nothing configured to reflect, gold and chrome render as
near-black silhouettes with a single specular dot.

Give the project an environment (`Project → Project Settings → Rendering →
Environment → Default Environment`). Any sky or IBL works; the demo project
ships one.

## Bright white gloss that only shows in the editor

If converted metals bloom into radioactive-looking white patches on their
undersides and edges in the editor but render normally at runtime, the light
doing it is the scene's own: a directional light set to **Only baked**
(`light_bake_mode = 1`) lights the editor viewport for preview, while a mesh
without lightmap data ignores it in a running game. Check the imported scene's
lights before suspecting the conversion. Blender-imported lamps also map
wattage straight to `light_energy`, so a kilowatt lamp lands at a very high
energy — sanity-check any OmniLight3D that imports with energy far above 1.0.

Three knobs, all project-level, none related to this addon:

- **Environment → Glow → HDR Threshold** (default 1.0) — raise it (e.g. 1.5–2.0)
  so only true HDR sources bloom, not the polished gloss of a bright horizon.
- **Environment → Glow → Strength** — scale bloom back (e.g. 0.6).
- The plates' own `specular_roughness` in the source `.blend` — a near-zero
  value is what turns sunglare into a disk; authored polish is physics, not a
  bug, and the converter reproduces it on purpose.

## Oren-Nayar diffuse

Godot's spatial BRDF has no Oren-Nayar diffuse, so a MaterialX material with a
non-zero `diffuse_roughness` would be rendered with Lambert and quietly lose the
roughness the file asked for. This addon evaluates the lobe instead, by
transcribing Godot's lighting into a light function with the Oren-Nayar term in
place of Lambert. The same node carries MaterialX's *sheen* lobe
(Imageworks, `mx_microfacet_sheen.glsl`, verbatim) for materials it takes over,
so a dark fabric keeps its velvet response instead of Godot's white rim — and
its base diffuse is dimmed by the sheen's directional albedo, the way
MaterialX's `<layer>` stacks it.

The transcription is Godot's, not a reimplementation: `D_GGX`, `V_GGX`,
`SchlickFresnel`, the energy-compensation term and the backlight lobe are taken
from `scene_forward_lights_inc.glsl` and `scene_forward_clustered.glsl`, so the
material still tracks the engine when the engine changes. The substituted terms
are

```glsl
float sigma2 = mx_square(diffuse_roughness);
float A = 1.0 - 0.5 * (sigma2 / (sigma2 + 0.33));
float B = 0.45 * sigma2 / (sigma2 + 0.09);
diffuse_brdf_NL = (A + B * stinv) * NdotL / M_PI;
```

which is MaterialX's `mx_oren_nayar_diffuse` verbatim
(`mx_microfacet_diffuse.glsl:8`). The dielectric F0 comes from the material's
SPECULAR port through a shared uniform, exactly as `F0(metallic, specular,
albedo)` consumes it on Godot's own path; the only knowingly approximate piece
is the DFG energy-compensation term, which a light function cannot sample and
which is therefore taken from Filament's analytic fit of the same quantity —
verified against the engine's own integration, and now indistinguishable from
the texture at the test's quantisation floor.

Two consequences worth knowing:

- **The material's lighting comes from this addon, not from Godot.** Writing to
  the light stage sets `LIGHT_CODE_USED`, which makes the engine skip its entire
  lighting model (`scene_forward_lights_inc.glsl:121`). Anything the
  transcription does not cover disappears without an error, which is why the
  gate in [Known limitations](#known-limitations) refuses a material with lobes a
  light function cannot read rather than rendering half of it.
- **Ambient is not darkened to match.** MaterialX scales indirect diffuse by the
  directional albedo; Godot computes ambient in the fragment stage, where the
  light function cannot reach it. On a high-`diffuse_roughness` material the
  ambient reads slightly too bright relative to the direct light.

Set `materialx/custom_lighting` to `false` to fall back to Godot's own BRDF.

`subsurface` is **not** on that list. Godot's scattering is a compute pass over the
diffuse buffer, and `SSS_STRENGTH` is written outside the `LIGHT_CODE_USED` guard, so a
subsurface material keeps its scattering even when a light function replaces the
engine's lighting.

A note on reading the numbers: a material on this path renders **darker than Godot's
Lambert on purpose** when `diffuse_roughness` is high. At 1.0 the lobe spans 0.624 to
1.037, because a rough diffuse surface reflects less head-on and sends the rest toward
grazing angles. Measured across the library, `Rubber` goes from 0.046 to 0.135 and
`Cream_Onyx` from 0.353 to 0.326. That is the material doing what its file asked for, not
a fault. The invariant that has to hold is the one at `diffuse_roughness = 0`, where the
term is exactly 1.0 and the custom path reproduces Godot to within measurement noise --
which is what `mtlx_light_path_check` asserts.

## Known limitations

These are honest limits of the conversion, not bugs. They are all detected and
reported in the dock rather than silently approximated.

| Input | Why it is dropped |
|---|---|
| `transmission_depth`, `transmission_scatter`, `transmission_dispersion` | With `materialx/screen_space_refraction` on, `transmission` refracts the screen texture: the surface joins the transparent pass, dims itself by the amount of background it shows, and the displaced sample is depth-masked, blurred by roughness, and tinted by `transmission_color`. The offset follows the refracted ray's perspective slope; its magnitude ignores the focal length and is tuned by the `refraction_strength` parameter, with the mask blend width on `refraction_softness`. Volume absorption (depth, scatter) has no screen-space equivalent. Transparent objects behind the glass are not in the screen copy, so they do not show through it. With the setting off, `transmission` becomes `ALPHA` (`max(1 - transmission, 0.15)`), which shows the background without displacing it. |
| `diffuse_roughness`, when computed rather than written as a literal | Oren-Nayar can only be evaluated in the light stage, and a value computed in a nodegraph has to be a constant there. It is dropped, and the material keeps Godot's Lambert. Set the value directly and it works. |
| The *indirect* half of Oren-Nayar | MaterialX also scales ambient diffuse by the directional albedo (`mx_oren_nayar_diffuse_bsdf.glsl:34`). Godot computes ambient in the fragment stage, outside the light function, so a material with a high `diffuse_roughness` keeps an ambient term that is not darkened to match its direct light. Affects only materials the setting actually reaches. |
| `diffuse_roughness` material that also has `coat` or anisotropy | Those lobes are not readable from a light function at all, so the material keeps Godot's whole lighting rather than half of it. Reported in the dock when it happens. A `sheen` material is *not* refused: the light node carries MaterialX's sheen lobe, provided the sheen inputs are representable in the light stage (literals, uniforms, or node chains it can host) — otherwise the material is refused too. |
| `subsurface_color`, `subsurface_radius`, `subsurface_scale`, `subsurface_anisotropy` | Godot's scattering is driven by a single strength. `SSS_TRANSMITTANCE_COLOR`, `_DEPTH` and `_BOOST` are registered as fragment built-ins but are not writable output ports, so a material cannot say what colour its scatter is or how far it travels. The `subsurface` weight itself does work and reaches `SSS_STRENGTH`. |
| `coat_color` | Godot's clearcoat has no tint port. |
| `coat_IOR` | Godot hardcodes the coat IOR at 1.5. |
| `sheen_roughness` | Godot's rim has no roughness term; its exponent comes from the surface roughness instead. |

Deliberately approximated rather than dropped, because a partial match beats
nothing — these apply to materials *without* `diffuse_roughness`; on the
custom-lighting path sheen is the real lobe:

| Input | How it is approximated |
|---|---|
| `sheen` | Mapped to Godot's `RIM`. Both are grazing-angle lobes, so it is a close analogue, not an identity: MaterialX's sheen is retroreflective and roughness-dependent, Godot's rim is fresnel-weighted with an exponent taken from the surface roughness. On a dark fabric the rim reads as a wide white ring around every face of the mesh — the correct lobe, on the custom-lighting path, is the fix for that. |
| `sheen_color` | Mapped to `RIM_TINT`, which is a scalar (`mix(white, albedo, rim_tint)`). The colour is reduced to "how far from white", i.e. one minus its Rec.709 luminance, so white — the MaterialX default — is a no-op. Hue is lost: two sheens of equal brightness land on the same tint. On the custom-lighting path `sheen_color` feeds the real lobe instead, and no approximation happens. |

Other limits:

- A `.mtlx` exporting several `<surfacematerial>` nodes converts only the first.
- The parser handles the subset of MaterialX the loader needs. It does not
  validate against the MaterialX spec; that is what linking libMaterialX buys.
- MaterialX's `colorspace` is read as an annotation on a file input, which is
  how the standard library writes it.

## Validation

The converter was developed against the MaterialX standard library: **277
`.mtlx` files, all converting with 0 failures, 0 shader errors and 0 dangling
connections.** Reproduce it against your own library:

```bash
cd demo
godot --headless --script tests/mtlx_corpus_check.gd -- res://path/to/materials
```

GPU-backed checks -- the live preview, the equivalence render, the refraction
displacement -- need a framebuffer, and headless has none:

```bash
cd demo
xvfb-run -a godot --rendering-driver opengl3 --resolution 800x600 \
    --script tests/mtlx_refraction_render.gd
```

## Demo

`demo/` is the test harness and a working example: four materials covering three
conversion routes -- a pure metal, a normal-mapped surface, an sRGB colour
texture, and a transmissive glass. Run **Convert .mtlx to .tres** to see them
in the FileSystem dock, where the editor renders a preview of each material
itself.

```bash
godot --path demo
```

`demo/addons/materialx` is a **symlink** to `../addons/materialx`, so the addon
lives in exactly one place and cannot drift out of sync with the copy under
test. On Windows, clone with symlink support (`git clone --config
core.symlinks=true`) or enable Developer Mode; otherwise the demo's addon
will be a broken link. The addon itself needs no symlinks -- only the demo
does.

## License

MIT — see [LICENSE](LICENSE).
