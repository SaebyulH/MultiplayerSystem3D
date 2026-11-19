"""Generate the swimmable-water surface texture pair used by TrenchBroom.

Writes two 1024x1024 seamless PNGs next to the existing Water textures:

  trenchbroom/textures/Material-LIB/Nature/Water/Water[swim].png
  trenchbroom/textures/Material-LIB/Nature/Water/Water[swim]_normal.png

The albedo is what TrenchBroom shows in its texture browser and what the
water shader (`assets/materials/water_surface.gdshader`) samples; the normal
map is scrolled twice at different speeds to animate the ripples.

Determinism matters: the committed PNGs must match what this script produces,
so the seed is fixed and the wave table is literal. The height field is a sum
of integer-frequency sinusoids, which is periodic in both axes and therefore
tileable — no blending tricks needed at the seams.

Usage:
    python tools/generate_water_texture.py

Then let Godot import the new files:
    "C:/tools/godot/godot_console.exe" --path . --headless --import
"""

import math
import os

from PIL import Image

SIZE = 1024
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "trenchbroom", "textures", "Material-LIB", "Nature", "Water",
)
ALBEDO_NAME = "Water[swim].png"
NORMAL_NAME = "Water[swim]_normal.png"

# (amplitude, x frequency, y frequency, phase) — integer frequencies only.
WAVES = (
    (0.46, 2.0, 1.0, 0.31),
    (0.32, 1.0, 3.0, 1.94),
    (0.22, 4.0, 2.0, 4.12),
    (0.15, 3.0, 5.0, 2.63),
    (0.10, 6.0, 3.0, 5.47),
    (0.07, 5.0, 7.0, 3.08),
    (0.05, 9.0, 4.0, 0.77),
)

TAU = math.pi * 2.0

# Deep water to shallow crest.
DEEP = (10, 44, 74)
MID = (32, 104, 138)
CREST = (128, 214, 226)
FOAM = (214, 244, 248)


def _height(x, y):
    """Height field in roughly [-1, 1] and its two analytic derivatives."""
    nx = x / SIZE
    ny = y / SIZE
    h = 0.0
    dx = 0.0
    dy = 0.0
    for amp, fx, fy, phase in WAVES:
        angle = TAU * (fx * nx + fy * ny) + phase
        h += amp * math.sin(angle)
        dx += amp * math.cos(angle) * TAU * fx / SIZE
        dy += amp * math.cos(angle) * TAU * fy / SIZE
    return h, dx, dy


def _lerp(a, b, t):
    return a + (b - a) * t


def _albedo(h):
    t = max(0.0, min(1.0, 0.5 + 0.5 * h))
    if t < 0.5:
        k = t * 2.0
        return tuple(int(round(_lerp(DEEP[i], MID[i], k))) for i in range(3))
    k = (t - 0.5) * 2.0
    rgb = [_lerp(MID[i], CREST[i], k) for i in range(3)]
    if h > 0.72:
        # Thin bright crests where the ripples peak.
        f = min(1.0, (h - 0.72) / 0.28)
        rgb = [_lerp(rgb[i], FOAM[i], f * 0.85) for i in range(3)]
    return tuple(int(round(c)) for c in rgb)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    albedo = Image.new("RGB", (SIZE, SIZE))
    normal = Image.new("RGB", (SIZE, SIZE))
    ap = albedo.load()
    np = normal.load()

    strength = 2.2
    for y in range(SIZE):
        for x in range(SIZE):
            h, dhx, dhy = _height(x, y)
            ap[x, y] = _albedo(h)
            nx = -dhx * strength
            ny = -dhy * strength
            # (nx, ny, 1) normalized, encoded OpenGL-style (+Y up).
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + 1.0)
            np[x, y] = (
                int(round((nx * inv * 0.5 + 0.5) * 255.0)),
                int(round((ny * inv * 0.5 + 0.5) * 255.0)),
                int(round((1.0 * inv * 0.5 + 0.5) * 255.0)),
            )

    albedo_path = os.path.join(OUT_DIR, ALBEDO_NAME)
    normal_path = os.path.join(OUT_DIR, NORMAL_NAME)
    albedo.save(albedo_path, optimize=True)
    normal.save(normal_path, optimize=True)
    print("wrote " + albedo_path)
    print("wrote " + normal_path)


if __name__ == "__main__":
    main()
