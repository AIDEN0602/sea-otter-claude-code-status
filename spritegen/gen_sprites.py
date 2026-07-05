#!/usr/bin/env python3
"""Procedural pixel-art otter sprite sheet generator for NotchOtter.

Every frame is a hand-authored 32x32 character grid (list-of-strings /
list-of-lists mapped through a palette dict), NOT drawn with vector
ellipse/rect primitives -- those look mushy at this resolution. Ovals used
for the head/body/tail are built by `oval_rows()`, which fills explicit
per-row half-widths (a classic pixel-art circle technique: each row is a
horizontal band with hand-picked width, giving a crisp "staircase" outline
instead of an anti-aliased blob). Small asymmetric features (eyes, nose,
paws, tail, props) are then stamped on top at fixed coordinates.

Usage:
    python3 spritegen/gen_sprites.py

Regenerates every sprite sheet in assets/sprites/<variant>/<state>.png and
the two comparison images in assets/previews/. See spritegen/README.md for
how frame counts are encoded (sheet width / 32 = frame count, per SPEC.md).
"""

import os

from PIL import Image, ImageDraw, ImageFont

CELL = 32
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
SPRITES_DIR = os.path.join(REPO_ROOT, "assets", "sprites")
PREVIEWS_DIR = os.path.join(REPO_ROOT, "assets", "previews")

STATES = [
    "idle",
    "working",
    "waiting_permission",
    "waiting_input",
    "done",
    "error",
    "stale",
]

FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default()


# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------

def build_palette(ghost=False):
    """Char -> RGBA. `ghost=True` gives the pale translucent 'stale' look."""
    p = {
        ".": None,                     # transparent
        "O": (55, 34, 20, 255),        # outline - dark brown
        "B": (150, 98, 56, 255),       # body fur - warm brown
        "D": (120, 76, 42, 255),       # shading - darker brown
        "C": (245, 227, 194, 255),     # cream muzzle / belly
        "c": (221, 198, 160, 255),     # cream shading (patch outline)
        "K": (26, 20, 16, 255),        # eye black
        "W": (255, 255, 255, 255),     # eye highlight
        "N": (40, 26, 20, 255),        # nose
        "P": (222, 148, 138, 255),     # inner ear / mouth pink
        "S": (223, 232, 235, 255),     # clam shell (cool gray-blue, pops off fur)
        "T": (163, 180, 186, 255),     # clam shell shadow line
        "R": (214, 58, 58, 255),       # error X
        "!": (247, 197, 55, 255),      # exclaim mark / sparkle gold
        "u": (255, 255, 255, 235),     # bubble fill (white)
        "g": (70, 55, 40, 235),        # bubble outline
    }
    if not ghost:
        return p
    ghost_map = {}
    for k, v in p.items():
        if v is None:
            ghost_map[k] = None
            continue
        r, g, b, a = v
        r = int(r + (232 - r) * 0.6)
        g = int(g + (238 - g) * 0.6)
        b = int(b + (245 - b) * 0.6)
        ghost_map[k] = (r, g, b, 145)
    return ghost_map


# ---------------------------------------------------------------------------
# Grid helpers
# ---------------------------------------------------------------------------

def new_grid(w=CELL, h=CELL):
    return [["." for _ in range(w)] for _ in range(h)]


def stamp(grid, rows, top, left):
    """Draw `rows` (list[str]) onto `grid` at (top, left). '.' = skip."""
    h, w = len(grid), len(grid[0])
    for r, row in enumerate(rows):
        gr = top + r
        if not (0 <= gr < h):
            continue
        for c, ch in enumerate(row):
            if ch == ".":
                continue
            gc = left + c
            if 0 <= gc < w:
                grid[gr][gc] = ch


def oval_rows(half_widths, fill="B", outline="O"):
    """Hand-authored circle/oval technique: one explicit half-width per row.

    Each row is filled center +/- half_width with `fill`, edges marked
    `outline`. Produces a crisp pixel-art "staircase" silhouette.
    """
    maxw = max(half_widths)
    width = maxw * 2 + 1
    center = maxw
    rows = []
    for hw in half_widths:
        row = ["."] * width
        if hw <= 0:
            row[center] = outline
        else:
            for c in range(center - hw, center + hw + 1):
                row[c] = fill
            row[center - hw] = outline
            row[center + hw] = outline
        rows.append("".join(row))
    return rows


def render(grid, palette):
    img = Image.new("RGBA", (len(grid[0]), len(grid)), (0, 0, 0, 0))
    px = img.load()
    for r, row in enumerate(grid):
        for c, ch in enumerate(row):
            color = palette.get(ch)
            if color:
                px[c, r] = color
    return img


def sheet_from_frames(frames, palette):
    n = len(frames)
    sheet = Image.new("RGBA", (CELL * n, CELL), (0, 0, 0, 0))
    for i, grid in enumerate(frames):
        sheet.paste(render(grid, palette), (i * CELL, 0))
    return sheet


def upscale_nn(img, factor):
    return img.resize((img.width * factor, img.height * factor), Image.NEAREST)


# ---------------------------------------------------------------------------
# Shared building blocks (used across variant A poses)
# ---------------------------------------------------------------------------

EAR = [
    ".OO.",
    "OPPO",
    "OBBO",
]

HEAD_HALFW = [4, 7, 8, 9, 10, 10, 10, 10, 10, 10, 9, 8, 7, 4]
BODY_HALFW = [6, 8, 9, 9, 9, 8, 6]
MUZZLE_HALFW = [3, 5, 5, 3]
BELLY_HALFW = [3, 5, 5, 4, 2]

TAIL_RIGHT = [
    ".OO....",
    "OBBO...",
    "OBBBO..",
    ".OBBBO.",
    "..OBBBO",
    "..OBBBO",
    "...OBBO",
    "....OBO",
    "....OO.",
]

CLAM = [
    ".TTT.",
    "TSSST",
    "STTTS",
]

BUBBLE = [
    ".ggg.",
    "gu!ug",
    "gu!ug",
    "guuug",
    "gu!ug",
    "..g..",
]


SPARKLE = [
    ".!.",
    "!!!",
    ".!.",
]

DIZZY = [
    "O.O",
    ".O.",
]


def head_center_col():
    return 16


def add_ears(grid, spread=0, lift=0):
    left_top = 3 + lift
    stamp(grid, EAR, left_top, 8 - spread)
    stamp(grid, EAR, left_top, 20 + spread)


def add_head(grid, dy=0, dx=0):
    rows = oval_rows(HEAD_HALFW, fill="B", outline="O")
    stamp(grid, rows, 6 + dy, 6 + dx)


def add_body(grid, dy=0):
    rows = oval_rows(BODY_HALFW, fill="B", outline="O")
    stamp(grid, rows, 19 + dy, 7)


def add_muzzle(grid, dy=0, dx=0):
    rows = oval_rows(MUZZLE_HALFW, fill="C", outline="c")
    stamp(grid, rows, 14 + dy, 11 + dx)


def add_belly(grid, dy=0):
    rows = oval_rows(BELLY_HALFW, fill="C", outline="c")
    stamp(grid, rows, 20 + dy, 11)


def add_nose_mouth(grid, dy=0, dx=0, open_mouth=False):
    grid[16 + dy][16 + dx] = "N"
    if open_mouth:
        grid[17 + dy][16 + dx] = "P"
        grid[18 + dy][15 + dx] = "P"
        grid[18 + dy][17 + dx] = "P"
    else:
        grid[17 + dy][15 + dx] = "P"
        grid[17 + dy][17 + dx] = "P"
    # whiskers: two short dashes per cheek, just outside the cream muzzle
    row = 16 + dy
    grid[row][9 + dx] = "O"
    grid[row][23 + dx] = "O"
    grid[row + 1][8 + dx] = "O"
    grid[row + 1][24 + dx] = "O"


EYE_OPEN = ["KW", "KK"]
EYE_CLOSED = ["OO"]
# "wide"/surprised eye: same footprint family as EYE_OPEN, just one ring
# bigger, with the white highlight kept as a single sparkle pixel so it
# doesn't read as a solid mask.
EYE_WIDE = [".K.", "KWK", "KKK"]
EYE_X = ["R.R", ".R.", "R.R"]


def add_eyes(grid, style="open", dy=0, tilt=0):
    row = 11 + dy
    lcol, rcol = 11 + tilt, 19 + tilt
    if style == "open":
        stamp(grid, EYE_OPEN, row, lcol)
        stamp(grid, EYE_OPEN, row, rcol)
    elif style == "closed":
        stamp(grid, EYE_CLOSED, row + 1, lcol)
        stamp(grid, EYE_CLOSED, row + 1, rcol)
    elif style == "wide":
        stamp(grid, EYE_WIDE, row - 1, lcol - 1)
        stamp(grid, EYE_WIDE, row - 1, rcol + 1)
    elif style == "x":
        stamp(grid, EYE_X, row, lcol)
        stamp(grid, EYE_X, row, rcol)


PAW_DOWN = [
    "OO",
    "BB",
    "OO",
]

PAW_UP = [
    "OO",
    "BB",
]


def add_paws_sitting(grid, dy=0):
    stamp(grid, PAW_DOWN, 23 + dy, 9)
    stamp(grid, PAW_DOWN, 23 + dy, 21)


WAVE_PAW = [
    ".OOO.",
    "OBBBO",
    "OBBBO",
    ".OOO.",
]


def add_arm_wave(grid, raised=True):
    # left paw stays planted. The waving paw is drawn as its own rounded
    # blob floating just clear of the head's silhouette (head's right edge
    # tops out at col 26) rather than a thin connecting arm -- a 2px-wide
    # line hugging the head's curve reads as noise, not a limb, at 32px.
    stamp(grid, PAW_DOWN, 23, 9)
    if raised:
        stamp(grid, WAVE_PAW, 8, 27)
    else:
        stamp(grid, PAW_DOWN, 23, 21)


def add_arms_paddling(grid, side="left"):
    # paws out front, alternating up/down like paddling water.
    if side == "left":
        stamp(grid, PAW_DOWN, 20, 6)
        stamp(grid, PAW_UP, 24, 22)
    else:
        stamp(grid, PAW_UP, 24, 6)
        stamp(grid, PAW_DOWN, 20, 22)


def add_arms_holding_up(grid, dy=0):
    # paws stretched up and OUT to the sides (cheer pose) -- kept well
    # clear of the ears (cols 8-11 / 20-23) so paw and ear don't visually
    # fuse into one tall blob.
    stamp(grid, PAW_UP, 2 + dy, 3)
    stamp(grid, PAW_UP, 2 + dy, 26)


PAW_SPLAY_LEFT = [
    ".OOO.",
    "OBBBO",
    "OBBBO",
    ".OOO.",
]

PAW_SPLAY_RIGHT = PAW_SPLAY_LEFT


def add_paws_splayed(grid, dy=0):
    # otter-on-its-back pose: chunky paws thrown out to the sides, fully
    # clear of the body silhouette (body spans roughly cols 7-25) so they
    # read as limbs instead of fuzzing into the outline.
    stamp(grid, PAW_SPLAY_LEFT, 16 + dy, 0)
    stamp(grid, PAW_SPLAY_RIGHT, 16 + dy, 27)


def add_tail(grid, dy=0):
    stamp(grid, TAIL_RIGHT, 18 + dy, 24)


def base_sit(dy=0, eye="open", mouth_open=False, ear_spread=0, head_dx=0, tail_dy=0):
    """The common seated chibi pose shared by idle/working/waiting states."""
    g = new_grid()
    add_tail(g, dy=tail_dy)
    add_ears(g, spread=ear_spread, lift=dy)
    add_head(g, dy=dy, dx=head_dx)
    add_body(g, dy=dy)
    add_muzzle(g, dy=dy, dx=head_dx)
    add_belly(g, dy=dy)
    add_eyes(g, style=eye, dy=dy, tilt=head_dx)
    add_nose_mouth(g, dy=dy, dx=head_dx, open_mouth=mouth_open)
    return g


# ---------------------------------------------------------------------------
# Variant A: round chibi -- all 7 states
# ---------------------------------------------------------------------------

def variant_a_idle():
    f1 = base_sit(dy=0, eye="open")
    add_paws_sitting(f1, dy=0)

    f2 = base_sit(dy=-1, eye="open")
    add_paws_sitting(f2, dy=-1)

    f3 = base_sit(dy=0, eye="closed")
    add_paws_sitting(f3, dy=0)
    return [f1, f2, f3]


def variant_a_working():
    frames = []
    for side in ("left", "right", "left", "right"):
        g = base_sit(dy=0, eye="open", ear_spread=0)
        add_arms_paddling(g, side=side)
        clam_dy = -1 if side == "left" else 1
        stamp(g, CLAM, 21 + clam_dy, 14)
        frames.append(g)
    return frames


def variant_a_waiting_permission():
    frames = []
    for raised in (True, False):
        g = base_sit(dy=0, eye="open")
        add_arm_wave(g, raised=raised)
        if raised:
            stamp(g, BUBBLE, 0, 26)
        frames.append(g)
    return frames


def variant_a_waiting_input():
    f1 = base_sit(dy=0, eye="open", head_dx=0)
    add_paws_sitting(f1, dy=0)

    f2 = base_sit(dy=0, eye="wide", head_dx=2)
    add_paws_sitting(f2, dy=0)

    f3 = base_sit(dy=0, eye="closed", head_dx=0)
    add_paws_sitting(f3, dy=0)
    return [f1, f2, f3]


def variant_a_done():
    frames = []
    for i in range(3):
        g = base_sit(dy=0, eye="wide", mouth_open=True)
        add_arms_holding_up(g, dy=0)
        # clam trophy held up between the raised paws, above the ears.
        stamp(g, CLAM, 0, 13)
        if i in (0, 2):
            stamp(g, SPARKLE, 0, 0)
            stamp(g, SPARKLE, 6, 29)
        else:
            stamp(g, SPARKLE, 6, 0)
            stamp(g, SPARKLE, 0, 29)
        frames.append(g)
    return frames


def on_back_pose(dx=0):
    """Otter flipped on its back: belly up, paws splayed, X eyes."""
    g = new_grid()
    add_tail(g, dy=2)
    add_ears(g, spread=0, lift=2)
    add_head(g, dy=2, dx=dx)
    add_body(g, dy=2)
    add_muzzle(g, dy=2, dx=dx)
    add_belly(g, dy=2)
    add_paws_splayed(g, dy=0)
    add_eyes(g, style="x", dy=2, tilt=dx)
    row = 18
    g[row][15 + dx] = "P"
    g[row][16 + dx] = "P"
    g[row][17 + dx] = "P"
    # little "dizzy" flick marks above the ears
    stamp(g, DIZZY, 0, 4 + dx)
    stamp(g, DIZZY, 0, 25 + dx)
    return g


def variant_a_error():
    # small side-to-side shake between the two frames sells "toppled over".
    f1 = on_back_pose(dx=0)
    f2 = on_back_pose(dx=1)
    return [f1, f2]


def variant_a_stale():
    f1 = base_sit(dy=0, eye="closed")
    add_paws_sitting(f1, dy=0)
    f2 = base_sit(dy=-2, eye="closed")
    add_paws_sitting(f2, dy=-2)
    return [f1, f2]


VARIANT_A_BUILDERS = {
    "idle": variant_a_idle,
    "working": variant_a_working,
    "waiting_permission": variant_a_waiting_permission,
    "waiting_input": variant_a_waiting_input,
    "done": variant_a_done,
    "error": variant_a_error,
    "stale": variant_a_stale,
}


# ---------------------------------------------------------------------------
# Variant B: classic long-body otter, lying horizontally (idle + waiting only)
# ---------------------------------------------------------------------------

# Wide, mostly-flat half-widths (only the two end rows taper) so the oval
# reads as a long horizontal capsule instead of a round blob.
B_BODY_HALFW = [6, 10, 12, 12, 12, 12, 10, 6]
B_HEAD_HALFW = [2, 4, 5, 5, 5, 4, 2]

B_TAIL = [
    ".OOO...",
    "OBBBBO.",
    "OBBBBBO",
    "OBBBBBO",
    "OBBBBO.",
    ".OOO...",
]

B_EAR = [".OO.", "OPPO", "OBBO"]


def b_base(dy=0, eye="open"):
    g = new_grid()
    # body: long flat capsule, the spine of the "lying down" pose.
    body_rows = oval_rows(B_BODY_HALFW, fill="B", outline="O")
    stamp(g, body_rows, 13 + dy, 6)
    # tail continues the body's right end, tapering off past the canvas edge.
    stamp(g, B_TAIL, 15 + dy, 25)
    # head overlaps the body's left bulge so neck reads as one silhouette.
    stamp(g, B_EAR, 9 + dy, 2)
    head_rows = oval_rows(B_HEAD_HALFW, fill="B", outline="O")
    stamp(g, head_rows, 11 + dy, 0)
    muzzle = oval_rows([2, 3, 3, 2], fill="C", outline="c")
    stamp(g, muzzle, 14 + dy, 2)
    g[16 + dy][6] = "N"
    if eye == "open":
        stamp(g, ["KW", "KK"], 13 + dy, 4)
    else:
        stamp(g, ["OO"], 14 + dy, 4)
    # belly patch along the body's underside
    belly = oval_rows([2, 4, 5, 5, 4, 2], fill="C", outline="c")
    stamp(g, belly, 17 + dy, 11)
    # little paws tucked underneath
    stamp(g, ["OO", "BB"], 20 + dy, 10)
    stamp(g, ["OO", "BB"], 20 + dy, 20)
    return g


def variant_b_idle():
    f1 = b_base(dy=0, eye="open")
    f2 = b_base(dy=1, eye="open")
    f3 = b_base(dy=0, eye="closed")
    return [f1, f2, f3]


def variant_b_waiting_permission():
    frames = []
    for raised in (True, False):
        g = b_base(dy=0, eye="open")
        if raised:
            stamp(g, WAVE_PAW, 6, 11)
            stamp(g, BUBBLE, 0, 15)
        else:
            stamp(g, ["OO", "BB"], 12, 11)
        frames.append(g)
    return frames


VARIANT_B_BUILDERS = {
    "idle": variant_b_idle,
    "waiting_permission": variant_b_waiting_permission,
}


# ---------------------------------------------------------------------------
# Variant C: tiny minimal style -- same oval-silhouette technique as variant
# A, but with chunky stepped half-widths (fewer, bigger jumps -> a more
# faceted/blocky look) and flat colors (no cream-shading ring, no whiskers),
# evoking a simplified 16x16 sprite blown up to 32x32.
# ---------------------------------------------------------------------------

C_HEAD_HALFW = [5, 5, 9, 9, 9, 9, 9, 5, 5]
C_BODY_HALFW = [7, 7, 10, 10, 10, 7, 7]
C_EYE = ["KK", "KK"]
C_EYE_CLOSED = ["OO"]


def c_base(eye="open", dy=0):
    g = new_grid()
    stamp(g, TAIL_RIGHT, 16 + dy, 23)
    stamp(g, EAR, 4 + dy, 8)
    stamp(g, EAR, 4 + dy, 20)
    head_rows = oval_rows(C_HEAD_HALFW, fill="B", outline="O")
    stamp(g, head_rows, 7 + dy, 7)  # head: rows 7-15
    body_rows = oval_rows(C_BODY_HALFW, fill="B", outline="O")
    stamp(g, body_rows, 15 + dy, 6)  # body: rows 15-21, overlaps head row 15
    # flat cream muzzle + belly blocks (no shading ring -- keeps it "flat").
    stamp(g, ["CCCCC"] * 3, 12 + dy, 14)
    stamp(g, ["CCCCCCC"] * 3, 17 + dy, 13)
    if eye == "open":
        stamp(g, C_EYE, 10 + dy, 11)
        stamp(g, C_EYE, 10 + dy, 19)
    else:
        stamp(g, C_EYE_CLOSED, 11 + dy, 11)
        stamp(g, C_EYE_CLOSED, 11 + dy, 19)
    g[14 + dy][16] = "N"
    g[15 + dy][15] = "P"
    g[15 + dy][17] = "P"
    stamp(g, PAW_DOWN, 20 + dy, 9)
    stamp(g, PAW_DOWN, 20 + dy, 21)
    return g


def variant_c_idle():
    return [c_base(eye="open", dy=0), c_base(eye="open", dy=-1), c_base(eye="closed", dy=0)]


def variant_c_waiting_permission():
    frames = []
    for raised in (True, False):
        g = c_base(eye="open")
        if raised:
            stamp(g, WAVE_PAW, 8, 27)
            stamp(g, BUBBLE, 0, 26)
        else:
            stamp(g, PAW_DOWN, 20, 21)
        frames.append(g)
    return frames


VARIANT_C_BUILDERS = {
    "idle": variant_c_idle,
    "waiting_permission": variant_c_waiting_permission,
}


VARIANTS = {
    "A": VARIANT_A_BUILDERS,
    "B": VARIANT_B_BUILDERS,
    "C": VARIANT_C_BUILDERS,
}


# ---------------------------------------------------------------------------
# Build + save
# ---------------------------------------------------------------------------

def build_all():
    saved = {}
    for variant, builders in VARIANTS.items():
        out_dir = os.path.join(SPRITES_DIR, variant)
        os.makedirs(out_dir, exist_ok=True)
        saved[variant] = {}
        for state, builder in builders.items():
            frames = builder()
            ghost = state == "stale"
            palette = build_palette(ghost=ghost)
            sheet = sheet_from_frames(frames, palette)
            path = os.path.join(out_dir, f"{state}.png")
            sheet.save(path)
            saved[variant][state] = (path, len(frames))
    return saved


# ---------------------------------------------------------------------------
# Previews
# ---------------------------------------------------------------------------

def label(draw, xy, text, size=20, fill=(255, 255, 255, 255)):
    draw.text(xy, text, font=font(size), fill=fill)


def build_variants_preview(saved):
    scale = 8
    cell_px = CELL * scale
    pad = 24
    label_h = 40
    strip_h = cell_px + label_h
    total_w = pad + 3 * (cell_px + pad)
    total_h = pad + strip_h + pad + strip_h + pad

    canvas = Image.new("RGB", (total_w, total_h), (30, 30, 30))
    draw = ImageDraw.Draw(canvas)

    # black strip (notch simulation) on top, light strip below
    black_y = pad
    light_y = pad + strip_h + pad
    draw.rectangle([0, black_y - 4, total_w, black_y + strip_h + 4], fill=(0, 0, 0))
    draw.rectangle([0, light_y - 4, total_w, light_y + strip_h + 4], fill=(232, 232, 228))

    variant_names = {"A": "A - round chibi", "B": "B - long body", "C": "C - tiny 16x16"}
    for i, variant in enumerate(("A", "B", "C")):
        idle_path = saved[variant]["idle"][0]
        sheet = Image.open(idle_path).convert("RGBA")
        first_frame = sheet.crop((0, 0, CELL, CELL))
        big = upscale_nn(first_frame, scale)

        x = pad + i * (cell_px + pad)

        canvas.paste(big, (x, black_y), big)
        label(draw, (x, black_y + cell_px + 4), variant_names[variant],
              size=20, fill=(255, 255, 255))

        canvas.paste(big, (x, light_y), big)
        label(draw, (x, light_y + cell_px + 4), variant_names[variant],
              size=20, fill=(20, 20, 20))

    label(draw, (pad, 2), "notch-otter sprite variants (idle frame 1, 8x nearest-neighbor)",
          size=16, fill=(255, 255, 255))

    out_path = os.path.join(PREVIEWS_DIR, "variants.png")
    canvas.save(out_path)
    return out_path


def build_variant_a_all_states_preview(saved):
    scale = 8
    cell_px = CELL * scale
    pad = 20
    label_h = 28
    cols = 4
    rows = 2
    cell_w = cell_px * 4 + pad  # up to 4 frames wide per state
    cell_h = cell_px + label_h + pad

    total_w = pad + cols * cell_w
    total_h = pad + rows * cell_h + 40

    canvas = Image.new("RGB", (total_w, total_h), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    label(draw, (pad, 6), "notch-otter variant A - all 7 states (8x, on black)",
          size=18, fill=(255, 255, 255))

    for idx, state in enumerate(STATES):
        r, c = divmod(idx, cols)
        x = pad + c * cell_w
        y = 40 + pad + r * cell_h

        path, nframes = saved["A"][state]
        sheet = Image.open(path).convert("RGBA")
        big = upscale_nn(sheet, scale)
        canvas.paste(big, (x, y), big)
        label(draw, (x, y + cell_px + 4), f"{state} ({nframes}f)",
              size=16, fill=(255, 255, 255))

    out_path = os.path.join(PREVIEWS_DIR, "variant_A_all_states.png")
    canvas.save(out_path)
    return out_path


def main():
    os.makedirs(SPRITES_DIR, exist_ok=True)
    os.makedirs(PREVIEWS_DIR, exist_ok=True)
    saved = build_all()

    for variant in sorted(saved):
        for state in sorted(saved[variant]):
            path, n = saved[variant][state]
            print(f"[{variant}] {state}: {n} frames -> {path}")

    vpath = build_variants_preview(saved)
    print(f"preview: {vpath}")
    apath = build_variant_a_all_states_preview(saved)
    print(f"preview: {apath}")


if __name__ == "__main__":
    main()
