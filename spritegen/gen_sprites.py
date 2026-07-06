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
        "L": (215, 217, 222, 255),     # laptop chassis (cool light gray)
        "l": (146, 149, 156, 255),     # laptop chassis shadow / underside
        "E": (38, 40, 46, 255),        # laptop screen bezel (near-black)
        "U": (88, 168, 224, 255),      # laptop screen glow (blue)
        "V": (156, 214, 255, 255),     # laptop screen glow, bright flicker frame
        "H": (103, 65, 40, 255),       # sea otter: dark chocolate body/back fur
        "Y": (78, 48, 29, 255),        # sea otter: chocolate shading (tail/ear)
        "q": (140, 202, 232, 190),     # sea otter: water line accent (translucent)
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

# Small open laptop: upright glowing screen + flat keyboard deck, sat in
# front of the belly. Kept a distinct cool gray/blue palette (L/l/E/U) so
# it never blends into the warm-brown fur silhouette behind it.
LAPTOP = [
    "..EEEEEEE..",
    ".EUUUUUUUE.",
    ".EUUUUUUUE.",
    ".EEEEEEEEE.",
    "LLLLLLLLLLL",
    "LLLLLLLLLLL",
    "lllllllllll",
]

LAPTOP_FLICKER = [
    "..EEEEEEE..",
    ".EVVVVVVVE.",
    ".EVVVVVVVE.",
    ".EEEEEEEEE.",
    "LLLLLLLLLLL",
    "LLLLLLLLLLL",
    "lllllllllll",
]

# These (medium-brown "B"/"O" fill) are used by variants B and C, which
# still use the old single-brown palette -- kept here even though variant
# A's sea-otter redesign below uses its own chocolate "H" shapes instead.
EAR = [
    ".OO.",
    "OPPO",
    "OBBO",
]

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

PAW_DOWN = [
    "OO",
    "BB",
    "OO",
]

PAW_UP = [
    "OO",
    "BB",
]

WAVE_PAW = [
    ".OOO.",
    "OBBBO",
    "OBBBO",
    ".OOO.",
]


# ---------------------------------------------------------------------------
# Variant A: SEA OTTER floating on its back -- all 7 states
# ---------------------------------------------------------------------------
# Sea otters float belly-up and use their chest as a table -- that's the
# whole pose language here, replacing the old sitting-chibi. The identity
# markers that must read at a glance: a pale cream/gray face ("C"/"c")
# against a dark chocolate body ("H"/"O"), tiny low-set ears, and a
# horizontal on-back silhouette using the full 32px width. Head sits at the
# left, body/belly extend right, tail at the far right -- same head-then-
# body overlap technique proven in variant B, just recolored and widened.

# Head made a touch bigger/rounder (10 rows, maxhw 7) -- the face is the
# cuteness anchor and was too small next to the long body. Belly shrunk to
# a small oval (5 rows, maxhw 4) AND, critically, moved clearly clear of
# the head's own right edge (head's widest rows reach col 14) so a solid
# band of dark chocolate separates the pale face from the pale belly --
# without that gap the two pale regions visually fuse into one big pale
# mass and the "dark body" read disappears even though the belly itself
# is small. That's what was wrong the first time: belly left was 13,
# inside the head's own footprint, touching/overlapping it directly.
SEA_HEAD_HALFW = [2, 4, 6, 7, 7, 7, 7, 6, 4, 2]     # 10 rows, maxhw 7 -> width 15
SEA_BODY_HALFW = [5, 9, 11, 12, 12, 12, 11, 9, 5]   # 9 rows, maxhw 12 -> width 25
SEA_BELLY_HALFW = [2, 4, 4, 3, 2]                   # 5 rows, maxhw 4 -> width 9

SEA_HEAD_TOP, SEA_HEAD_LEFT = 8, 0
SEA_BODY_TOP, SEA_BODY_LEFT = 11, 6
SEA_BELLY_TOP, SEA_BELLY_LEFT = 12, 17
SEA_TAIL_TOP, SEA_TAIL_LEFT = 13, 26
SEA_WATERLINE_ROW = 20

SEA_EAR = [
    "HH",
    "OO",
]

SEA_TAIL = [
    "..OOO..",
    ".OHHHO.",
    "OHHHHHO",
    "OHHHHHO",
    ".OHHHO.",
    "..OOO..",
]

# Small folded paw (rests flat on the belly) vs the big rounded paw used
# whenever a limb needs to read clearly away from the body (typing,
# waving, holding, splayed) -- chocolate "H" fill so it always matches the
# body rather than the old medium-brown "B" used by variants B/C.
SEA_PAW_SMALL = [
    "OO",
    "HH",
]

SEA_PAW_BIG = [
    ".OOO.",
    "OHHHO",
    "OHHHO",
    ".OOO.",
]

SEA_EYE_OPEN = ["KW", "KK"]
SEA_EYE_CLOSED = ["OO"]
SEA_EYE_WIDE = [".K.", "KWK", "KKK"]
SEA_EYE_X = ["R.R", ".R.", "R.R"]
# Lowered lids, cast down toward the laptop -- reads as concentration
# rather than the fully-shut "closed" style, which looks like napping.
SEA_EYE_FOCUS = ["OO", "KK"]


def add_sea_body(grid, dy=0):
    rows = oval_rows(SEA_BODY_HALFW, fill="H", outline="O")
    stamp(grid, rows, SEA_BODY_TOP + dy, SEA_BODY_LEFT)


def add_sea_tail(grid, dy=0):
    stamp(grid, SEA_TAIL, SEA_TAIL_TOP + dy, SEA_TAIL_LEFT)


def add_sea_belly(grid, dy=0):
    rows = oval_rows(SEA_BELLY_HALFW, fill="C", outline="c")
    stamp(grid, rows, SEA_BELLY_TOP + dy, SEA_BELLY_LEFT)


def add_sea_head(grid, dy=0, dx=0):
    # Pale face oval stamped AFTER the body so the face silhouette always
    # wins in the head/body overlap -- the pale/dark contrast is the whole
    # point, so the face must never get eaten by the darker torso.
    rows = oval_rows(SEA_HEAD_HALFW, fill="C", outline="c")
    stamp(grid, rows, SEA_HEAD_TOP + dy, SEA_HEAD_LEFT + dx)


def add_sea_ears(grid, dy=0, dx=0):
    # Tiny, low on the head (near the lower edge of the face oval), not
    # tall nubs on top like a land otter -- that low placement is one of
    # the sea-otter identity cues called out in the brief.
    stamp(grid, SEA_EAR, 15 + dy, 1 + dx)
    stamp(grid, SEA_EAR, 15 + dy, 11 + dx)


def add_sea_face(grid, style="open", dy=0, dx=0):
    row = 11 + dy
    lcol, rcol = 3 + dx, 10 + dx
    if style == "open":
        stamp(grid, SEA_EYE_OPEN, row, lcol)
        stamp(grid, SEA_EYE_OPEN, row, rcol)
    elif style == "closed":
        stamp(grid, SEA_EYE_CLOSED, row + 1, lcol)
        stamp(grid, SEA_EYE_CLOSED, row + 1, rcol)
    elif style == "focus":
        stamp(grid, SEA_EYE_FOCUS, row + 1, lcol)
        stamp(grid, SEA_EYE_FOCUS, row + 1, rcol)
    elif style == "wide":
        stamp(grid, SEA_EYE_WIDE, row - 1, lcol - 1)
        stamp(grid, SEA_EYE_WIDE, row - 1, rcol - 1)
    elif style == "x":
        stamp(grid, SEA_EYE_X, row, lcol)
        stamp(grid, SEA_EYE_X, row, rcol)
    nose_row = 14 + dy
    grid[nose_row][7 + dx] = "N"
    # a couple of whisker dashes per cheek, if they still land inside the
    # face oval after a head-turn dx shift
    if 0 <= dx + 1 < 32:
        grid[13 + dy][1 + dx] = "O"
    if 0 <= dx + 13 < 32:
        grid[13 + dy][13 + dx] = "O"


def add_sea_waterline(grid, dy=0):
    # Subtle floating-in-water accent -- translucent so it still reads
    # (rather than vanishing) on a pure black background.
    row = SEA_WATERLINE_ROW + dy
    if not (0 <= row < 32):
        return
    for c in (9, 13, 17, 21, 25):
        grid[row][c] = "q"


def sea_base(dy=0, eye="open", dx=0, waterline=True):
    """The common floating-on-back pose shared by idle/working/waiting."""
    g = new_grid()
    add_sea_body(g, dy=dy)
    add_sea_tail(g, dy=dy)
    add_sea_head(g, dy=dy, dx=dx)
    add_sea_ears(g, dy=dy, dx=dx)
    add_sea_belly(g, dy=dy)
    add_sea_face(g, style=eye, dy=dy, dx=dx)
    if waterline:
        add_sea_waterline(g, dy=dy)
    return g


def add_folded_paws(grid, dy=0):
    stamp(grid, SEA_PAW_SMALL, 14 + dy, 20)
    stamp(grid, SEA_PAW_SMALL, 14 + dy, 25)


def variant_a_idle():
    f1 = sea_base(dy=0, eye="open")
    add_folded_paws(f1, dy=0)

    f2 = sea_base(dy=-1, eye="open")
    add_folded_paws(f2, dy=-1)

    f3 = sea_base(dy=0, eye="closed")
    add_folded_paws(f3, dy=0)
    return [f1, f2, f3]


# Laptop rests on the belly (the pale "table" patch), keyboard deck low
# enough that the typing paws mostly hang in the open canvas below the
# body (nothing else is drawn past row 20) rather than inside the laptop's
# own small detail pixels -- that's what made the paws finally read as
# paws instead of keyboard noise in the previous redesign round.
SEA_LAPTOP_TOP, SEA_LAPTOP_LEFT = 13, 17
SEA_KEY_L_COL, SEA_KEY_R_COL = 17, 24
SEA_PAW_LIFT_ROW = SEA_LAPTOP_TOP + 5
SEA_PAW_CONTACT_ROW = SEA_LAPTOP_TOP + 6
SEA_PAW_LIFT_SHIFT = 3


def add_sea_laptop(grid, flicker=False):
    stamp(grid, LAPTOP_FLICKER if flicker else LAPTOP, SEA_LAPTOP_TOP, SEA_LAPTOP_LEFT)


def add_sea_typing_paws(grid, left_down, spark=None):
    l_row = SEA_PAW_CONTACT_ROW if left_down else SEA_PAW_LIFT_ROW
    r_row = SEA_PAW_LIFT_ROW if left_down else SEA_PAW_CONTACT_ROW
    l_col = SEA_KEY_L_COL if left_down else SEA_KEY_L_COL - SEA_PAW_LIFT_SHIFT
    r_col = SEA_KEY_R_COL if not left_down else SEA_KEY_R_COL + SEA_PAW_LIFT_SHIFT
    stamp(grid, SEA_PAW_BIG, l_row, l_col)
    stamp(grid, SEA_PAW_BIG, r_row, r_col)
    if spark == "left":
        grid[l_row - 1][l_col + 1] = "W"
        grid[l_row - 1][l_col + 2] = "W"
    elif spark == "right":
        grid[r_row - 1][r_col + 1] = "W"
        grid[r_row - 1][r_col + 2] = "W"


def variant_a_working():
    # On its back, laptop propped on the belly, head tipped down toward
    # the screen. Paws alternate contact/lift on the keys, with a "clack"
    # spark and a screen-brightness flicker so the motion is unmistakable.
    frames = []
    steps = [
        dict(left_down=True, spark="left", flicker=False),
        dict(left_down=False, spark=None, flicker=True),
        dict(left_down=True, spark="left", flicker=False),
        dict(left_down=False, spark="right", flicker=False),
    ]
    for step in steps:
        g = sea_base(dy=0, eye="focus", waterline=False)
        add_sea_laptop(g, flicker=step["flicker"])
        add_sea_typing_paws(g, left_down=step["left_down"], spark=step["spark"])
        frames.append(g)
    return frames


def variant_a_waiting_permission():
    frames = []
    for raised in (True, False):
        g = sea_base(dy=0, eye="open")
        stamp(g, SEA_PAW_SMALL, 14, 20)
        if raised:
            stamp(g, SEA_PAW_BIG, 2, 2)
            stamp(g, BUBBLE, 0, 9)
        else:
            stamp(g, SEA_PAW_SMALL, 14, 25)
        frames.append(g)
    return frames


def variant_a_waiting_input():
    f1 = sea_base(dy=0, eye="open", dx=0)
    add_folded_paws(f1, dy=0)

    f2 = sea_base(dy=0, eye="wide", dx=2)
    add_folded_paws(f2, dy=0)

    f3 = sea_base(dy=0, eye="closed", dx=0)
    add_folded_paws(f3, dy=0)
    return [f1, f2, f3]


def variant_a_done():
    frames = []
    for i in range(3):
        g = sea_base(dy=0, eye="wide")
        # Paws flank the clam tightly at the same height, close enough
        # (small gaps, not floating far apart) to read as gripping it, and
        # the whole cluster sits close above the head instead of stranded
        # high up with a big empty gap in between.
        stamp(g, SEA_PAW_BIG, 5, 4)
        stamp(g, SEA_PAW_BIG, 5, 20)
        stamp(g, CLAM, 6, 12)
        if i in (0, 2):
            stamp(g, SPARKLE, 0, 0)
            stamp(g, SPARKLE, 4, 29)
        else:
            stamp(g, SPARKLE, 4, 0)
            stamp(g, SPARKLE, 0, 29)
        frames.append(g)
    return frames


def sea_distressed_pose(dx=0):
    """Still floating on its back, but distressed: X eyes, paws flung out
    away from the belly, small dizzy flicks above the head."""
    g = sea_base(dy=0, eye="x", dx=dx, waterline=False)
    stamp(g, SEA_PAW_BIG, 2, 1 + dx)
    stamp(g, SEA_PAW_BIG, 2, 23 + dx)
    stamp(g, DIZZY, 5, 3 + dx)
    stamp(g, DIZZY, 5, 9 + dx)
    return g


def variant_a_error():
    # small side-to-side shake between the two frames sells "distressed".
    f1 = sea_distressed_pose(dx=0)
    f2 = sea_distressed_pose(dx=1)
    return [f1, f2]


def variant_a_stale():
    f1 = sea_base(dy=0, eye="closed")
    add_folded_paws(f1, dy=0)
    f2 = sea_base(dy=-1, eye="closed")
    add_folded_paws(f2, dy=-1)
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

    variant_names = {"A": "A - sea otter", "B": "B - long body", "C": "C - tiny 16x16"}
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
