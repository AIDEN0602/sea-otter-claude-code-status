#!/usr/bin/env python3
"""Turn any photo into a NotchOtter character pack ("hatch your own character").

Unlike gen_sprites.py (which hand-authors every pixel of the stock otter),
this tool derives its 7 state sheets from a real photo: crop to square,
strip the background, downscale-and-quantize into a chunky 32x32 pixel-art
"master", then re-derive the 7 states from that single master by nudging it
(bob/lean/shake), ghosting it (stale), and stamping a small badge on top
(waiting/working/done/error) -- the same state vocabulary and glyph/color
language as gen_sprites.py, just applied to an arbitrary silhouette instead
of a hand-drawn one.

Usage:
    python3 spritegen/hatch.py photo.jpg --name captain-otter

Output layout matches the app's pack contract: one subdirectory per
character under --out-dir, containing the 7 state PNGs (per SPEC.md
section 3 -- horizontal strip of square cells, frame count = width /
height) plus a preview.png contact sheet (ignored by the app, for humans).
"""

import argparse
import os
import re
import sys
from collections import deque

from PIL import Image, ImageDraw, ImageFont, ImageOps

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

MASTER = 32          # pixel-art master resolution, per SPEC.md base cell size
WORK = 256            # intermediate resolution used for background removal
BG_TOLERANCE = 30     # corner-flood-fill color tolerance (0-441, euclidean)
BG_MAX_REMOVE = 0.85  # abort bg removal if it would erase more than this
OUTLINE_COLOR = (30, 22, 16, 255)   # dark brown-black, close to gen_sprites' "O"
GHOST_TARGET = (232, 238, 245)      # pale blue-gray, gen_sprites' ghost blend target
GHOST_BLEND = 0.6
GHOST_ALPHA = 145                   # ~57%, matches gen_sprites' ghost alpha exactly

# Colors matched to gen_sprites.py's palette (see build_palette()):
GOLD = (247, 197, 55, 255)      # "!" sparkle/bubble gold
GOLD_TEXT = (55, 34, 20, 255)   # dark brown text on gold, matches "O" outline ink
BLUE = (88, 168, 224, 255)      # laptop screen glow "U"
RED = (214, 58, 58, 255)        # error "R"
GREEN = (86, 176, 110, 255)     # not in gen_sprites (no literal done-badge there --
                                 # variant_a_done uses gold sparkles + a clam prop,
                                 # not a checkmark); chosen as the universal
                                 # "success" complement to gen_sprites' warm/gold
                                 # palette so it doesn't visually collide with the
                                 # waiting states' gold badges.
WHITE = (255, 255, 255, 255)


def font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def slugify(name):
    s = name.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-") or "character"


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("photo", help="path to a source photo")
    p.add_argument("--name", help="pack name (default: slugified photo filename)")
    p.add_argument(
        "--out-dir",
        default=os.path.expanduser("~/.local/share/notch-otter/sprites"),
        help="packs directory the app scans (default: %(default)s)",
    )
    p.add_argument("--cell", type=int, default=64, help="output cell size in px (default: 64)")
    p.add_argument("--keep-bg", action="store_true", help="skip background removal")
    p.add_argument("--colors", type=int, default=24, help="palette size for quantization (default: 24)")
    return p.parse_args(argv)


# ---------------------------------------------------------------------------
# Photo -> pixel-art master
# ---------------------------------------------------------------------------

def center_crop_square(img):
    w, h = img.size
    s = min(w, h)
    left, top = (w - s) // 2, (h - s) // 2
    return img.crop((left, top, left + s, top + s))


def _color_dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def remove_background(img, tolerance=BG_TOLERANCE, max_remove=BG_MAX_REMOVE):
    """Flood-fill transparency from the 4 corners.

    Each corner is its own flood-fill seed compared against ITS OWN corner
    color (not a running average) -- keeps the fill from drifting across a
    smooth gradient background and eating into the subject. Falls back to
    the original opaque image if the fill would erase most of the frame
    (a busy/high-contrast background where corner color != true background,
    e.g. the subject fills the frame edge-to-edge).
    """
    w, h = img.size
    px = img.load()
    bg = [[False] * w for _ in range(h)]
    corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    for cx, cy in corners:
        if bg[cy][cx]:
            continue
        ref = px[cx, cy][:3]
        dq = deque([(cx, cy)])
        bg[cy][cx] = True
        while dq:
            x, y = dq.popleft()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and not bg[ny][nx]:
                    r, g, b, _a = px[nx, ny]
                    if _color_dist((r, g, b), ref) <= tolerance:
                        bg[ny][nx] = True
                        dq.append((nx, ny))

    removed = sum(sum(row) for row in bg)
    if removed / (w * h) > max_remove:
        return img, False

    out = img.copy()
    opx = out.load()
    for y in range(h):
        for x in range(w):
            if bg[y][x]:
                r, g, b, _a = opx[x, y]
                opx[x, y] = (r, g, b, 0)
    return out, True


def premultiplied_downscale(img, size):
    """LANCZOS downscale that premultiplies alpha first.

    Plain LANCZOS on straight-alpha RGBA lets the (0,0,0,0) fill color of
    transparent pixels bleed a dark fringe into the resized edge -- exactly
    where the crisp pixel-art silhouette needs to be cleanest. Premultiplying
    before the resize and un-premultiplying after avoids that fringe.
    """
    w, h = img.size
    data = img.getdata()
    premult = [(r * a // 255, g * a // 255, b * a // 255, a) for (r, g, b, a) in data]
    pimg = Image.new("RGBA", (w, h))
    pimg.putdata(premult)
    resized = pimg.resize((size, size), Image.Resampling.LANCZOS)

    out = []
    for (r, g, b, a) in resized.getdata():
        if a > 0:
            out.append((min(255, r * 255 // a), min(255, g * 255 // a), min(255, b * 255 // a), a))
        else:
            out.append((0, 0, 0, 0))
    result = Image.new("RGBA", (size, size))
    result.putdata(out)
    return result


def quantize_preserving_alpha(img, colors):
    alpha = img.getchannel("A")
    rgb = img.convert("RGB").quantize(colors=max(2, colors)).convert("RGBA")
    rgb.putalpha(alpha)
    return rgb


def build_master(photo_path, colors, keep_bg):
    img = Image.open(photo_path)
    img = ImageOps.exif_transpose(img)
    img = img.convert("RGBA")
    img = center_crop_square(img)
    img = img.resize((WORK, WORK), Image.Resampling.LANCZOS)

    bg_removed = False
    if not keep_bg:
        img, bg_removed = remove_background(img)

    master = premultiplied_downscale(img, MASTER)
    master = quantize_preserving_alpha(master, colors)
    return master, bg_removed


# ---------------------------------------------------------------------------
# Frame helpers (all operate in 32px master space; upscale happens last)
# ---------------------------------------------------------------------------

def offset(master, dx=0, dy=0):
    # NOTE: uses alpha_composite, not paste(im, box, mask=im) -- pasting an
    # RGBA image using itself as the mask double-applies the alpha (each
    # pixel's alpha channel gets blended by ITS OWN alpha value too),
    # silently darkening every translucent/antialiased edge pixel.
    canvas = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    canvas.alpha_composite(master, dest=(dx, dy))
    return canvas


def add_outline(img, color=OUTLINE_COLOR):
    w, h = img.size
    alpha = img.getchannel("A")
    apx = alpha.load()
    out = img.copy()
    opx = out.load()
    for y in range(h):
        for x in range(w):
            if apx[x, y] != 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and apx[nx, ny] != 0:
                    opx[x, y] = color
                    break
    return out


def ghostify(img, target=GHOST_TARGET, blend=GHOST_BLEND, alpha=GHOST_ALPHA):
    """Pale, translucent "stale" look -- same blend formula as gen_sprites.py's
    build_palette(ghost=True), just applied to arbitrary RGBA pixels instead
    of a fixed palette dict."""
    tr, tg, tb = target
    out = []
    for (r, g, b, a) in img.getdata():
        if a == 0:
            out.append((0, 0, 0, 0))
            continue
        out.append((int(r + (tr - r) * blend), int(g + (tg - g) * blend), int(b + (tb - b) * blend), alpha))
    res = Image.new("RGBA", img.size)
    res.putdata(out)
    return res


BADGE_ANCHORS = {
    "top-right": (26, 6),
    "top-left": (6, 6),
}


def _threshold_alpha(layer):
    """Binarize the alpha channel so a font-rendered glyph keeps a crisp,
    stepped pixel-art edge instead of a soft anti-aliased fringe once it
    gets nearest-neighbor upscaled to the final cell size."""
    r, g, b, a = layer.split()
    a = a.point(lambda v: 255 if v >= 128 else 0)
    layer.putalpha(a)
    return layer


def badge_circle(glyph, glyph_color, backdrop_color, anchor="top-right", radius=6, size=11, dy=0):
    layer = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = BADGE_ANCHORS[anchor]
    cy += dy
    draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=backdrop_color)
    f = font(size)
    bbox = draw.textbbox((0, 0), glyph, font=f)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text((cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]), glyph, font=f, fill=glyph_color)
    return _threshold_alpha(layer)


def badge_check(anchor="top-right", radius=7, backdrop_color=GREEN, glyph_color=WHITE, dy=0):
    """Green "done" badge -- drawn as an actual checkmark stroke rather than
    the Arial Bold "✓" glyph, which Arial Bold doesn't contain (renders as
    an empty notdef box, not a check)."""
    layer = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = BADGE_ANCHORS[anchor]
    cy += dy
    draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=backdrop_color)
    draw.line([(cx - 3, cy), (cx - 1, cy + 3), (cx + 4, cy - 4)], fill=glyph_color, width=2, joint="curve")
    return _threshold_alpha(layer)


def badge_speech_bubble(glyph, glyph_color, backdrop_color, anchor="top-right", size=10, dy=0):
    """Small rounded-rect bubble with a tail, echoing gen_sprites.py's BUBBLE
    prop -- used for waiting_input so it reads as "typed reply wanted"
    rather than the plain circular "approve?" badge used for
    waiting_permission."""
    layer = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = BADGE_ANCHORS[anchor]
    cy += dy
    x0, y0, x1, y1 = cx - 7, cy - 6, cx + 7, cy + 4
    draw.rounded_rectangle([x0, y0, x1, y1], radius=3, fill=backdrop_color)
    draw.polygon([(cx - 2, y1 - 1), (cx + 2, y1 - 1), (cx - 1, y1 + 3)], fill=backdrop_color)
    f = font(size)
    bbox = draw.textbbox((0, 0), glyph, font=f)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cy_text = (y0 + y1) / 2
    draw.text((cx - tw / 2 - bbox[0], cy_text - th / 2 - bbox[1]), glyph, font=f, fill=glyph_color)
    return _threshold_alpha(layer)


def badge_dots(n, anchor="top-left", dot_color=BLUE, backdrop=(20, 20, 24, 235)):
    """"..."-style progress dots for `working`, filled circles (not text --
    a period glyph is too small to read at 32px) growing 1/2/3 across frames."""
    layer = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = BADGE_ANCHORS[anchor]
    draw.rounded_rectangle([cx - 8, cy - 4, cx + 8, cy + 4], radius=3, fill=backdrop)
    spacing = 5
    start = cx - spacing * (n - 1) / 2
    for i in range(n):
        dx = start + i * spacing
        draw.ellipse([dx - 1.2, cy - 1.2, dx + 1.2, cy + 1.2], fill=dot_color)
    return _threshold_alpha(layer)


def sparkle_mark(anchor, color=GOLD):
    layer = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = {"top-left": (2, 2), "bottom-right": (MASTER - 3, MASTER - 3)}[anchor]
    draw.line([(cx - 2, cy), (cx + 2, cy)], fill=color, width=1)
    draw.line([(cx, cy - 2), (cx, cy + 2)], fill=color, width=1)
    return layer


def composite(*layers):
    out = layers[0].copy()
    for layer in layers[1:]:
        out.alpha_composite(layer)
    return out


# ---------------------------------------------------------------------------
# The 7 states -- each returns a list of 32x32 RGBA frames
# ---------------------------------------------------------------------------

def state_idle(master):
    return [add_outline(offset(master, dy=d)) for d in (0, -1, 0)]


def state_working(master):
    frames = []
    for i, (dx, dy) in enumerate(((-1, 0), (0, -1), (1, 0))):
        base = add_outline(offset(master, dx=dx, dy=dy))
        frames.append(composite(base, badge_dots(i + 1)))
    return frames


def state_waiting_permission(master):
    frames = []
    for dy in (0, -1, 0):
        base = add_outline(offset(master))
        frames.append(composite(base, badge_circle("?", GOLD_TEXT, GOLD, dy=dy)))
    return frames


def state_waiting_input(master):
    frames = []
    for dy in (0, -1, 0):
        base = add_outline(offset(master))
        frames.append(composite(base, badge_speech_bubble("?", GOLD_TEXT, GOLD, dy=dy)))
    return frames


def state_done(master):
    frames = []
    sparkle_pattern = [("top-left", "bottom-right"), ("bottom-right", "top-left"), ("top-left", "bottom-right")]
    for i, dy in enumerate((0, -2, 0)):
        base = add_outline(offset(master, dy=dy))
        layers = [base, badge_check()]
        on, _off = sparkle_pattern[i]
        layers.append(sparkle_mark(on))
        frames.append(composite(*layers))
    return frames


def state_error(master):
    frames = []
    for dx in (-1, 0, 1):
        base = add_outline(offset(master, dx=dx))
        frames.append(composite(base, badge_circle("!", WHITE, RED, size=12)))
    return frames


def state_stale(master):
    return [ghostify(add_outline(offset(master, dy=d))) for d in (0, -1)]


STATE_BUILDERS = {
    "idle": state_idle,
    "working": state_working,
    "waiting_permission": state_waiting_permission,
    "waiting_input": state_waiting_input,
    "done": state_done,
    "error": state_error,
    "stale": state_stale,
}


# ---------------------------------------------------------------------------
# Sheet assembly + preview
# ---------------------------------------------------------------------------

def build_sheet(frames, cell):
    sheet = Image.new("RGBA", (cell * len(frames), cell), (0, 0, 0, 0))
    for i, frame in enumerate(frames):
        up = frame.resize((cell, cell), Image.Resampling.NEAREST)
        sheet.alpha_composite(up, dest=(i * cell, 0))
    return sheet


def label(draw, xy, text, size=16, fill=(255, 255, 255, 255)):
    draw.text(xy, text, font=font(size), fill=fill)


def build_preview(sheets, cell):
    scale = max(1, 200 // cell)
    pad = 20
    label_h = 24
    cols = 4
    max_frames = max(sheet.width // sheet.height for sheet in sheets.values())
    cell_w = cell * scale * max_frames + pad
    cell_h = cell * scale + label_h + pad
    rows = (len(STATES) + cols - 1) // cols

    canvas = Image.new("RGB", (pad + cols * cell_w, 40 + pad + rows * cell_h), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    label(draw, (pad, 6), "hatched character -- all 7 states", size=18)

    for idx, state in enumerate(STATES):
        r, c = divmod(idx, cols)
        x = pad + c * cell_w
        y = 40 + pad + r * cell_h
        sheet = sheets[state]
        n = sheet.width // sheet.height
        big = sheet.resize((sheet.width * scale, sheet.height * scale), Image.Resampling.NEAREST)
        canvas.paste(big, (x, y), big)
        label(draw, (x, y + sheet.height * scale + 2), f"{state} ({n}f)", size=14)

    return canvas


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def hatch(photo_path, name, out_dir, cell, colors, keep_bg):
    master, bg_removed = build_master(photo_path, colors, keep_bg)

    pack_dir = os.path.join(out_dir, name)
    os.makedirs(pack_dir, exist_ok=True)

    sheets = {}
    for state in STATES:
        frames = STATE_BUILDERS[state](master)
        sheet = build_sheet(frames, cell)
        sheet.save(os.path.join(pack_dir, f"{state}.png"))
        sheets[state] = sheet

    preview = build_preview(sheets, cell)
    preview.save(os.path.join(pack_dir, "preview.png"))

    return pack_dir, sheets, bg_removed


def main():
    args = parse_args()
    if not os.path.isfile(args.photo):
        print(f"error: no such file: {args.photo}", file=sys.stderr)
        sys.exit(1)

    name = slugify(args.name) if args.name else slugify(os.path.splitext(os.path.basename(args.photo))[0])
    out_dir = os.path.expanduser(args.out_dir)

    pack_dir, sheets, bg_removed = hatch(args.photo, name, out_dir, args.cell, args.colors, args.keep_bg)

    print(f"hatched '{name}' -> {pack_dir}")
    print(f"background removed: {bg_removed}" if not args.keep_bg else "background: kept (--keep-bg)")
    for state in STATES:
        n = sheets[state].width // sheets[state].height
        print(f"  {state}.png: {n} frames, {sheets[state].size[0]}x{sheets[state].size[1]}")
    print(f"  preview.png")
    print()
    print(f"Select it via the NotchOtter menu bar -> Character -> {name}")


if __name__ == "__main__":
    main()
