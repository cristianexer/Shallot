"""Shallot app icon — a digital shallot.

An onion in cross-section, filled with the app's own blood-red digital rain.
The silhouette is what reads at 60pt; the falling glyphs inside it are what
make it Shallot's onion rather than any onion, and they are drawn with the
same glyph set, column pitch and two-tone head/trail treatment as
`DesignSystem/RainView.swift`.

The rain is masked to the silhouette, so the columns appear to fall *through*
the onion. Layer outlines are drawn over the top at low opacity so the
cross-section still reads once the glyphs are too small to resolve.

Rendered at 4x and downsampled with Lanczos. Run from the repository root:

    python3 Tools/make-app-icon.py
"""
import math
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 1024
F = 4
N = S * F

VOID = (0x0A, 0x02, 0x06)
DEEP = (0x8B, 0x00, 0x00)  # trail
RAIN = (0xFF, 0x2B, 0x45)  # head
ARTERIAL = (0xFF, 0x12, 0x3D)  # outline and core

MOTIF_EXTENT = N * 0.74  # ~13% of the canvas as margin on every side
LAYERS = 4
STEP = 0.70  # each layer is this fraction of the one outside it

# The rain, matched to RainView: same alphabet, same relative column pitch.
GLYPHS = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾﾀﾁﾂﾃﾅﾆﾇﾊﾋﾌﾍﾎ0123456789ABCDEFxX#<>/█▓"
CELL = N // 34
TRAIL = 9

# Deterministic: the icon must be byte-identical on every run, or it shows up
# as a spurious diff every time anyone regenerates it.
random.seed(20260829)


def onion(scale, samples=2400):
    """The tear-drop curve rotated so its point is at the top and squashed so
    the bulb is wider than it is tall — which is what makes it read as an onion
    rather than a raindrop."""
    return [
        (-math.sin(t) * (math.sin(t / 2) ** 2) * 1.30 * scale, math.cos(t) * 0.95 * scale)
        for t in (2 * math.pi * i / samples for i in range(samples))
    ]


_base = onion(1.0)
_xs = [p[0] for p in _base]
_ys = [p[1] for p in _base]
_span = max(max(_xs) - min(_xs), max(_ys) - min(_ys))
_k = MOTIF_EXTENT / _span
_mid_x = (max(_xs) + min(_xs)) / 2
_mid_y = (max(_ys) + min(_ys)) / 2


def place(points):
    return [
        (N / 2 + (x - _mid_x) * _k, N / 2 - (y - _mid_y) * _k - N * 0.02)
        for x, y in points
    ]


def load_font(size):
    """SF Mono for the latin glyphs, with Hiragino for the half-width katakana
    SF Mono has none of — the same substitution the real rain view gets."""
    for path in (
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Supplemental/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def load_kana_font(size):
    for path in (
        "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/Supplemental/Osaka.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return None


FONT = load_font(int(CELL * 0.92))
KANA = load_kana_font(int(CELL * 0.86)) or FONT


def font_for(glyph):
    return KANA if ord(glyph) > 0x2500 else FONT


# --- The canvas -------------------------------------------------------------

img = Image.new("RGB", (N, N), VOID)

# A faint pool of red behind the motif: depth on a dark home screen, stopping
# well short of a glow.
halo = Image.new("L", (N, N), 0)
ImageDraw.Draw(halo).ellipse(
    [N * 0.14, N * 0.16, N * 0.86, N * 0.88], fill=70
)
halo = halo.filter(ImageFilter.GaussianBlur(N * 0.10))
img = Image.composite(Image.new("RGB", (N, N), (0x2A, 0x04, 0x10)), img, halo)

# --- The rain, on its own layer ---------------------------------------------

rain = Image.new("RGB", (N, N), (0, 0, 0))
rain_draw = ImageDraw.Draw(rain)

columns = N // CELL + 1
rows = N // CELL + 1
offset_x = (N - columns * CELL) / 2

# A dim bed first, so no part of the onion is empty. This is the same treatment
# the rain view falls back to under Reduce Motion: a static field rather than a
# few lonely columns.
for column in range(columns):
    for row in range(rows):
        if random.random() > 0.62:
            continue
        glyph = random.choice(GLYPHS)
        fade = random.uniform(0.30, 0.62)
        rain_draw.text(
            (column * CELL + offset_x, row * CELL),
            glyph,
            font=font_for(glyph),
            fill=tuple(round(c * fade) for c in DEEP),
            anchor="mt",
        )

# Then the falling heads over the top, each with its trail — the part that says
# this is rain and not texture.
for column in range(columns):
    x = column * CELL + offset_x
    for _ in range(random.choice((1, 1, 2))):
        head_row = random.randrange(rows)
        for step in range(TRAIL):
            row = head_row - step
            if row < 0:
                break
            glyph = random.choice(GLYPHS)
            if step == 0:
                colour = RAIN
            else:
                fade = max(0.26, 1.0 - step * 0.09)
                colour = tuple(round(c * fade) for c in DEEP)
            rain_draw.text(
                (x, row * CELL), glyph, font=font_for(glyph), fill=colour, anchor="mt"
            )

# --- Mask the rain to the silhouette ----------------------------------------


def silhouette_mask(scale):
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).polygon(place(onion(scale)), fill=255)
    return mask


silhouette = silhouette_mask(1.0)

# Softening the mask by a hair stops the glyphs being sliced with a hard edge
# at the silhouette's boundary, which at icon sizes reads as jagged.
img = Image.composite(rain, img, silhouette.filter(ImageFilter.GaussianBlur(N * 0.003)))

# --- The cross-section, over the rain ---------------------------------------

# Each ring is the difference of two filled silhouettes rather than a stroked
# polygon: a stroke over a 2400-point path stitches visibly at this scale, and
# the difference also lets the walls meet cleanly at the neck.


def ring(scale, thickness):
    return ImageChops.subtract(silhouette_mask(scale), silhouette_mask(scale * (1 - thickness)))


def paint(mask, colour, opacity=1.0):
    global img
    if opacity < 1.0:
        mask = mask.point(lambda value: round(value * opacity))
    img = Image.composite(Image.new("RGB", (N, N), colour), img, mask)


# Outer edge: crisp and bright, because this is the shape that survives being
# shrunk to a home-screen icon.
paint(ring(1.0, 0.030), ARTERIAL)

# Inner layers: progressively dimmer, so they read as depth rather than as
# competing outlines.
for layer in range(1, LAYERS):
    paint(ring(STEP**layer, 0.030), ARTERIAL, opacity=0.82 - layer * 0.17)

overlay = Image.new("RGBA", (N, N), (0, 0, 0, 0))
overlay_draw = ImageDraw.Draw(overlay)

# No sprout at the neck: strokes splaying from the point converge into
# something that reads as a downward arrow at icon sizes, which is worse than
# the plain silhouette. The nested rings are what say "onion in cross-section".

# The core, so the centre has somewhere for the eye to land.
core = N * 0.028
centre_x, centre_y = N / 2, N / 2 + N * 0.06
overlay_draw.ellipse(
    [centre_x - core, centre_y - core, centre_x + core, centre_y + core],
    fill=RAIN + (255,),
)

img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")

# --- Down to size -----------------------------------------------------------

icon = img.resize((S, S), Image.LANCZOS)
icon.save("Shallot/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
print("wrote Shallot/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
