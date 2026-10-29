"""Checks the develop looks in Phi/Camera/LookRecipe.swift.

Neutrals stay near neutral (chroma under 6, and ΔE under 8 for 正片 and CCD).
Memory-color hue stays within 10°. Run: python3 Tests/look_calibration_test.py
"""

import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Phi/Camera/LookRecipe.swift").read_text()


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


def main():
    failures = []
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
