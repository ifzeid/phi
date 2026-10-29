"""Checks the develop looks in Phi/Camera/LookRecipe.swift and the edit effects.

Neutrals stay near neutral (chroma under 6, and ΔE under 8 for 正片 and CCD).
Memory-color hue stays within 10°.

Grain at FINE, 光晕, EV, and 无 are checked against the develop sources.
Grain is zero-mean luminance: a gray patch stays neutral and its mean color stays
within ΔE 1, and some pixels move. 无 is identity. Each look moves a red sample.
光晕 is additive and highlight-only: a gray below the knee and a dark region far
from a bright patch stay within 0.5%, and the pixels beside that patch gain glow.
EV does not rotate hue.
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
CAPTURE = (ROOT / "Phi/Camera/CaptureService.swift").read_text()
CAMERA = (ROOT / "Phi/Camera/CameraSession.swift").read_text()
LIBRARY = (ROOT / "Phi/Camera/PhotoLibrary.swift").read_text()
META = (ROOT / "Phi/Camera/PhotoMetadata.swift").read_text()
SESSION = (ROOT / "Phi/Camera/ProcessSession.swift").read_text()
UITEST = (ROOT / "Phi/Debug/PHIUITest.swift").read_text()


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


def emphasis(luma, knee, highlight_end):
    """Soft threshold. Matches HaloOptics.emphasis."""
    y = max(0.0, min(1.0, luma))
    if y <= knee:
        return 0.0
    if y >= highlight_end:
        return 1.0
    t = (y - knee) / (highlight_end - knee)
    return t * t * (3.0 - 2.0 * t)


def screen_shoulder(base, glow, scatter):
    """Matches HaloOptics.screenShoulder. Approaches 1 and does not cross it."""
    if base >= 1.0:
        return base
    addition = max(0.0, min(1.0, scatter * max(glow, 0.0)))
    room = 1.0 - max(0.0, min(base, 1.0))
    return base + room * addition


def diffuse_pixel(rgb, glow, scatter):
    return tuple(screen_shoulder(rgb[channel], glow[channel], scatter) for channel in range(3))


def gaussian_kernel(sigma):
    if sigma < 0.15:
        return [1.0]
    radius = max(1, int(math.ceil(sigma * 3)))
    weights = [math.exp(-0.5 * (offset / sigma) ** 2) for offset in range(-radius, radius + 1)]
    total = sum(weights)
    return [weight / total for weight in weights]


def blur_plane(plane, width, height, sigma):
    """Normalized gaussian with edge clamp, matching CIGaussianBlur on a clamped image."""
    kernel = gaussian_kernel(sigma)
    radius = len(kernel) // 2
    temp = [0.0] * (width * height)
    for y in range(height):
        for x in range(width):
            acc = 0.0
            for offset, weight in enumerate(kernel):
                sample = min(width - 1, max(0, x + offset - radius))
                acc += weight * plane[y * width + sample]
            temp[y * width + x] = acc
    output = [0.0] * (width * height)
    for y in range(height):
        for x in range(width):
            acc = 0.0
            for offset, weight in enumerate(kernel):
                sample = min(height - 1, max(0, y + offset - radius))
                acc += weight * temp[sample * width + x]
            output[y * width + x] = acc
    return output


def proximity_gate(reach, floor, ceil):
    if reach <= floor:
        return 0.0
    if reach >= ceil:
        return 1.0
    t = (reach - floor) / (ceil - floor)
    return t * t * (3.0 - 2.0 * t)


def diffuse_image(pixels, width, height, scatter, optics):
    weighted = []
    mask = []
    for pixel in pixels:
        gain = emphasis(rec709(pixel), optics["knee"], optics["highlight_end"])
        mask.append(gain)
        weighted.append(tuple(channel * gain for channel in pixel))
    glow = []
    longest = max(width, height)
    for channel in range(3):
        plane = [pixel[channel] for pixel in weighted]
        tight = blur_plane(plane, width, height, longest * optics["tight"])
        medium = blur_plane(plane, width, height, longest * optics["medium"])
        wide = blur_plane(plane, width, height, longest * optics["wide"])
        weights = (optics["tight_weight"], optics["medium_weight"], optics["wide_weight"])
        total = sum(weights)
        glow.append(
            [
                (weights[0] * tight[i] + weights[1] * medium[i] + weights[2] * wide[i]) / total
                for i in range(width * height)
            ]
        )
    reach = blur_plane(mask, width, height, longest * optics["reach"])
    gated = []
    for index in range(width * height):
        falloff = proximity_gate(reach[index], optics["gate_floor"], optics["gate_ceil"])
        gated.append(tuple(glow[channel][index] * falloff for channel in range(3)))
    return [
        diffuse_pixel(pixels[index], gated[index], scatter)
        for index in range(len(pixels))
    ]


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
    if not profile or not side:
        return None
    return {
        "seed": int(profile.group(1).replace("_", ""), 16),
        "cell": int(profile.group(2)),
        "amplitude": float(profile.group(3)),
        "tile_fraction": float(profile.group(4)),
        "tile_side": int(side.group(1)),
    }


def parse_halo():
    import re

    names = (
        "weakScatter",
        "strongScatter",
        "tightWeight",
        "mediumWeight",
        "wideWeight",
        "tightRadius",
        "mediumRadius",
        "wideRadius",
    )
    values = {}
    for name in names:
        match = re.search(rf"static let {name}: CGFloat = ([0-9.]+)", LOOKS_SWIFT)
        if not match:
            return None
        values[name] = float(match.group(1))
    knee = re.search(r"static let knee: Float = ([0-9.]+)", LOOKS_SWIFT)
    highlight_end = re.search(r"static let highlightEnd: Float = ([0-9.]+)", LOOKS_SWIFT)
    reach = re.search(r"static let reachRadius: CGFloat = ([0-9.]+)", LOOKS_SWIFT)
    gate_floor = re.search(r"static let gateFloor: Float = ([0-9.]+)", LOOKS_SWIFT)
    gate_ceil = re.search(r"static let gateCeil: Float = ([0-9.]+)", LOOKS_SWIFT)
    if not knee or not highlight_end or not reach or not gate_floor or not gate_ceil:
        return None
    return {
        "weak": values["weakScatter"],
        "strong": values["strongScatter"],
        "tight_weight": values["tightWeight"],
        "medium_weight": values["mediumWeight"],
        "wide_weight": values["wideWeight"],
        "tight": values["tightRadius"],
        "medium": values["mediumRadius"],
        "wide": values["wideRadius"],
        "knee": float(knee.group(1)),
        "highlight_end": float(highlight_end.group(1)),
        "reach": float(reach.group(1)),
        "gate_floor": float(gate_floor.group(1)),
        "gate_ceil": float(gate_ceil.group(1)),
    }


def grain_image(rgb, width, height, spec):
    step = grain_step(width, spec["tile_fraction"], spec["tile_side"])
    field = [
        signed_unit(x, y, spec["seed"], spec["cell"], step)
        for y in range(height)
        for x in range(width)
    ]
    field = balanced(field)
    return [grain_pixel(rgb, noise, spec["amplitude"]) for noise in field]


def check_halo(failures):
    optics = parse_halo()
    if optics is None:
        failures.append("halo optics constants missing")
        return
    if not (0 < optics["weak"] < optics["strong"] <= 2.2):
        failures.append(f"halo steps {optics['weak']} / {optics['strong']} are not a weak/strong pair")
    if optics["strong"] < optics["weak"] * 1.5:
        failures.append("强 is not clearly stronger than 弱")
    if not (optics["tight"] < optics["medium"] < optics["wide"] <= 0.12):
        failures.append(f"halo radii {optics['tight']}, {optics['medium']}, {optics['wide']} are not a short pyramid")
    if optics["knee"] < 0.66 or optics["knee"] > 0.74:
        failures.append(f"halo knee {optics['knee']} is not near 0.70 linear")
    if emphasis(0.45, optics["knee"], optics["highlight_end"]) != 0:
        failures.append("emphasis leaks below the knee")
    if emphasis(1.0, optics["knee"], optics["highlight_end"]) < 0.99:
        failures.append("white does not fully enter the glow")

    gains = {}
    for scatter, name in ((optics["weak"], "弱"), (optics["strong"], "强")):
        for level in (0.20, 0.45, 0.50):
            flat = [(level, level, level)] * 16
            out = diffuse_image(flat, 4, 4, scatter, optics)
            worst = max(abs(out[i][c] - level) / level for i in range(len(out)) for c in range(3))
            if worst >= 0.005:
                failures.append(f"halo {name} gray {level:.2f} below the knee moved {worst:.3%}")
            if any(max(pixel) - min(pixel) > 1e-6 for pixel in out):
                failures.append(f"halo {name} gray {level:.2f} picked up chroma")

        width, height = 72, 40
        x0, y0 = width // 2 - 4, height // 2 - 4
        scene = []
        for y in range(height):
            for x in range(width):
                if x0 <= x < x0 + 8 and y0 <= y < y0 + 8:
                    scene.append((1.0, 1.0, 1.0))
                else:
                    scene.append((0.02, 0.02, 0.02))
        diffused = diffuse_image(scene, width, height, scatter, optics)
        far = 0.0
        for y in range(6):
            for x in range(6):
                index = y * width + x
                src = scene[index][0]
                far = max(far, abs(diffused[index][0] - src) / src)
        if far >= 0.005:
            failures.append(f"halo {name} dark region far from highlights moved {far:.3%}")
        neighbor = (y0 + 4) * width + (x0 - 1)
        gain = rec709(diffused[neighbor]) - rec709(scene[neighbor])
        gains[name] = gain
        if gain < 0.01:
            failures.append(f"halo {name} area next to a bright patch did not gain glow ({gain:.4f})")
        if max(diffused[neighbor]) - min(diffused[neighbor]) > 1e-5:
            failures.append(f"halo {name} neutral glow picked up chroma")
        center = (y0 + 4) * width + (x0 + 4)
        if max(diffused[center]) > 1.0001:
            failures.append(f"halo {name} pushed white past 1")

    if gains.get("强", 0) <= gains.get("弱", 0):
        failures.append("强 halo is not stronger than 弱")

    width, height = 72, 40
    x0, y0 = width // 2 - 4, height // 2 - 4
    warm_src = (1.0, 0.72, 0.38)
    warm = []
    for y in range(height):
        for x in range(width):
            warm.append(warm_src if x0 <= x < x0 + 8 and y0 <= y < y0 + 8 else (0.03, 0.03, 0.03))
    warm_out = diffuse_image(warm, width, height, optics["strong"], optics)
    beside = (y0 + 4) * width + (x0 - 1)
    delta = tuple(warm_out[beside][channel] - warm[beside][channel] for channel in range(3))
    if delta[0] <= delta[2]:
        failures.append(f"warm highlight glow did not keep source hue {delta}")
    corner = warm_out[0]
    if max(abs(corner[channel] - 0.03) / 0.03 for channel in range(3)) >= 0.005:
        failures.append("warm scene darkened a far pixel")
    check_bright_sky(failures, optics)
    print(f"halo neighbor gain 弱 {gains.get('弱', 0):.4f} 强 {gains.get('强', 0):.4f}")


def display_luma(pixel):
    encoded = tuple(srgb_encode(min(channel, 1.0)) for channel in pixel)
    return rec709(encoded)


def is_clipped(pixel):
    return max(srgb_encode(min(channel, 1.0)) for channel in pixel) >= 254.5 / 255.0


def daylight_scene():
    """Courtyard-like frame: sky, white wall, terracotta, and a far shadow.

    HaloOptics.brightSkyFailures uses these same linear colors and the same layout.
    """
    width, height = 128, 80
    sky = (0.3916, 0.5647, 0.7605)
    wall = (0.8388, 0.7913, 0.7011)
    terra = (0.4342, 0.1620, 0.0685)
    shadow = (0.0194, 0.0144, 0.0116)
    scene = []
    for y in range(height):
        for x in range(width):
            if y < int(height * 0.38):
                scene.append(sky)
            elif x > int(width * 0.42) and y < int(height * 0.82):
                scene.append(wall)
            elif x < 18 and y > int(height * 0.70):
                scene.append(shadow)
            else:
                scene.append(terra)
    return scene, width, height


def display_delta(src, out):
    return display_code(out) - display_code(src)


def darkest_mean_lift(src, out):
    order = sorted(range(len(src)), key=lambda index: display_code(src[index]))
    count = max(1, len(src) // 10)
    total = 0.0
    for index in order[:count]:
        total += display_delta(src[index], out[index])
    return total / count


def display_code(pixel):
    return 255.0 * display_luma(pixel)


def check_bright_sky(failures, optics):
    """Daylight frame. 弱 rises about 1.5–4 levels, 强 about 4–9, and clipping stays under 2%."""
    scene, width, height = daylight_scene()
    weak = diffuse_image(scene, width, height, optics["weak"], optics)
    strong = diffuse_image(scene, width, height, optics["strong"], optics)
    before = sum(1 for pixel in scene if is_clipped(pixel)) / len(scene)

    def mean_code(pixels):
        return sum(display_code(pixel) for pixel in pixels) / len(pixels)

    weak_rise = mean_code(weak) - mean_code(scene)
    strong_rise = mean_code(strong) - mean_code(scene)
    if not (1.5 <= weak_rise <= 4.5):
        failures.append(f"弱 mean rise {weak_rise:.2f} levels is outside 1.5–4")
    if not (4.0 <= strong_rise <= 9.5):
        failures.append(f"强 mean rise {strong_rise:.2f} levels is outside 4–9")
    if strong_rise < weak_rise + 1.5:
        failures.append(f"强 mean rise {strong_rise:.2f} is not clearly above 弱 {weak_rise:.2f}")
    for name, diffused in (("弱", weak), ("强", strong)):
        after = sum(1 for pixel in diffused if is_clipped(pixel)) / len(diffused)
        if after - before > 0.02:
            failures.append(f"{name} clipped-area delta {after - before:.3%}")
        shadow = darkest_mean_lift(scene, diffused)
        if shadow > 1.0:
            failures.append(f"{name} darkest decile lifted {shadow:.2f} levels")
    # Terracotta touching the left edge of the white wall.
    wall_x = int(width * 0.42) + 1
    band = []
    for y in range(int(height * 0.45), int(height * 0.70)):
        index = y * width + (wall_x - 3)
        band.append(display_delta(scene[index], strong[index]))
    band_gain = sum(band) / len(band)
    if band_gain < 3:
        failures.append(f"halo beside the wall is not visible ({band_gain:.2f} levels)")
    weak_band = []
    for y in range(int(height * 0.45), int(height * 0.70)):
        index = y * width + (wall_x - 3)
        weak_band.append(display_delta(scene[index], weak[index]))
    if sum(weak_band) / len(weak_band) > band_gain * 0.75:
        failures.append("弱 bloom beside the wall is not clearly quieter than 强")
    far = max(abs(display_delta(scene[index], strong[index])) for index in range(8))
    if far > 1.5:
        failures.append(f"far shadow moved {far:.2f} levels")
    print(
        f"daylight halo 弱 {weak_rise:.2f} levels 强 {strong_rise:.2f} levels "
        f"wall edge {band_gain:.1f}"
    )
    for label in (
        "0.3916, 0.5647, 0.7605",
        "0.8388, 0.7913, 0.7011",
        "0.4342, 0.1620, 0.0685",
        "0.0194, 0.0144, 0.0116",
    ):
        if label not in LOOKS_SWIFT:
            failures.append(f"Swift bright-sky probe is missing daylight color {label}")
    if "0.78, 0.84, 0.95" in LOOKS_SWIFT or "0.94, 0.93, 0.90" in LOOKS_SWIFT:
        failures.append("Swift bright-sky probe still uses the near-white sky")
    effect_check = LOOKS_SWIFT.split("enum DevelopEffectCheck", 1)[-1]
    if "assertionFailure" in effect_check:
        failures.append("DevelopEffectCheck still traps with assertionFailure")
    if "DEVELOP EFFECT CHECK FAILED" not in LOOKS_SWIFT:
        failures.append("DevelopEffectCheck does not log a failing check")
    if "assertionFailure" in STILL:
        failures.append("StillPipeline still traps with assertionFailure")


def check_capture_path(failures):
    """50mm RAW drops to zoom 1, then the finder must wait until the still has finished."""
    start = CAMERA.find("func capturePhoto(")
    end = CAMERA.find("// MARK: - Setup", start)
    body = CAMERA[start:end] if start >= 0 and end > start else ""
    if not body:
        failures.append("capturePhoto is missing")
        return
    if "previewAnchor.resume" in body:
        failures.append("capturePhoto resumes the finder while a still can still be in flight")
    if "captureInFlight" not in CAMERA or "func noteCaptureFinished" not in CAMERA:
        failures.append("finder restore is not deferred until capture finishes")
    if "noteCaptureFinished" not in CAPTURE:
        failures.append("capture does not tell the session when the still has finished")
    if "restoreFinderFraming()" in CAPTURE:
        failures.append("capture restores the finder before the still has finished")
    if "cgImageRepresentation()" in CAPTURE:
        failures.append("capture decodes the full-resolution still for the thumbnail")
    if "legalRawPixelFormat" not in CAMERA or "commitLegalOutputDimensions" not in CAMERA:
        failures.append("photo settings are not validated against the active output")
    if "isBayerRAWPixelFormat" not in CAMERA or "let wanted: AVCapturePhotoOutput.QualityPrioritization = isBayerRaw ? .speed : .quality" not in CAMERA:
        failures.append("Bayer RAW must set photoQualityPrioritization to .speed")
    if "PHIMakePhotoSettings" not in CAMERA or "PHICapturePhoto" not in CAMERA:
        failures.append("photo settings exceptions are not caught")
    if "fileURL: url" not in LIBRARY or "addResource(with: kind, fileURL: url, options: options)" not in LIBRARY:
        failures.append("Photos save still passes the DNG as data")
    if "shouldMoveFile = false" not in LIBRARY:
        failures.append("Photos file resource must not move the local still")
    if "fileURL: url" not in CAPTURE:
        failures.append("capture finish does not pass the written still URLs")
    if "Rewriting a HEIF" in META or "pixels don't match the DNG is what Photos reports" in LIBRARY:
        failures.append("3300 comments still blame HEIF rewrite or pixel mismatch")
    if "ImageOrientation.upright" in RAW_SWIFT:
        failures.append("CIRAWFilter output is rotated a second time")
    if "AlbumImage.framed" not in CAPTURE:
        failures.append("editor does not crop with the album frame")
    if "rendersFromDNG ? self.sourceDNG : nil" not in SESSION:
        failures.append("editor preview does not keep HEIF edits off the DNG")
    if "previewMaxSide: CGFloat = 1280" not in SESSION:
        failures.append("editor preview is not capped")
    if "func warmPreview" not in SESSION:
        failures.append("editor does not warm the preview proxy")
    for flag in (
        "-PHIUITestImport",
        "-PHIUITestOpenEditor",
        "-PHIUITestEditorEV",
        "-PHIUITestEditorLook",
        "EDITOR NEUTRAL DIFF",
        "EDITOR RENDER LATENCY",
        "-PHIUITestEditorDrag",
        "EDITOR DRAG p50",
        "-PHIUITestEditorEVSweep",
        "EDITOR EV SWEEP",
        "EDITOR EV SWEEP FAILED",
    ):
        if flag not in UITEST and flag not in SESSION:
            failures.append(f"editor uitest missing {flag}")
    if "MTKView" not in (ROOT / "Phi/Views/EditorMetalPreview.swift").read_text():
        failures.append("editor preview does not draw with MTKView")
    if "CIRenderDestination" not in STILL:
        failures.append("editor preview does not render through CIRenderDestination")
    if "cacheIntermediates: true" not in STILL:
        failures.append("preview context does not cache intermediates")
    if "dragSide: CGFloat = 800" not in SESSION:
        failures.append("drag proxy is not 800 px")
    if "rendersFromDNG" not in CAPTURE or "RawDevelop.image" not in CAPTURE:
        failures.append("mode 0 edits do not develop the DNG")
    if "baseShoulder" not in RAW_SWIFT:
        failures.append("mode 0 has no highlight shoulder")
    if "exposeThenShoulder" not in RAW_SWIFT or "exposeThenShoulder" not in STILL:
        failures.append("exposure is not a linear gain before the RAW shoulder")
    if "return StillPipeline.applyingExposure(developed" in STILL:
        failures.append("preview still multiplies exposure after the grade")
    if "EDITOR EV METRICS" not in RAW_SWIFT:
        failures.append("missing EV black-point and saturation log")
    if "CIExposureAdjust" in STILL or "CIExposureAdjust" in RAW_SWIFT:
        failures.append("exposure still goes through CIExposureAdjust")
    if "filter.exposure = baseline" in RAW_SWIFT:
        failures.append("RAW filter exposure is the baseline plus a later gain")
    if "baselineExposure = 0" not in RAW_SWIFT or "filter.exposure = 0" not in RAW_SWIFT:
        failures.append("RAW baseline is still applied inside CIRAWFilter")
    if "isGamutMappingEnabled = false" not in RAW_SWIFT:
        failures.append("RAW gamut map can refit highlights after the dial")
    if "shadowBias = 0" not in RAW_SWIFT:
        failures.append("RAW shadow bias is still the display pedestal")
    if "StillPipeline.expose(" not in RAW_SWIFT or "StillPipeline.expose(" not in STILL:
        failures.append("preview and export do not share the linear exposure multiply")
    if "portraitOrientationFailures" not in RAW_SWIFT or "portrait DNG developed" not in RAW_SWIFT:
        failures.append("missing portrait DNG orientation check")


def check_effects(failures):
    spec = parse_grain()
    if spec is None:
        failures.append("grain profile or tileSide missing")
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
    if "CIImageOption.colorSpace: StillPipeline.linearP3" not in LOOKS_SWIFT:
        failures.append("CCD texture is not tagged extended-linear")
    if "sRGB" in META_SWIFT or "sRGB" in STILL:
        failures.append("HEIF export path mentions sRGB")
    if "if y <= knee { return 0 }" not in LOOKS_SWIFT:
        failures.append("highlight emphasis does not cut off at the knee")
    if "imageSum / glowSum" in STILL or "let kept = 1 - k" in STILL:
        failures.append("diffusion still renormalizes glow to the image mean")
    if "CIAdditionCompositing" in STILL or "CIMultiplyCompositing" in STILL:
        failures.append("halo still uses a CI composite for the glow gain")
    if "func applyHalo" not in STILL or "func renderHalo" not in STILL:
        failures.append("preview and export do not share applyHalo")
    if "func screenShoulder" not in LOOKS_SWIFT or "screenShoulder" not in STILL:
        failures.append("glow is not a screen shoulder")
    if "headroomPower" in LOOKS_SWIFT or "HaloOptics.headroom" in STILL:
        failures.append("halo still gates glow with (1-luma)^power")
    if "bakedHalo == halo" not in STILL:
        failures.append("preview cache ignores halo strength")
    if "pyramidBlur" not in STILL:
        failures.append("diffusion blur is not a pyramid")
    if "emphasisFloor" in LOOKS_SWIFT or "static let wideRadius: CGFloat = 0.18" in LOOKS_SWIFT:
        failures.append("frame-wide veil constants remain")
    if "CIColorCubeWithColorSpace" not in LOOKS_SWIFT or "inputColorSpace" not in LOOKS_SWIFT:
        failures.append("look cube is not applied in a tagged display space")
    if "MTLCreateSystemDefaultDevice" not in STILL:
        failures.append("CIContext is not Metal")
    if "PreviewCache" not in STILL or "PreviewCache" not in SESSION:
        failures.append("preview has no cached proxy")
    schedule = SESSION.split("func schedule()", 1)[-1].split("private func showOriginal", 1)[0]
    if "normalizedCGImage" in schedule or "45_000_000" in schedule:
        failures.append("schedule still redraws or waits on the caller")
    export = CAPTURE.split("background-export", 1)[-1].split(".value", 1)[0]
    if "encodeDeveloped" not in export:
        failures.append("HEIF encode is not inside the background export task")
    if "-PHIUITestLook" not in (ROOT / "Phi/Debug/PHIUITest.swift").read_text():
        failures.append("missing -PHIUITestLook")
    if "-PHIUITestHalo" not in (ROOT / "Phi/Debug/PHIUITest.swift").read_text():
        failures.append("missing -PHIUITestHalo")
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
        moved = max(
            abs(pixel[channel] - linear[channel])
            for pixel in grained
            for channel in range(3)
        )
        if moved < 0.01:
            failures.append(f"grain color did not move pixels vs 无 ({moved:.4f})")

    gray = tuple(srgb_decode(0.5) for _ in range(3))
    grained_gray = grain_image(gray, width, height, spec)
    gray_move = max(abs(pixel[channel] - gray[channel]) for pixel in grained_gray for channel in range(3))
    if gray_move < 0.01:
        failures.append(f"grain grey did not move pixels vs 无 ({gray_move:.4f})")

    check_halo(failures)
    check_looks_move(failures)

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


def check_looks_move(failures):
    """Each develop look changes at least one sample vs identity (无)."""
    probe = ("red", (0.78, 0.14, 0.12))
    for title, recipe in LOOKS.items():
        out = apply(recipe, *probe[1])
        delta = sum(abs(out[channel] - probe[1][channel]) for channel in range(3))
        if delta < 0.04:
            failures.append(f"{title} did not move vs 无 ({delta:.4f})")
        if recipe["mono"]:
            if max(out) - min(out) > 0.004:
                failures.append(f"{title} red is not grey {out}")


def main():
    failures = []
    check_effects(failures)
    check_capture_path(failures)
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
