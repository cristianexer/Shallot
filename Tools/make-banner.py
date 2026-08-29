"""Shallot README banner — an animated GIF of the app's own digital rain.

This is a faithful port of `DesignSystem/RainView.swift`: the same glyph set,
the same two-tone head-and-trail treatment, the same per-step opacity ramp, the
same 11 Hz glyph flicker, and the same deterministic hash, so a column always
shows the same character for a given tick. The backdrop is the same gradient
and vignette as `ShallotBackdrop`, in the palette from `Tokens.swift`.

One thing is deliberately not faithful: the fall speeds. RainView picks
40–95 pt/s, which on a 400-pixel banner takes six to fourteen seconds for a
column to cross — far too long for a GIF that has to stay under a few megabytes.
The speeds here are instead snapped to `span * k / LOOP`, k in 1...3, which is
what makes the loop *exactly* seamless: after LOOP seconds every column has
travelled a whole number of spans and the flicker clock has wrapped, so the last
frame hands over to the first with no jump at all.

Run from the repository root:

    python3 Tools/make-banner.py
"""
import math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = "docs/banner.gif"

WIDTH, HEIGHT = 1280, 400
LOOP = 4.0          # seconds; the whole animation repeats exactly here
FRAMES = 50         # 50 frames x 80 ms = 4.0 s
DELAY_MS = 80

# ---- DesignSystem/Tokens.swift -------------------------------------------
VOID = (10, 2, 6)
VOID_LIFT = (42, 4, 16)
VOID_DEEP = (5, 1, 3)
BLOOD = (139, 0, 0)
ARTERIAL = (255, 18, 61)
RAIN = (255, 43, 69)
BONE = (244, 233, 236)
ASH = (163, 119, 127)

# ---- DesignSystem/RainView.swift -----------------------------------------
GLYPHS = list("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾﾀﾁﾂﾃﾅﾆﾇﾊﾋﾌﾍﾎ0123456789ABCDEFxX#<>/█▓")
CELL = 22
TRAIL = 7
RAIN_OPACITY = 0.55   # RainView's own .opacity(0.55)
FLICKER_HZ = 11

# SF Mono is the app's chrome face but has no half-width katakana, so the
# katakana are drawn in Hiragino — which is the same substitution the system
# makes for the real view.
MONO = "/System/Library/Fonts/SFNSMono.ttf"
KANA = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"


def mono(size, weight="Semibold"):
    font = ImageFont.truetype(MONO, size)
    try:
        font.set_variation_by_name(weight)
    except Exception:
        pass
    return font


rain_font = mono(CELL, "Semibold")
kana_font = ImageFont.truetype(KANA, CELL)


def hash2(a, b):
    """RainView.hash(_:_:) — the same mixing function, so the same cell shows
    the same glyph for a given tick and the pattern does not shimmer."""
    value = (a * 0x9E3779B1 + b * 0x85EBCA77) & 0xFFFFFFFFFFFFFFFF
    value ^= value >> 33
    value = (value * 0xFF51AFD7ED558CCD) & 0xFFFFFFFFFFFFFFFF
    value ^= value >> 33
    return value % 0x7FFFFFFFFFFFFFFF


def font_for(glyph):
    return kana_font if ord(glyph) >= 0xFF61 else rain_font


# ---------------------------------------------------------------------------
# Backdrop: the ShallotBackdrop gradient, plus a vignette so the wordmark reads.
# ---------------------------------------------------------------------------
def make_backdrop():
    image = Image.new("RGB", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    top = tuple(round(lift * 0.55 + base * 0.45) for lift, base in zip(VOID_LIFT, VOID))
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        if t < 0.5:
            u = t / 0.5
            colour = tuple(round(a + (b - a) * u) for a, b in zip(top, VOID))
        else:
            u = (t - 0.5) / 0.5
            colour = tuple(round(a + (b - a) * u) for a, b in zip(VOID, VOID_DEEP))
        draw.line([(0, y), (WIDTH, y)], fill=colour)
    return image


def make_vignette():
    """Darkens the edges so the glass-layer type reads against the rain —
    ShallotBackdrop's radial gradient, adapted to a wide frame."""
    mask = Image.new("L", (WIDTH, HEIGHT), 0)
    draw = ImageDraw.Draw(mask)
    steps = 90
    for i in range(steps):
        t = i / (steps - 1)
        inset_x = WIDTH * 0.5 * t
        inset_y = HEIGHT * 0.62 * t
        draw.ellipse(
            [inset_x - WIDTH * 0.10, inset_y - HEIGHT * 0.18,
             WIDTH - inset_x + WIDTH * 0.10, HEIGHT - inset_y + HEIGHT * 0.18],
            fill=round(235 * (1 - t) ** 1.6),
        )
    mask = Image.eval(mask, lambda v: 235 - v)
    return mask.filter(ImageFilter.GaussianBlur(40))


def tracked(draw, text, font, x, y, fill, tracking):
    """Draws letter-spaced text and returns the width it occupied."""
    cursor = x
    for character in text:
        draw.text((cursor, y), character, font=font, fill=fill)
        cursor += draw.textlength(character, font=font) + tracking
    return cursor - tracking - x


def tracked_width(draw, text, font, tracking):
    return sum(draw.textlength(c, font=font) for c in text) + tracking * (len(text) - 1)


# ---------------------------------------------------------------------------
# The wordmark, rendered once: bone type over an arterial glow.
# ---------------------------------------------------------------------------
def make_wordmark():
    layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    title_font = mono(112, "Bold")
    tag_font = mono(24, "Regular")
    title, tracking = "SHALLOT", 22
    tagline, tag_tracking = "Onion routing, wrapped in glass.", 5

    title_width = tracked_width(draw, title, title_font, tracking)
    tag_width = tracked_width(draw, tagline, tag_font, tag_tracking)

    title_y = HEIGHT * 0.30
    tag_y = title_y + 148

    # The glow: the same letterforms, blurred and tinted arterial.
    glow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    tracked(glow_draw, title, title_font, (WIDTH - title_width) / 2, title_y,
            ARTERIAL + (255,), tracking)
    glow = glow.filter(ImageFilter.GaussianBlur(26))
    glow.putalpha(glow.getchannel("A").point(lambda v: min(255, int(v * 1.9))))

    # A hairline rule either side of the tagline, in the app's accent.
    rule_y = round(tag_y + 12)
    gap = tag_width / 2 + 34
    for direction in (-1, 1):
        start = WIDTH / 2 + direction * gap
        end = start + direction * 150
        draw.line([(start, rule_y), (end, rule_y)], fill=ARTERIAL + (110,), width=2)

    tracked(draw, title, title_font, (WIDTH - title_width) / 2, title_y, BONE + (255,), tracking)
    tracked(draw, tagline, tag_font, (WIDTH - tag_width) / 2, tag_y, ASH + (255,), tag_tracking)

    return Image.alpha_composite(glow, layer)


# ---------------------------------------------------------------------------
# One frame of rain, straight out of RainView.draw(in:size:seconds:).
# ---------------------------------------------------------------------------
SPAN = HEIGHT + TRAIL * CELL
COLUMNS = math.ceil(WIDTH / CELL)
# span * k / LOOP: a whole number of spans per loop, so the GIF wraps exactly.
SPEEDS = [SPAN * (1 + hash2(column, 7) % 3) / LOOP for column in range(COLUMNS)]
OFFSETS = [hash2(column, 13) % 1000 / 1000 * SPAN for column in range(COLUMNS)]


def make_rain(seconds):
    layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    flicker = int(seconds * FLICKER_HZ) % int(LOOP * FLICKER_HZ)

    for column in range(COLUMNS):
        travelled = seconds * SPEEDS[column] + OFFSETS[column]
        head_y = travelled % SPAN - TRAIL * CELL
        x = column * CELL

        for step in range(TRAIL):
            y = head_y - step * CELL
            if y <= -CELL or y >= HEIGHT:
                continue
            row = math.floor(y / CELL)
            index = hash2(column * 31 + row, flicker + step) % len(GLYPHS)
            glyph = GLYPHS[index]
            is_head = step == 0
            opacity = 1.0 if is_head else max(0.06, 0.55 - step * 0.08)
            colour = RAIN if is_head else BLOOD
            alpha = round(255 * opacity * (1.0 if is_head else 0.85))
            draw.text((x, y), glyph, font=font_for(glyph), fill=colour + (alpha,))

    layer.putalpha(layer.getchannel("A").point(lambda v: round(v * RAIN_OPACITY)))
    return layer


def main():
    backdrop = make_backdrop()
    vignette = make_vignette()
    wordmark = make_wordmark()
    shadow = Image.new("RGB", (WIDTH, HEIGHT), VOID_DEEP)

    frames = []
    for index in range(FRAMES):
        seconds = LOOP * index / FRAMES
        frame = backdrop.copy()
        frame.paste(Image.alpha_composite(frame.convert("RGBA"), make_rain(seconds)).convert("RGB"))
        frame = Image.composite(shadow, frame, vignette)
        frame = Image.alpha_composite(frame.convert("RGBA"), wordmark).convert("RGB")
        frames.append(frame.quantize(colors=96, method=Image.MEDIANCUT, dither=Image.Dither.NONE))

    frames[0].save(
        OUT,
        save_all=True,
        append_images=frames[1:],
        duration=DELAY_MS,
        loop=0,
        optimize=True,
        disposal=1,
    )
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
