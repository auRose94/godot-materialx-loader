# MaterialX Loader for Godot

Load [MaterialX](https://materialx.org) `.mtlx` files into Godot as
[Visual Shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html),
with real material thumbnails in the FileSystem dock.

No C++ build. Copy the `addons/materialx` folder into your project and enable it.

![A converted MaterialX sphere in a Godot scene](docs/preview.png)

---

## What it does

Drop a `.mtlx` file anywhere in your project and it becomes a `VisualShader`:

- **Loads directly.** `load("res://art/Bricks.mtlx")` returns a `VisualShader`.
  No import step, no manual conversion.
- **Material thumbnails.** `.mtlx` files show a shaded sphere in the FileSystem
  dock instead of a generic icon.
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
| `materialx/auto_bake_previews` | `true` | Render thumbnails with the real shader in the background. |
| `materialx/preview_size` | `128` | Edge length in pixels of a baked thumbnail. |

## Using the dock

The dock appears on the right-hand side of the editor. It defaults to
**preview only**, so nothing is written until you ask for it.

- **Convert .mtlx to .tres** — batch-convert a folder. This is the path to use
  for an exported build (see below).
- **Repair texture imports** — fix the import settings of the textures a
  material references. A colour map used as `base_color` needs sRGB decoding; a
  tangent-space normal map needs BC5 compression. Getting these wrong makes
  materials look subtly flat or washed out.
- **Rebuild all previews** / **Delete all previews** — clear and regenerate every
  baked thumbnail.

### About thumbnails and restarting the editor

Godot caches each thumbnail in two places. The **on-disk** copy
(`~/.cache/godot/resthumb-<md5>.png`) is keyed on the file's MD5, so an
unchanged material keeps its old thumbnail indefinitely; the addon deletes that
entry after every bake, so this never needs doing by hand.

The **in-memory** copy is checked first and has no clearing API in 4.x. A
thumbnail already generated in the current session therefore shows the old image
until the editor restarts. Per-material refreshes appear to shift the mismatch
rather than fix it — use **Rebuild all previews** and restart once.

## Exporting

An exported game has no editor and therefore no plugin, so **`.mtlx` will not
load at runtime**. Run **Convert .mtlx to .tres** and ship the generated
`.tres`, which is what a build should use anyway: it moves the conversion cost
out of load time.

## Metals look black

Not a conversion bug. A metal has no diffuse response — all of its appearance is
reflection — so with nothing configured to reflect, gold and chrome render as
near-black silhouettes with a single specular dot.

Give the project an environment (`Project → Project Settings → Rendering →
Environment → Default Environment`). Any sky or IBL works; the demo project
ships one. Baked thumbnails use that same environment, so thumbnails and scenes
match.

## Known limitations

These are honest limits of the conversion, not bugs. They are all detected and
reported in the dock rather than silently approximated.

| Input | Why it is dropped |
|---|---|
| `diffuse_roughness` | Feeds MaterialX's Oren-Nayar diffuse lobe. Godot's spatial BRDF has no diffuse-roughness port. |
| `subsurface_color`, `subsurface_radius`, `subsurface_scale` | Godot's subsurface scattering takes a radius and depth per object, not a per-material colour and radius. |
| `coat_color` | Godot's clearcoat has no tint port. |
| `sheen`, `sheen_color`, `sheen_roughness` | No sheen lobe in Godot's spatial BRDF. |
| `transmission`, `transmission_depth`, `transmission_scatter`, `transmission_color`, `transmission_dispersion` | No refraction lobe in Godot's spatial BRDF. Folded into `ALPHA` (`max(1 - transmission, 0.15)`), which is an approximation. |
| `hsvadjust` | Not representable in Godot 4.7. Passed through unchanged rather than approximated. |

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

The suite finds `.mtlx` files automatically, so the argument is optional.

| script | checks |
|---|---|
| `tests/mtlx_corpus_check.gd` | every material: failures, dangling connections, missing textures, dropped inputs |
| `tests/mtlx_specular_check.gd` | specular conversion against each file's declared IOR |
| `tests/mtlx_mix_check.gd` | `mix()` fg/bg polarity — the inverted-blend bug |
| `tests/mtlx_dependency_check.gd` | textures are reported as dependencies, including inside nodegraphs |
| `tests/mtlx_loader_check.gd` | `.mtlx` loads as a `VisualShader` |
| `tests/mtlx_dock_layout_check.gd` | dock fits the panel and stays scrollable |
| `tests/mtlx_fixer_check.gd` | import repair is side-effect free; save/load round trip |
| `tests/mtlx_cache_tools_check.gd` | the preview-cache buttons and cache-key format |
| `tests/mtlx_autobake_check.gd` | auto-baker produces real renders (needs a GPU) |
| `tests/mtlx_baker_backoff_check.gd` | a failing material backs off instead of retrying forever |
| `tests/mtlx_thumb_check.gd` | CPU thumbnail rendering |

Most run headless. The two that render need a real driver, because the headless
dummy renderer has no framebuffer:

```bash
xvfb-run -a godot --rendering-driver opengl3 --resolution 800x600 \
    --script tests/mtlx_autobake_check.gd
```

## Demo

`demo/` is the test harness and a working example: four materials covering three
conversion routes -- a pure metal, a normal-mapped surface, an sRGB colour
texture, and a transmissive glass. Open it to see the thumbnails.

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
