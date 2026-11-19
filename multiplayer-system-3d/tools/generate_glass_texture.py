"""Generate the TrenchBroom glass texture.

Writes `trenchbroom/textures/glass.png` (512x512, seamless).  The material next
to it (`glass.tres`) supplies the transparency and the specular response; this
image is the faint tint and surface sheen a mapper sees in TrenchBroom and in
game.

The pattern is a sum of integer-frequency sinusoids, so it tiles in both axes
with no seam blending.  Deterministic like the water generator: re-run this
instead of hand-editing the PNG.

Usage:
    python tools/generate_glass_texture.py

Then:
    "C:/tools/godot/godot_console.exe" --path . --headless --import
"""

import math
import os

from PIL import Image

SIZE = 512
OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "trenchbroom", "textures", "glass.png",
)

TAU = math.pi * 2.0

# (amplitude, x frequency, y frequency, phase)
WAVES = (
    (0.055, 1.0, 2.0, 0.4),
    (0.035, 3.0, 1.0, 2.1),
    (0.020, 2.0, 5.0, 4.3),
    (0.012, 7.0, 3.0, 1.2),
)

BASE = (206, 228, 240)
SPECULAR = (250, 252, 255)


def _lerp(a, b, t):
    return a + (b - a) * t


def main():
    image = Image.new("RGB", (SIZE, SIZE))
    pixels = image.load()

    for y in range(SIZE):
        ny = y / SIZE
        for x in range(SIZE):
            nx = x / SIZE
            sheen = 0.0
            for amp, fx, fy, phase in WAVES:
                sheen += amp * math.sin(TAU * (fx * nx + fy * ny) + phase)

            # Diagonal streak: a sharp narrow band that reads as a reflection
            # without needing an environment map.
            streak = math.sin(TAU * (nx * 1.0 + ny * 1.0) * 1.0)
            streak = max(0.0, streak) ** 6.0

            t = max(0.0, min(1.0, 0.5 + sheen * 2.0 + streak * 0.55))
            rgb = [int(round(_lerp(BASE[i], SPECULAR[i], t))) for i in range(3)]
            pixels[x, y] = tuple(rgb)

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    image.save(OUT_PATH, optimize=True)
    print("wrote " + OUT_PATH)


if __name__ == "__main__":
    main()
