---
name: image-analysis-fallback
description: "Analyze images programmatically when the built-in vision tool (vision_analyze) is unavailable — extract structure, color composition, layout, and metadata using Pillow."
version: 1.0.0
created_by: agent
metadata:
  triggers:
    - user sends an image and vision_analyze tool is not in your tool list
    - need to understand image content but vision toolset is enabled yet idle
    - quick image assessment (size, format, color distribution, composition)
  related_skills: [hermes-agent, comfyui, pixel-art]
---

# Image Analysis Fallback

When a user sends an image but the built-in `vision_analyze` tool is not loaded in your current session, use Pillow (Python Imaging Library) to extract quantitative information about the image. This gives you enough data to make educated guesses about image layout, composition, and content type — not as good as true vision, but far better than saying "I can't see it."

## Prerequisites

```bash
pip install Pillow
```

## Standard Analysis Workflow

### 1. Basic Metadata

```python
from PIL import Image
import os

img = Image.open(path)
print(f"Format: {img.format}     # JPEG, PNG, WebP, etc.
print(f"Size: {img.size}        # (width, height)
print(f"Mode: {img.mode}        # RGB, RGBA, L (grayscale), etc.
print(f"File size: {os.path.getsize(path)} bytes")
```

### 2. Dominant Colors

Quantize (reduce palette) to extract the most prevalent hues:

```python
reduced = img.quantize(colors=8)
palette = reduced.getpalette()[:8*3]
colors = [(palette[i], palette[i+1], palette[i+2]) for i in range(0, 8*3, 3)]
counts = reduced.getcolors()

for count, idx in sorted(counts, reverse=True):
    r, g, b = colors[idx]
    pct = count / (img.width * img.height) * 100
    print(f"  ({r:3d},{g:3d},{b:3d}) — {pct:.1f}%")
```

This tells you the dominant hues — green suggests nature/vegetation, blue suggests sky/water, white suggests brightness/empty space, etc.

### 3. Horizontal Band Analysis (Composition)

Split the image into horizontal strips to understand layout from top to bottom:

```python
bands = 5
band_h = h // bands
for i in range(bands):
    band = img.crop((0, i*band_h, w, (i+1)*band_h if i < bands-1 else h))
    reduced = band.quantize(colors=3)
    palette = reduced.getpalette()[:3*3]
    colors = [(palette[j], palette[j+1], palette[j+2]) for j in range(0, 3*3, 3)]
    counts = reduced.getcolors()
    # interpret: top band white=sky/background, bottom band green=grass/ground
```

Patterns to recognize:
- **Top is white/blue + bottom is green/brown** → landscape/nature photo
- **Top is dark + bottom is light** → indoor scene with ceiling/lighting
- **Consistent color across bands** → solid backgrounds, UI screenshots, documents
- **Sharp color transition mid-image** → horizon line, tabletop, or UI header

### 4. Vertical Band Analysis (Symmetry)

Split left-to-right to check centering:

```python
v_bands = 3
band_w = w // v_bands
labels = ["Left", "Center", "Right"]
for i in range(v_bands):
    band = img.crop((i*band_w, 0, (i+1)*band_w if i < v_bands-1 else w, h))
    # ... same color analysis as above
```

- **Uniform across all bands** → centered subject or uniform field
- **Center differs from edges** → subject is centered (portrait, object photo)
- **One edge differs** → subject offset to one side

### 5. Brightness & Contrast

```python
gray = img.convert('L')
pixels = list(gray.getdata())
avg_brightness = sum(pixels) / len(pixels)   # 0=black, 255=white

# Standard deviation = contrast
std = (sum((p - avg_brightness)**2 for p in pixels) / len(pixels))**0.5
```

- **Bright > 200**: overexposed, white-dominant, or very bright scene
- **Dark < 60**: nighttime, shadow-heavy, or dark-mode UI
- **High contrast (std > 60)**: text/objects on contrasting background, outdoor sunny
- **Low contrast (std < 30)**: foggy, hazy, flat-color design, textless UI

### 6. Edge/Detail Level (via FIND_EDGES filter)

```python
from PIL import ImageFilter
edges = img.convert('L').filter(ImageFilter.FIND_EDGES)
edge_pixels = list(edges.getdata())
edge_ratio = sum(1 for p in edge_pixels if p > 50) / len(edge_pixels)
```

- **edge_ratio > 25%**: highly detailed (crowd, dense foliage, complex UI, text)
- **edge_ratio 10-25%**: moderately detailed (landscape, portrait, simple UI)
- **edge_ratio < 10%**: low detail (solid colors, gradients, blur, out-of-focus)

## Interpreting Results

Combine all signals to form a coherent guess:

| Color pattern | Layout | Contrast | Guess |
|--------------|--------|----------|-------|
| Green/brown bottom, blue/white top | Horizontal bands | Medium-high | Landscape / nature photo |
| Flesh-tones center, blurry edges | Center-heavy | Medium | Portrait / selfie |
| White with scattered dark pixels | Uniform | High | Document / screenshot with text |
| Dark top, lighter bottom, warm tones | Horizontal bands | Low-medium | Sunset / sunrise |
| Consistent mid-grey across | Uniform | Low | UI mockup, wireframe, foggy scene |

## Limitations

- Cannot read text or recognize specific objects, faces, logos
- Cannot interpret meaning — only reports pixel statistics
- Works best on natural images with distinct color regions
- Less useful for grayscale, duotone, or heavily filtered images
- Does NOT use a vision model — purely mathematical pixel analysis

## Pitfalls

- **Don't guess specific objects.** Saying "This looks like a cat" from color data alone is hallucination. Say "warm-toned central subject against a lighter background" instead.
- **Install Pillow first** — it's not in the standard library. Use `pip install Pillow`.
- **Large images (>10MB)** may take time to load and process. Check file size first.
- **The aspect ratio is a strong clue.** 2:1+ = cinematic/panoramic. 1:1 = social media square. 4:3 = standard photo. 16:9 = screen/widescreen.
