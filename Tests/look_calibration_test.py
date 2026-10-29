"""Checks the develop looks in Phi/Camera/LookRecipe.swift and the edit effects.

Neutrals stay near neutral (chroma under 6, and ΔE under 8 for 正片 and CCD).
Memory-color hue stays within 10°.

Grain at FINE, 光晕, EV, and 无 are checked against Phi/Camera/StillPipeline.swift.
Grain is zero-mean luminance in linear light: a gray patch stays neutral and its
mean color stays within ΔE 1. 无 is identity. 光晕 and EV do not rotate hue.
Run: python3 Tests/look_calibration_test.py
"""

import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Phi/Camera/LookRecipe.swift").read_text()
STILL = (ROOT / "Phi/Camera/StillPipeline.swift").read_text()
LOOKS_SWIFT = (ROOT / "Phi/Camera/ColorLooks.swift").read_text()
GRAIN_SWIFT = (ROOT / "Phi/Camera/GrainStyle.swift").read_text()
RAW_SWIFT = (ROOT / "Phi/Camera/RawDevelop.swift").read_text()
META_SWIFT = (ROOT / "Phi/Camera/PhotoMetadata.swift").read_text()


def clamp(value):
    return max(0.0, min(1.0, value))


def smooth(edge0, edge1, value):
    span = edge1 - edge0
    if span == 0:
        return 0.0 if value < edge0 else 1.0
    t = max(0.0, min(1.0, (value - edge0) / span))
    return t * t * (3 - 2 * t)


def curve_value(value, points):
    x = clamp(value)
    if x <= points[0][0]:
        return points[0][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x <= x1:
            span = x1 - x0
            t = 0 if span == 0 else (x - x0) / span
            return y0 + t * (y1 - y0)
    return points[-1][1]


def apply(recipe, red, green, blue):
    r, g, b = red, green, blue
    if recipe["mono"]:
        y = 0.45 * r + 0.42 * g + 0.13 * b
        r = g = b = y
    r, g, b = (curve_value(c, recipe["curve"]) for c in (r, g, b))
    m = recipe["matrix"]
    rr = m[0] * r + m[1] * g + m[2] * b
    gg = m[3] * r + m[4] * g + m[5] * b
    bb = m[6] * r + m[7] * g + m[8] * b
    luma = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
    sat = recipe["saturation"]
    r = luma + sat * (rr - luma)
    g = luma + sat * (gg - luma)
    b = luma + sat * (bb - luma)
    contrast = recipe["contrast"]
    r = (r - 0.5) * contrast + 0.5
    g = (g - 0.5) * contrast + 0.5
    b = (b - 0.5) * contrast + 0.5
    tone = 0.2126 * r + 0.7152 * g + 0.0722 * b
    shadow = smooth(0.02, 0.16, tone) * (1 - smooth(0.16, 0.48, tone))
    highlight = smooth(0.58, 0.78, tone) * (1 - smooth(0.90, 0.99, tone))
    sr, sg, sb = recipe["shadow"]
    hr, hg, hb = recipe["highlight"]
    r += sr * shadow + hr * highlight
    g += sg * shadow + hg * highlight
    b += sb * shadow + hb * highlight
    return clamp(r), clamp(g), clamp(b)


def lab(red, green, blue):
    def linear(channel):
        return max(channel, 0) ** 2.2

    r, g, b = linear(red), linear(green), linear(blue)
    x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116

    fx, fy, fz = f(x / 0.95047), f(y / 1), f(z / 1.08883)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def delta_e(a, b):
    return math.dist(lab(*a), lab(*b))


def chroma(rgb):
    _, a, b = lab(*rgb)
    return math.hypot(a, b)


def hue_delta(a, b):
    _, aa, ab = lab(*a)
    _, ba, bb = lab(*b)
    delta = abs(math.degrees(math.atan2(bb, ba) - math.atan2(ab, aa)))
    if delta > 180:
        delta = 360 - delta
    return delta


LOOKS = {
    "正片": {
        "matrix": [1.03, -0.015, -0.015, -0.01, 1.02, -0.01, -0.01, 0.00, 1.01],
        "curve": [(0, 0.025), (0.25, 0.24), (0.50, 0.51), (0.75, 0.77), (1, 0.985)],
        "saturation": 1.08,
        "contrast": 1.03,
        "shadow": (-0.018, 0.008, 0.030),
        "highlight": (0.028, 0.006, -0.020),
        "mono": False,
    },
    "负片": {
        "matrix": [1.01, 0.01, -0.02, 0.00, 0.99, 0.01, -0.02, 0.01, 1.01],
        "curve": [(0, 0.035), (0.22, 0.26), (0.50, 0.51), (0.78, 0.76), (1, 0.96)],
        "saturation": 0.90,
        "contrast": 0.96,
        "shadow": (-0.010, 0.008, 0.028),
        "highlight": (0.020, 0.004, -0.012),
        "mono": False,
    },
    "黑白": {
        "matrix": [1, 0, 0, 0, 1, 0, 0, 0, 1],
        "curve": [(0, 0.04), (0.25, 0.23), (0.50, 0.50), (0.75, 0.78), (1, 0.98)],
        "saturation": 1,
        "contrast": 1,
        "shadow": (0, 0, 0),
        "highlight": (0, 0, 0),
        "mono": True,
    },
    "CCD": {
        "matrix": [1.02, -0.03, 0.01, -0.02, 1.04, -0.02, 0.00, -0.02, 1.02],
        "curve": [(0, 0.03), (0.22, 0.21), (0.50, 0.52), (0.78, 0.80), (1, 0.97)],
        "saturation": 1.10,
        "contrast": 1.05,
        "shadow": (-0.008, 0.012, 0.016),
        "highlight": (-0.012, 0.022, 0.010),
        "mono": False,
    },
}

SAMPLES = [
    ("grey 0.05", (0.05, 0.05, 0.05), True),
    ("grey 0.20", (0.20, 0.20, 0.20), True),
    ("grey 0.50", (0.50, 0.50, 0.50), True),
    ("grey 0.80", (0.80, 0.80, 0.80), True),
    ("grey 0.96", (0.96, 0.96, 0.96), True),
    ("skin", (0.86, 0.62, 0.48), False),
    ("sky", (0.36, 0.58, 0.86), False),
    ("orange", (0.93, 0.48, 0.14), False),
    ("foliage", (0.28, 0.50, 0.18), False),
    ("red", (0.78, 0.14, 0.12), False),
]


def unit_hash(x, y, seed):
    n = (x * 374761393) & 0xFFFFFFFF
    n = (n + ((y * 668265263) & 0xFFFFFFFF)) & 0xFFFFFFFF
    n = (n + seed) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return (n & 0x00FFFFFF) / float(0x00FFFFFF)


def grain_step(width, tile_fraction, tile_side):
    raw = max(width, 1) * tile_fraction / tile_side
    whole = int(raw)
    step = whole + 1 if raw - whole >= 0.5 else whole
    return max(step, 1)


def signed_unit(x, y, seed, cell, step):
    safe_step = max(step, 1)
    safe_cell = max(cell, 1)
    unit = unit_hash((x // safe_step) // safe_cell, (y // safe_step) // safe_cell, seed)
    return (unit - 0.5) * 2


def balanced(noise):
    if not noise:
        return noise
    mean = sum(noise) / len(noise)
    shifted = [sample - mean for sample in noise]
    peak = max(abs(sample) for sample in shifted)
    if peak > 1:
        shifted = [sample / peak for sample in shifted]
    return shifted


def rec709(rgb):
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]


def grain_pixel(rgb, noise, amplitude):
    """Zero-mean luma grain in Display P3 code values, matching `GrainField.encoded`."""
    display = tuple(srgb_encode(channel) for channel in rgb)
    y = rec709(display)
    peak = max(display)
    high = y * (1.0 - peak) / peak if peak > 0.0001 else 0.0
    room = min(y, max(high, 0.0))
    delta = noise * min(amplitude, max(room, 0.0))
    factor = 1.0 if y <= 0.0001 else (y + delta) / y
    return tuple(srgb_decode(channel * factor) for channel in display)


def halo_pixel(rgb, amount, points):
    glow = tuple(curve_value(channel, points) for channel in rgb)
    y = rec709(rgb)
    glow_luma = rec709(glow)
    delta = amount * max(glow_luma, 0.0) * max(0.0, 1.0 - y)
    room = max(0.0, 1.0 - y)
    delta = min(delta, room)
    factor = 1.0 if y <= 0.0001 else (y + delta) / y
    return tuple(channel * factor for channel in rgb)


def exposure_pixel(rgb, ev):
    gain = 2.0 ** ev
    return tuple(channel * gain for channel in rgb)


def srgb_encode(channel):
    channel = clamp(channel)
    if channel <= 0.0031308:
        return 12.92 * channel
    return 1.055 * (channel ** (1.0 / 2.4)) - 0.055


def srgb_decode(channel):
    channel = clamp(channel)
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def display_quantize(channel):
    return round(srgb_encode(channel) * 255.0) / 255.0


def mean_rgb(pixels):
    count = float(len(pixels))
    return tuple(sum(pixel[channel] for pixel in pixels) / count for channel in range(3))


def parse_grain():
    import re

    profile = re.search(
        r"GrainProfile\(seed:\s*(0x[0-9A-Fa-f_]+),\s*cell:\s*(\d+),\s*amplitude:\s*([0-9.]+),\s*tileFraction:\s*([0-9.]+)\)",
        GRAIN_SWIFT,
    )
    side = re.search(r"static let tileSide = (\d+)", STILL)
    halo = re.search(r"static let haloMix: CGFloat = ([0-9.]+)", LOOKS_SWIFT)
    if not profile or not side or not halo:
        return None
    return {
        "seed": int(profile.group(1).replace("_", ""), 16),
        "cell": int(profile.group(2)),
        "amplitude": float(profile.group(3)),
        "tile_fraction": float(profile.group(4)),
        "tile_side": int(side.group(1)),
        "halo_mix": float(halo.group(1)),
    }


HALO_CURVE = [(0.00, 0.00), (0.80, 0.00), (0.88, 0.35), (0.94, 0.72), (1.00, 1.00)]


def grain_image(rgb, width, height, spec):
    step = grain_step(width, spec["tile_fraction"], spec["tile_side"])
    field = [
        signed_unit(x, y, spec["seed"], spec["cell"], step)
        for y in range(height)
        for x in range(width)
    ]
    field = balanced(field)
    return [grain_pixel(rgb, noise, spec["amplitude"]) for noise in field]


def check_effects(failures):
    spec = parse_grain()
    if spec is None:
        failures.append("grain profile, tileSide, or haloMix missing")
        return
    if "CIGammaAdjust" in STILL:
        failures.append("StillPipeline still applies CIGammaAdjust on top of the linear working space")
    if "CIOverlayBlendMode" in STILL:
        failures.append("StillPipeline still blends grain with CIOverlayBlendMode")
    if "CIScreenBlendMode" in LOOKS_SWIFT:
        failures.append("highlight diffusion still uses CIScreenBlendMode")
    if "baseFilm" in LOOKS_SWIFT or "includeBase" in LOOKS_SWIFT + STILL + RAW_SWIFT:
        failures.append("无 still applies a base film grade")
    for marker in (
        "CIContextOption.workingColorSpace: linearP3",
        "CIContextOption.outputColorSpace: displayP3",
        "colorSpace: displayP3",
        "colorSpace: linearP3",
        "(y + delta) / y",
        "0.2126 * red + 0.7152 * green + 0.0722 * blue",
        "static let tileSide = 256",
    ):
        if marker not in STILL:
            failures.append(f"StillPipeline missing {marker}")
    if "max(glowLuma, 0) * max(0, 1 - y)" not in STILL:
        failures.append("highlight add is not luminance")
    if "CIImageOption.colorSpace: StillPipeline.linearP3" not in LOOKS_SWIFT:
        failures.append("CCD texture is not tagged extended-linear")
    if "sRGB" in META_SWIFT or "sRGB" in STILL:
        failures.append("HEIF export path mentions sRGB")
    for point in ("(0.80, 0.00)", "(0.88, 0.35)", "(0.94, 0.72)"):
        if point not in LOOKS_SWIFT:
            failures.append(f"highlight curve missing {point}")
    if spec["amplitude"] <= 0 or spec["amplitude"] > 0.12:
        failures.append(f"FINE amplitude {spec['amplitude']} is not a fine grain")

    width = height = 96
    gray_levels = (0.05, 0.20, 0.50, 0.80, 0.96)
    colors = ((0.62, 0.28, 0.16), (0.18, 0.34, 0.62), (0.20, 0.46, 0.16))
    worst_grain = 0.0
    for display in gray_levels:
        linear = tuple(srgb_decode(display) for _ in range(3))
        grained = grain_image(linear, width, height, spec)
        shown = [tuple(srgb_encode(channel) for channel in pixel) for pixel in grained]
        shown_mean = mean_rgb(shown)
        spread = max(shown_mean) - min(shown_mean)
        if spread > 1e-6:
            failures.append(f"grain grey {display:.2f} mean is not neutral {shown_mean}")
        for channel in range(3):
            if abs(shown_mean[channel] - display) > 1e-4:
                failures.append(
                    f"grain grey {display:.2f} display mean shifted {shown_mean[channel] - display:+.6f}"
                )
        encoded = [tuple(display_quantize(channel) for channel in pixel) for pixel in grained]
        encoded_mean = mean_rgb(encoded)
        original = tuple(display_quantize(srgb_decode(display)) for _ in range(3))
        delta = delta_e(original, encoded_mean)
        worst_grain = max(worst_grain, delta)
        if delta >= 1:
            failures.append(f"grain grey {display:.2f} ΔE {delta:.3f}")
        if chroma(encoded_mean) > 0.5:
            failures.append(f"grain grey {display:.2f} chroma {chroma(encoded_mean):.3f}")
        quadrant = width // 2
        for y0 in (0, quadrant):
            for x0 in (0, quadrant):
                patch = [
                    encoded[(y * width) + x]
                    for y in range(y0, y0 + quadrant)
                    for x in range(x0, x0 + quadrant)
                ]
                patch_delta = delta_e(original, mean_rgb(patch))
                worst_grain = max(worst_grain, patch_delta)
                if patch_delta >= 1:
                    failures.append(f"grain grey {display:.2f} patch @{x0},{y0} ΔE {patch_delta:.3f}")
    for linear in colors:
        grained = grain_image(linear, width, height, spec)
        original_display = tuple(srgb_encode(channel) for channel in linear)
        shown_mean = mean_rgb([tuple(srgb_encode(channel) for channel in pixel) for pixel in grained])
        for channel in range(3):
            if abs(shown_mean[channel] - original_display[channel]) > 1e-4:
                failures.append(f"grain color mean shifted {shown_mean}")
        if hue_delta(original_display, shown_mean) > 0.5:
            failures.append(f"grain color hue {hue_delta(original_display, shown_mean):.2f}")
        if delta_e(original_display, shown_mean) >= 1:
            failures.append(f"grain color ΔE {delta_e(original_display, shown_mean):.3f}")

    for display in gray_levels:
        linear = tuple(srgb_decode(display) for _ in range(3))
        bloomed = halo_pixel(linear, spec["halo_mix"], HALO_CURVE)
        if max(bloomed) - min(bloomed) > 1e-6:
            failures.append(f"halo grey {display:.2f} picked up chroma {bloomed}")
        if linear[0] < 0.80:
            if max(abs(bloomed[channel] - linear[channel]) for channel in range(3)) > 1e-6:
                failures.append(f"halo grey {display:.2f} moved {bloomed}")
            encoded = tuple(display_quantize(channel) for channel in bloomed)
            original = tuple(display_quantize(channel) for channel in linear)
            delta = delta_e(original, encoded)
            if delta >= 1:
                failures.append(f"halo grey {display:.2f} ΔE {delta:.3f}")
    for linear in colors:
        bloomed = halo_pixel(linear, spec["halo_mix"], HALO_CURVE)
        if hue_delta(linear, bloomed) > 1:
            failures.append(f"halo color hue {hue_delta(linear, bloomed):.2f}")
        if linear[0] < 0.80 and max(abs(bloomed[c] - linear[c]) for c in range(3)) > 1e-6:
            failures.append(f"halo color below the knee moved {bloomed}")

    for ev in (-1.0, 0.0, 1.0):
        for display in (0.20, 0.50):
            linear = tuple(srgb_decode(display) for _ in range(3))
            exposed = exposure_pixel(linear, ev)
            if max(exposed) - min(exposed) > 1e-6:
                failures.append(f"EV {ev} grey is not neutral {exposed}")
            if ev != 0:
                restored = tuple(channel / (2.0 ** ev) for channel in exposed)
                if max(abs(restored[channel] - linear[channel]) for channel in range(3)) > 1e-6:
                    failures.append(f"EV {ev} changed more than exposure")
        for linear in colors:
            exposed = exposure_pixel(linear, ev)
            restored = tuple(channel / (2.0 ** ev) for channel in exposed) if ev != 0 else exposed
            if hue_delta(linear, restored) > 0.5:
                failures.append(f"EV {ev} hue {hue_delta(linear, restored):.2f}")
            if max(abs(restored[channel] - linear[channel]) for channel in range(3)) > 1e-6:
                failures.append(f"EV {ev} cast {restored}")

    # The old HEIF path decoded in the linear working space and then applied gamma 2.2 again.
    crushed = srgb_encode(srgb_decode(0.50) ** 2.2)
    if delta_e((0.50, 0.50, 0.50), (crushed, crushed, crushed)) < 1:
        failures.append("double-gamma fixture no longer reproduces the tone crush")
    print(f"grain max gray ΔE {worst_grain:.4f} at amplitude {spec['amplitude']}")


def main():
    failures = []
    check_effects(failures)
    for title, recipe in LOOKS.items():
        row_sums = [sum(recipe["matrix"][i : i + 3]) for i in (0, 3, 6)]
        if not recipe["mono"] and any(abs(total - 1) > 1e-6 for total in row_sums):
            failures.append(f"{title} matrix rows do not sum to 1: {row_sums}")
        off = [recipe["matrix"][i] for i in (1, 2, 3, 5, 6, 7)]
        if any(abs(value) > 0.08 for value in off):
            failures.append(f"{title} off-diagonal exceeds 0.08")
        for tint in (recipe["shadow"], recipe["highlight"]):
            if any(abs(channel) > 0.05 for channel in tint):
                failures.append(f"{title} split tone exceeds 5%")
        marker = {"正片": "static let positive", "负片": "static let negative", "黑白": "static let mono", "CCD": "static let ccd"}[title]
        if marker not in SOURCE:
            failures.append(f"{marker} missing from LookRecipe.swift")
        for name, rgb, neutral in SAMPLES:
            out = apply(recipe, *rgb)
            if recipe["mono"]:
                if max(out) - min(out) > 0.004:
                    failures.append(f"{title} {name} is not grey {out}")
                continue
            if neutral:
                c = chroma(out)
                if c > 6:
                    failures.append(f"{title} {name} chroma {c:.2f}")
                if title != "负片" and delta_e(rgb, out) > 8:
                    failures.append(f"{title} {name} ΔE {delta_e(rgb, out):.2f}")
            elif hue_delta(rgb, out) > 10:
                failures.append(f"{title} {name} hue {hue_delta(rgb, out):.1f}")
    if failures:
        print("\n".join(failures))
        return 1
    print("look calibration passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
