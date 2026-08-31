# Interpreting Pixel Analysis Results

A reference to help translate color data into plausible scene descriptions.

## The Two-Image Pattern (from session)

In one session, two user images were analyzed with near-identical color profiles:
- ~35-50% white (bright background)
- ~40-55% green tones (vegetation/ground)
- Very bright (193-205/255)
- Wide aspect ratios (1.93:1 and 2.28:1)

**Interpretation**: Nature/landscape scenes with bright or overcast sky above and grass or treeline below. The cinematic aspect ratio (2:1+) is a strong clue the user may be sending photos taken with a phone camera in landscape orientation.

## Common Color → Scene Mappings

| Dominant palette | Likely subject |
|-----------------|----------------|
| White/light + greens | Landscape, park, garden |
| Blues + whites/greys | Sky, ocean, snow, mountains |
| Flesh tones + warm browns | Portraits, people, indoor scenes |
| Dark + scattered bright spots | Night scene with lights |
| Uniform greys/blues | UI screenshot, document, wireframe |
| Red/orange + dark | Sunset, fire, warm lighting |
| High-contrast black + white | Text document, code screenshot |
| Neon/bright saturated | Digital art, gaming, social media graphic |

## Band Composition Patterns

### Top-to-bottom (5 bands)

```
1: White 65%                   → Sky / ceiling / bright background
2: White 49%, Grey 28%        → Mid-sky, cloud layer, or wall
3: White 81%                  → Horizon transition or empty space
4: Green 44%                  → Ground / grass / vegetation
5: Green 41%                  → Foreground / floor / field
```

This pattern = **landscape / nature photo**.

```
1: Flesh-tone 50%, Warm 30%   → Hair / hat area
2: Flesh-tone 60%             → Face
3: Flesh-tone 55%, Dark 25%   → Torso / clothing
4: Dark 60%                   → Lower body
5: Dark 70%                   → Bottom frame / ground
```

This pattern = **portrait / selfie**.

### Left-to-right (3 bands)

```
Left:   Green 51%, White 40%  → Edge landscape
Center: Green 47%, White 45%  → Similar — centered subject or uniform
Right:  Green 49%, White 45%  → Edge landscape
```

All three bands similar = **wide centering** or **uniform scene**.

```
Left:   Dark 70%              → Edge of frame / out of focus
Center: Flesh-tone 55%        → Subject
Right:  Dark 65%              → Edge of frame / out of focus
```

Center-heavy with blurry edges = **portrait mode / shallow depth of field**.

## Brightness Quick Guide

| Avg (0-255) | Interpretation |
|-------------|---------------|
| >200 | Very bright — overcast sky, white background, overexposed |
| 150-200 | Bright — well-lit outdoor, sunny indoor |
| 80-150 | Moderate — indoor lighting, shaded outdoor |
| 40-80 | Dark — evening, dim indoor |
| <40 | Very dark — night, intentional low-light |

## Contrast Quick Guide

| Std Dev | Interpretation |
|---------|---------------|
| >70 | High contrast — text on background, sunny with hard shadows |
| 40-70 | Medium contrast — typical photo |
| 20-40 | Low contrast — overcast, flat lighting |
| <20 | Very low — fog, gradient, single color field |

## Edge Detail Quick Guide

| Edge ratio | Interpretation |
|-----------|---------------|
| >30% | Highly detailed — dense foliage, text, complex UI, crowd |
| 12-30% | Moderately detailed — typical landscape, simple UI, portrait |
| <12% | Low detail — solid colors, blur, gradient, pure sky |
