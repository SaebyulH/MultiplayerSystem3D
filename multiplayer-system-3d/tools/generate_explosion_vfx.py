"""Generate the extra explosion VFX masks (noise, comet, swoosh, splat, flame atlas).

Complements tools/generate_explosion_textures.py.  Pure procedural, no image models.

    python tools/generate_explosion_vfx.py
"""

import math
import os
import random

from PIL import Image

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "effects", "explosion")


def _save(img, name):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    img.save(path)
    print("wrote", path)


def make_noise(seed=3, size=256):
    rnd = random.Random(seed)
    phases = [(rnd.uniform(0, 6.28), rnd.uniform(0, 6.28), rnd.uniform(2.0, 7.0)) for _ in range(5)]
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for j in range(size):
        y = j / size
        for i in range(size):
            x = i / size
            v = 0.0
            for k, (p1, p2, f) in enumerate(phases):
                v += math.sin(x * f * 6.28 + p1 + k) * math.cos(y * (f + 1.7) * 6.28 + p2)
            v = v / (2 * len(phases)) + 0.5
            v = max(0.0, min(1.0, v))
            g = int(v * 255)
            px[i, j] = (g, g, g, 255)
    _save(img, "noise.png")


def make_comet(size=128):
    w, h = size, size * 2
    img = Image.new("RGBA", (w, h))
    px = img.load()
    hx, hy, hr = w * 0.5, h * 0.12, size * 0.1
    for j in range(h):
        for i in range(w):
            d = math.hypot(i - hx, j - hy) / hr
            head = max(0.0, 1.0 - d)
            head = head * head
            t = max(0.0, min(1.0, (j - hy) / (h - hy)))
            width = max(0.5, hr * (1.0 - t) ** 1.3)
            tail = max(0.0, 1.0 - abs(i - hx) / width) * (1.0 - t) ** 0.7
            a = max(head, tail)
            px[i, j] = (255, 255, 255, int(max(0.0, min(1.0, a)) * 255))
    _save(img, "comet.png")


def make_swoosh(w=256, h=128):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for j in range(h):
        t = j / (h - 1)
        cx = w * 0.5 + math.sin(t * math.pi * 0.9) * w * 0.22
        half = max(0.5, (1.0 - t) * 4.0)
        for i in range(w):
            d = abs(i - cx)
            a = max(0.0, 1.0 - d / half) * (1.0 - t) ** 0.5
            px[i, j] = (255, 255, 255, int(max(0.0, min(1.0, a)) * 255))
    _save(img, "swoosh.png")


def make_splat(size=256, seed=9):
    rnd = random.Random(seed)
    n = 11
    radii = [rnd.uniform(0.35, 1.0) for _ in range(n)]
    phases = [rnd.uniform(0, 6.28) for _ in range(n)]
    img = Image.new("RGBA", (size, size))
    px = img.load()
    half = size * 0.5
    for j in range(size):
        y = (j - half) / half
        for i in range(size):
            x = (i - half) / half
            ang = math.atan2(y, x)
            r = math.hypot(x, y)
            reach = 0.35
            for k in range(n):
                lobe = math.cos((ang - phases[k]) * n * 0.5)
                if lobe > 0.0:
                    reach = max(reach, radii[k] * lobe ** 6)
            a = max(0.0, min(1.0, (reach - r) * 8.0))
            a = a * a * (3.0 - 2.0 * a)
            px[i, j] = (255, 255, 255, int(a * 255))
    _save(img, "splat.png")


def make_flame_atlas(cell=128, cols=4, rows=4):
    """Pre-coloured curling tongue flipbook: 4x4 cells."""
    full = Image.new("RGBA", (cell * cols, cell * rows))
    for fy in range(rows):
        for fx in range(cols):
            phase = (fy * cols + fx) / float(cols * rows) * 6.283
            frame = Image.new("RGBA", (cell, cell))
            px = frame.load()
            blobs = []
            for k in range(7):
                t = k / 6.0
                bx = 0.5 + math.sin(phase + t * 5.5) * 0.16 * t
                by = 0.92 - t * 0.75
                br = 0.22 * (1.0 - t * 0.75)
                blobs.append((bx, by, br))
            for j in range(cell):
                y = (j / cell - 0.5) * 2.0
                for i in range(cell):
                    x = (i / cell - 0.5) * 2.0
                    f = 0.0
                    for bx, by, br in blobs:
                        dx = x - (bx - 0.5) * 2.0
                        dy = y - (by - 0.5) * 2.0
                        d2 = (dx * dx + dy * dy) / (br * br)
                        f += max(0.0, 1.0 - d2)
                    f += 0.25 * math.sin(x * 9.0 + phase) * math.cos(y * 7.0 - phase)
                    a = max(0.0, min(1.0, (f - 0.45) / 0.5))
                    if a <= 0.0:
                        px[i, j] = (0, 0, 0, 0)
                        continue
                    heat = max(0.0, min(1.0, f / 2.4))
                    if heat > 0.7:
                        col = (1.0, 0.95, 0.45)
                    elif heat > 0.45:
                        col = (1.0, 0.55, 0.08)
                    else:
                        col = (0.72, 0.12, 0.02)
                    px[i, j] = (
                        int(col[0] * 255),
                        int(col[1] * 255),
                        int(col[2] * 255),
                        int(a * 255),
                    )
            full.alpha_composite(frame, (fx * cell, fy * cell))
    _save(full, "flame_atlas.png")


def main():
    make_noise()
    make_comet()
    make_swoosh()
    make_splat()
    make_flame_atlas()


if __name__ == "__main__":
    main()
