"""Shallot app icon.

An onion in cross-section: five nested tear-drop layers in the app's blood-red
ramp on the near-black void, centred with a generous margin.

Every layer is drawn as the difference of two filled outlines rather than as a
thick stroke, so the layers meet cleanly at the neck instead of fraying there.
Rendered at 8x and downsampled with Lanczos. Run from the repository root:

    python3 Tools/make-app-icon.py
"""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
F = 8
N = S * F

VOID = (0x0A, 0x02, 0x06)
DEEP = (0x8B, 0x00, 0x00)      # outermost layer
ARTERIAL = (0xFF, 0x12, 0x3D)  # innermost layer and core

MOTIF_EXTENT = N * 0.70        # ~15% of the canvas as margin on every side
LAYERS = 5
STEP = 0.745                   # each layer is this fraction of the one outside it
THICKNESS = 0.072              # layer wall, as a fraction of the layer's own size


def lerp(colour_a, colour_b, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(colour_a, colour_b))


def onion(scale, samples=3000):
    """The tear-drop curve rotated so its point is at the top and squashed so
    the bulb is wider than it is tall — which is what makes it read as an onion
    rather than a raindrop."""
    return [
        (-math.sin(t) * (math.sin(t / 2) ** 2) * 1.30 * scale, math.cos(t) * 0.95 * scale)
        for t in (2 * math.pi * i / samples for i in range(samples))
    ]


base = onion(1.0)
xs = [p[0] for p in base]
ys = [p[1] for p in base]
span = max(max(xs) - min(xs), max(ys) - min(ys))
k = MOTIF_EXTENT / span
mid_x = (max(xs) + min(xs)) / 2
mid_y = (max(ys) + min(ys)) / 2


def place(points):
    return [(N / 2 + (x - mid_x) * k, N / 2 - (y - mid_y) * k - N * 0.018) for x, y in points]


img = Image.new("RGB", (N, N), VOID)

# A faint pool of red behind the motif: depth on a dark home screen, stopping
# well short of a glow.
halo = Image.new("L", (N, N), 0)
ImageDraw.Draw(halo).ellipse(
    [N / 2 - MOTIF_EXTENT * 0.60, N / 2 - MOTIF_EXTENT * 0.60,
     N / 2 + MOTIF_EXTENT * 0.60, N / 2 + MOTIF_EXTENT * 0.60],
    fill=54,
)
halo = halo.filter(ImageFilter.GaussianBlur(N * 0.06))
img = Image.composite(Image.new("RGB", (N, N), (0x42, 0x00, 0x0F)), img, halo)

draw = ImageDraw.Draw(img)
scale = 1.0
for index in range(LAYERS):
    t = index / (LAYERS - 1)
    draw.polygon(place(onion(scale)), fill=lerp(DEEP, ARTERIAL, t ** 0.7))
    scale *= 1 - THICKNESS
    draw.polygon(place(onion(scale)), fill=VOID)
    scale *= STEP

# The core, sitting inside the innermost layer.
r = MOTIF_EXTENT * 0.036
cx, cy = place([(0.0, -0.035)])[0]
draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ARTERIAL)

img.resize((S, S), Image.LANCZOS).save(
    "/Users/cristianexer/Hyperdrive/Shallot/Shallot/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    format="PNG", optimize=True,
)
print("written")
