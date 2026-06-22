#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "Pillow"]
# ///
"""Generate the built-in noise textures shipped with Phosphor.

All textures are deterministic (fixed seed) so rebuilds are byte-stable.
Output: 512x512 PNGs into the package's BuiltinTextures resource directory.

Usage:
    ./Tools/generate_noise_textures.py [OUTPUT_DIR]
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 512
SEED = 0xC0FFEE


def _to_u8(a: np.ndarray) -> np.ndarray:
    return np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8)


def save_gray(path: Path, a: np.ndarray) -> None:
    """a in [0,1], shape (H,W). Saved as grayscale."""
    Image.fromarray(_to_u8(a), mode="L").save(path, optimize=True)


def save_rgb(path: Path, a: np.ndarray) -> None:
    """a in [0,1], shape (H,W,3)."""
    Image.fromarray(_to_u8(a), mode="RGB").save(path, optimize=True)


def white_noise(rng: np.random.Generator) -> np.ndarray:
    """Uniform white noise, one channel."""
    return rng.random((SIZE, SIZE), dtype=np.float64)


def white_noise_rgb(rng: np.random.Generator) -> np.ndarray:
    """Independent white noise per channel (useful for stochastic effects)."""
    return rng.random((SIZE, SIZE, 3), dtype=np.float64)


def value_noise(rng: np.random.Generator, period: int = 8) -> np.ndarray:
    """Tileable value noise: random lattice + smooth (quintic fade) interp."""
    lattice = rng.random((period, period), dtype=np.float64)
    # Continuous sample coordinate (in lattice cells) for each output pixel.
    coords = np.arange(SIZE, dtype=np.float64) / SIZE * period
    i0 = np.floor(coords).astype(int) % period
    i1 = (i0 + 1) % period
    f = coords - np.floor(coords)
    f = f * f * f * (f * (f * 6 - 15) + 10)  # quintic fade

    # Build per-axis index/weight grids (y down rows, x across cols).
    iy0, ix0 = np.meshgrid(i0, i0, indexing="ij")
    iy1, ix1 = np.meshgrid(i1, i1, indexing="ij")
    fy, fx = np.meshgrid(f, f, indexing="ij")

    c00 = lattice[iy0, ix0]
    c10 = lattice[iy0, ix1]
    c01 = lattice[iy1, ix0]
    c11 = lattice[iy1, ix1]
    top = c00 * (1 - fx) + c10 * fx
    bot = c01 * (1 - fx) + c11 * fx
    return top * (1 - fy) + bot * fy


def fbm(rng: np.random.Generator, octaves: int = 5) -> np.ndarray:
    """Fractal (fBm) value noise — soft cloudy / Perlin-like field."""
    out = np.zeros((SIZE, SIZE), dtype=np.float64)
    amp, total, period = 1.0, 0.0, 4
    for _ in range(octaves):
        out += amp * value_noise(rng, period=period)
        total += amp
        amp *= 0.5
        period *= 2
    out /= total
    # normalize to full range
    out -= out.min()
    out /= max(out.max(), 1e-9)
    return out


def blue_noise(rng: np.random.Generator, iterations: int = 24) -> np.ndarray:
    """Blue noise via iterative gaussian high-pass + rank equalisation.

    Not a textbook void-and-cluster, but yields a tileable high-frequency
    dither pattern: most spectral energy sits at high frequencies and the
    histogram is flat in [0,1] (good for ordered dithering / sampling).
    """
    fy = np.fft.fftfreq(SIZE)[:, None]
    fx = np.fft.fftfreq(SIZE)[None, :]
    radius = np.sqrt(fx**2 + fy**2)
    # High-pass: suppress low frequencies, keep highs. sigma controls cutoff.
    sigma = 0.10
    low_pass = np.exp(-(radius**2) / (2 * sigma**2))
    high_pass = 1.0 - low_pass

    field = rng.random((SIZE, SIZE), dtype=np.float64)
    for _ in range(iterations):
        spec = np.fft.fft2(field)
        field = np.real(np.fft.ifft2(spec * high_pass))
        # Rank-based histogram equalisation back to uniform [0,1].
        ranks = field.ravel().argsort().argsort()
        field = ranks.reshape(SIZE, SIZE) / (SIZE * SIZE - 1)
    return field


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parent.parent
        / "Packages/PhosphorSupport/Sources/PhosphorSupport/Resources/BuiltinTextures"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(SEED)
    save_gray(out_dir / "noise-white.png", white_noise(rng))
    save_rgb(out_dir / "noise-white-rgb.png", white_noise_rgb(rng))
    save_gray(out_dir / "noise-value.png", value_noise(rng, period=32))
    save_gray(out_dir / "noise-fbm.png", fbm(rng, octaves=6))
    save_gray(out_dir / "noise-blue.png", blue_noise(rng))

    print(f"Wrote noise textures to {out_dir}")
    for p in sorted(out_dir.glob("noise-*.png")):
        print(f"  {p.name}  ({p.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
