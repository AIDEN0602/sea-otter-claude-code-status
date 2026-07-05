# spritegen

Procedurally generates the pixel-art otter sprite sheets consumed by the
Swift app, per `SPEC.md` section 3.

## Regenerating

```sh
python3 spritegen/gen_sprites.py
```

Requires Python 3 and Pillow. Regenerates everything under
`assets/sprites/` and `assets/previews/` from scratch -- the script is
idempotent, safe to re-run any time the pixel maps in `gen_sprites.py`
change.

## Output layout

```
assets/sprites/<variant>/<state>.png
assets/previews/variants.png              # A/B/C idle comparison, 8x, black + light strips
assets/previews/variant_A_all_states.png  # all 7 states of variant A, 8x, on black
```

`<variant>` is `A` (round chibi -- the default candidate, all 7 states
implemented), `B` (classic long body lying horizontal), or `C` (tiny
minimal/blocky style). Only `A` implements every session state; `B` and
`C` are style comps and only implement `idle` + `waiting_permission`,
per the design brief.

## Frame count encoding

Each output PNG is a single horizontal strip of 32x32 RGBA cells, exactly
per `SPEC.md`: **frame count = sheet width / 32**. There is no separate
metadata file -- the app derives frame count purely from the image's
pixel width. All sheets in this repo are 2-4 frames wide.

## How the pixel art is built (not vector shapes)

Nothing is drawn with `ImageDraw.ellipse`/`rectangle`. Every frame is a
hand-authored character grid (list of strings / list of lists, one char
per pixel) mapped through a palette dict (`build_palette()`) to RGBA.

- `oval_rows(half_widths, fill, outline)` is the core hand-pixel-art
  circle/oval technique: you supply one explicit half-width per row, and
  it fills `center +/- half_width` with `fill`, marking the two edge
  pixels `outline`. This gives the crisp "staircase" silhouette typical
  of pixel-art circles (as opposed to an anti-aliased blob from a vector
  ellipse). The head, body, and muzzle/belly patches are all built this
  way, with hand-picked half-width arrays (e.g. `HEAD_HALFW`).
- `stamp(grid, rows, top, left)` composites a small shape (ears, eyes,
  nose, paws, tail, props like the clam/speech-bubble/sparkle) onto the
  base grid at fixed coordinates. `.` in a shape means "transparent,
  don't overwrite" so shapes can be stamped on top of each other freely.
- Each state/pose is a small Python function that calls these shared
  parts with different offsets (`dy` for bob/lift, `dx`/`tilt` for head
  tilt, different `eye=` styles, different prop stamps) to build 2-4
  frames.

Variant A and B share the same technique but different proportions
(`HEAD_HALFW`/`BODY_HALFW` vs `B_HEAD_HALFW`/`B_BODY_HALFW`). Variant C
reuses the identical technique with chunkier, fewer-step half-width
arrays and flat (unshaded) cream patches for a more minimal/blocky look.

## Iterating on the art

1. Edit the half-width arrays / shape constants / pose functions in
   `gen_sprites.py`.
2. Run the script.
3. Open `assets/previews/variant_A_all_states.png` (or `variants.png`)
   and look at it -- at 8x nearest-neighbor on both black and light
   backgrounds -- before deciding a change worked. Small coordinate bugs
   (e.g. a limb landing *inside* the head/body silhouette instead of
   outside it) are invisible at 1x and obvious at 8x.
4. A prop or limb that hugs the head/body outline usually just reads as
   silhouette noise, not a separate feature -- if something needs to
   read as a distinct paw/arm, give it a visible gap or a different
   color from whatever it's next to, not just an adjacent outline.
