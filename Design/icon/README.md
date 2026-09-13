# etcetera icon

The Poppins set from the icon handoff: Poppins Bold, converted to outlines. A
second, drawn set with the same layout was dropped.

## Files

| File | Use |
| --- | --- |
| `poppins-icon.svg` | The icon. Square, full bleed, gradient and glyphs only. |
| `poppins-icon-shaded.svg` | Same plus dome and floor shading, for flat contexts such as the README. |
| `poppins-icon-raster.svg` | Same, with the 4x4 raster faintly visible. |
| `poppins-icon-small.svg` | Reduced to `e.` for 32px and below. |
| `poppins-mark.svg` | Glyphs only, transparent, inherits `currentColor`. |
| `poppins-mark-small.svg` | Reduced mark, transparent. |
| `build_icon_poppins.py` | Generates the SVGs above. |
| `make_app_icon.py` | Splits `poppins-icon.svg` into the app icon's layers. |

Every file is a square 1024 canvas with no corner radius. macOS applies the
squircle and its Liquid Glass treatment itself, so baking a shape in would
produce a rounded icon inside a rounded mask.

## The app icon

The app uses an Icon Composer document, `App/Etcetera/Etcetera/AppIcon.icon`,
with two layers split from `poppins-icon.svg`: the gradient rectangle as
background, without glass, and the glyph group as foreground, where the system
applies its specular and depth effects. After changing the icon, run
`make_app_icon.py` to refresh the layers. `icon.json` holds the layer settings
and opens in Icon Composer.

An Icon Composer document has one design for every size, so the reduced `e.`
is not part of the app icon.

## On using a typeface

The glyphs are baked into path data in every file. None of them reference a
font by name.

That distinction matters. An SVG with `<text font-family="Poppins">` renders
with whatever the viewer happens to have: GitHub sanitizes README SVGs and
resolves nothing, a Linux build box substitutes DejaVu, and Icon Composer
rasterizes whatever the Mac picks. A logo has to be geometry. So the set is
set in the real typeface and then outlined, which is the normal design
handoff, rather than left as live text.

Poppins is SIL OFL 1.1. Outlining glyphs for a logo is permitted, and the font
file itself is not redistributed here. If you later want to change the
wordmark, you need Poppins installed and a re-run of `build_icon_poppins.py`,
not just an editor.

One change was made to the typeface: the period is scaled to 1.45 times its
natural size. At its drawn size it is far too light for the cell it occupies,
and the bottom right of the grid reads as empty. Adjusting one glyph in a
lockup is ordinary practice.

## Construction

Everything sits on a 1024 canvas. The raster is 4 columns by 4 rows of 175
units, spanning 162 to 862, so it is centered. Each glyph owns a 2x2 block.

- The `t` stem and the dot both sit on the grid line at x = 687, which is why
  they line up vertically.
- The `e` crossbar is clipped to the bowl through an ellipse fitted to it,
  unioned with everything left of center so the rest of the glyph is
  untouched. Left alone, the crossbar ends in a flat vertical cut whose
  corners sit outside the curve.
- The `t` ascender rises above the raster. Ascenders overshoot; keeping the
  stem inside its cell makes the glyph read as a capital T.
- The dot sits on the baseline of the `c`, not in the center of its cell. Grid
  logic loses to typographic logic here, or it reads as a bullet.
- The whole group is nudged to center it optically. The glyphs do not fill
  their cells evenly, so geometric centering looks wrong.

`build_icon_poppins.py` generates the set from these numbers. Change a number,
run the script, and the set stays consistent.

## Palette

| Hex | Role |
| --- | --- |
| `#6BB2FF` | Gradient start, top left |
| `#2C74E6` | Gradient middle |
| `#0B3A9E` | Gradient end, bottom right |
| `#1B5FD0` | Flat blue, for the mark on light backgrounds |
| `#04205C` | Floor shading |

White glyphs throughout.

## Matching type

For body text alongside the mark, stay geometric. Poppins itself works, and
its single-storey `a` sits naturally next to the mark. Avoid humanist faces;
the construction here is compass and ruler work, and a humanist face beside
it looks like an accident.

## Reduction

The full lockup stops being legible somewhere around 32px. Below that, use
the `-small` variant, which keeps the `e` and the dot at a size that survives.
Menu bar items and favicons should use the reduced form.
