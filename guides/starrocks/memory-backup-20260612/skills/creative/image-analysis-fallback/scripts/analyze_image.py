#!/usr/bin/env python3
"""
Full-image analysis script for the image-analysis-fallback skill.
Usage: python analyze_image.py <path_to_image>
"""

import sys
import os
from PIL import Image, ImageFilter


def analyze(path):
    if not os.path.exists(path):
        print(f"ERROR: File not found: {path}")
        sys.exit(1)

    img = Image.open(path)
    w, h = img.size
    fsize = os.path.getsize(path)

    print(f"=== Image Info ===")
    print(f"  Path:   {path}")
    print(f"  Format: {img.format}")
    print(f"  Size:   {w} x {h}")
    print(f"  Ratio:  {w/h:.2f}")
    print(f"  Mode:   {img.mode}")
    print(f"  File:   {fsize:,} bytes")

    # --- Dominant colors ---
    print(f"\n=== Dominant Colors (top 8) ===")
    reduced = img.quantize(colors=8)
    palette = reduced.getpalette()[:8*3]
    colors = [(palette[i], palette[i+1], palette[i+2]) for i in range(0, 8*3, 3)]
    counts = reduced.getcolors()
    total_px = w * h
    for count, idx in sorted(counts, reverse=True):
        r, g, b = colors[idx]
        pct = count / total_px * 100
        print(f"  RGB({r:3d},{g:3d},{b:3d}) — {pct:5.1f}%")

    # --- Horizontal bands ---
    print(f"\n=== Horizontal Composition (top→bottom, {h}px) ===")
    bands = 5
    band_h = h // bands
    for i in range(bands):
        y0 = i * band_h
        y1 = (i+1) * band_h if i < bands - 1 else h
        band = img.crop((0, y0, w, y1))
        reduced = band.quantize(colors=3)
        palette = reduced.getpalette()[:3*3]
        colors = [(palette[j], palette[j+1], palette[j+2]) for j in range(0, 3*3, 3)]
        counts = reduced.getcolors()
        top = []
        for count, idx in sorted(counts, reverse=True)[:2]:
            r, g, b = colors[idx]
            pct = count / (band.width * band.height) * 100
            top.append(f"({r:3d},{g:3d},{b:3d}) {pct:.0f}%")
        print(f"  y={y0:4d}-{y1:4d}: {', '.join(top)}")

    # --- Vertical bands ---
    print(f"\n=== Vertical Composition (left→right, {w}px) ===")
    v_bands = 3
    band_w = w // v_bands
    labels = ["Left   ", "Center ", "Right  "]
    for i in range(v_bands):
        x0 = i * band_w
        x1 = (i+1) * band_w if i < v_bands - 1 else w
        band = img.crop((x0, 0, x1, h))
        reduced = band.quantize(colors=3)
        palette = reduced.getpalette()[:3*3]
        colors = [(palette[j], palette[j+1], palette[j+2]) for j in range(0, 3*3, 3)]
        counts = reduced.getcolors()
        top = []
        for count, idx in sorted(counts, reverse=True)[:2]:
            r, g, b = colors[idx]
            pct = count / (band.width * band.height) * 100
            top.append(f"({r:3d},{g:3d},{b:3d}) {pct:.0f}%")
        print(f"  {labels[i]}: {', '.join(top)}")

    # --- Brightness & Contrast ---
    gray = img.convert('L')
    pixels = list(gray.getdata())
    avg = sum(pixels) / len(pixels)
    var = sum((p - avg)**2 for p in pixels) / len(pixels)
    std = var ** 0.5
    print(f"\n=== Light ===")
    print(f"  Brightness (0-255): {avg:.1f}")
    print(f"  Contrast (std dev): {std:.1f}")
    if avg > 200:
        print(f"  → Very bright (overexposed / white-dominant)")
    elif avg > 150:
        print(f"  → Bright (well-lit)")
    elif avg > 80:
        print(f"  → Moderate")
    elif avg > 40:
        print(f"  → Dark")
    else:
        print(f"  → Very dark")

    # --- Edge detail ---
    edges = gray.filter(ImageFilter.FIND_EDGES)
    edge_pixels = list(edges.getdata())
    edge_ratio = sum(1 for p in edge_pixels if p > 50) / len(edge_pixels) * 100
    print(f"\n=== Detail ===")
    print(f"  Edge ratio: {edge_ratio:.1f}%")
    if edge_ratio > 30:
        print(f"  → High detail (text, complex scene, dense foliage)")
    elif edge_ratio > 12:
        print(f"  → Moderate detail (typical photo, simple UI)")
    else:
        print(f"  → Low detail (solid colors, blur, gradient, out of focus)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyze_image.py <path_to_image>")
        sys.exit(1)
    analyze(sys.argv[1])
