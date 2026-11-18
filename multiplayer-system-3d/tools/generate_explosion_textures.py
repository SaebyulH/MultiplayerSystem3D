"""Generate monochrome alpha masks for the toon explosion.

Writes RGBA PNGs (white RGB, lumpy alpha) into effects/explosion/.  Pure
procedural shapes: overlapping metaball discs with a low-frequency edge wobble,
optionally chained along an axis (smoke wisps) or with radial flame tongues.
No external assets and no image models.

    python tools/generate_explosion_textures.py
"""

import math
import os
import random

from PIL import Image

SIZE = 384
HALF = SIZE * 0.5
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "effects", "explosion")


def _wobble(x, y, seed):
    v = 0.0
    for k in range(3):
        v += math.sin(x * (1.3 + k * 0.7) + seed * (1.1 + k)) * math.cos(
            y * (1.7 + k * 0.9) - seed * (0.7 + k)
        )
    return v / 3.0


def make_mask(
    name,
    seed,
    blob_count,
    spike_count=0,
    stretch_y=1.0,
    spike_len=(0.0, 0.0),
    spread=0.26,
    radius=(0.08, 0.17),
    wobble=0.3,
    chain=False,
):
    rnd = random.Random(seed)
    blobs = []
    for k in range(blob_count):
        if chain:
            # A single connected streak: overlapping discs along one axis.
            t = -0.36 + 0.72 * (k / max(1, blob_count - 1))
            blobs.append(
                (
                    rnd.uniform(-0.1, 0.1),
                    t + rnd.uniform(-0.04, 0.04),
                    rnd.uniform(radius[0], radius[1]),
                )
            )
        else:
            # Perimeter ring + a big core, so the union is one lumpy mass.
            angle = rnd.uniform(0.0, math.tau)
            ring = spread * rnd.uniform(0.35, 1.0)
            blobs.append(
                (
                    math.cos(angle) * ring,
                    math.sin(angle) * ring,
                    rnd.uniform(radius[0], radius[1]),
                )
            )
    blobs.append((0.0, 0.0, 0.3))

    spikes = []
    for _ in range(spike_count):
        angle = rnd.uniform(0.0, math.tau)
        length = rnd.uniform(*spike_len)
        width = rnd.uniform(0.35, 0.55)
        spikes.append((math.cos(angle), math.sin(angle), length, width))

    img = Image.new("RGBA", (SIZE, SIZE))
    px = img.load()
    for j in range(SIZE):
        ny = (j - HALF) / HALF / stretch_y
        for i in range(SIZE):
            nx = (i - HALF) / HALF

            # Additive metaball field: overlaps merge into one cloud.
            field = 0.0
            for bx, by, br in blobs:
                d2 = ((nx - bx) ** 2 + (ny - by) ** 2) / (br * br)
                field += max(0.0, 1.0 - d2)

            for dx, dy, length, width in spikes:
                along = nx * dx + ny * dy
                if along <= 0.0 or along >= length:
                    continue
                perp = abs(-nx * dy + ny * dx)
                taper = width * (1.0 - along / length)
                if taper <= 0.0:
                    continue
                field += max(0.0, 1.0 - perp / taper)

            if field > 0.0:
                # Wobble only the edge; keep empty space empty.
                field += wobble * min(1.0, field)

            r = math.hypot(nx, ny)
            if r > 0.96:
                field -= (r - 0.96) * 24.0

            alpha = max(0.0, min(1.0, (field - 0.35) / 0.5))
            alpha = alpha * alpha * (3.0 - 2.0 * alpha)
            px[i, j] = (255, 255, 255, int(alpha * 255.0))

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    img.save(path)
    print("wrote", path)


def main():
    make_mask("puff_a.png", 11, 17, spread=0.28, radius=(0.12, 0.22))
    make_mask("puff_b.png", 23, 15, stretch_y=0.9, spread=0.26, radius=(0.13, 0.23))
    make_mask("puff_c.png", 37, 18, stretch_y=1.1, spread=0.3, radius=(0.11, 0.21))
    make_mask(
        "fire_puff.png",
        51,
        12,
        spike_count=4,
        stretch_y=1.3,
        spike_len=(0.35, 0.6),
        spread=0.16,
        radius=(0.14, 0.24),
        wobble=0.2,
    )


if __name__ == "__main__":
    main()
