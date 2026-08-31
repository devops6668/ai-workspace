# SVG Diagram Patterns for Pipeline Diagrams

## Arrow Patterns

### Standard arrow with marker
```html
<line x1="X1" y1="Y1" x2="X2" y2="Y2" stroke="#COLOR" stroke-width="1.5" marker-end="url(#arrow)"/>
```

### Dashed arrow (cross-block / cross-phase)
```html
<line x1="X1" y1="Y1" x2="X2" y2="Y2" stroke="#COLOR" stroke-width="2" stroke-dasharray="6,3" marker-end="url(#arrow-purple)"/>
```

### Curved path (feedback loops)
```html
<path d="M X1 Y1 L X_left Y_mid L X_left Y_top L X2 Y2" stroke="#6366f1" stroke-width="1" stroke-dasharray="4,3" marker-end="url(#arrow)"/>
```

### Vertical arrow (sequential steps)
```html
<line x1="CENTER_X" y1="STEP1_BOTTOM" x2="CENTER_X" y2="STEP2_TOP" stroke="#COLOR" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arrow-blue)"/>
```

## Gradient Definitions (Pre-defined Patterns)

### Setup background gradient
```xml
<linearGradient id="setupBg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0%" stop-color="#1a3a2e" stop-opacity="0.2"/>
  <stop offset="100%" stop-color="#1a1a2e" stop-opacity="1"/>
</linearGradient>
```

### Sandbox / Dev background gradient
```xml
<linearGradient id="sandboxBg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0%" stop-color="#1e3a5f" stop-opacity="0.2"/>
  <stop offset="100%" stop-color="#1a1a2e" stop-opacity="1"/>
</linearGradient>
```

### Production background gradient
```xml
<linearGradient id="prodBg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0%" stop-color="#3b1f5e" stop-opacity="0.2"/>
  <stop offset="100%" stop-color="#1a1a2e" stop-opacity="1"/>
</linearGradient>
```

### Infrastructure background gradient
```xml
<linearGradient id="infraBg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0%" stop-color="#0f4c3a" stop-opacity="0.2"/>
  <stop offset="100%" stop-color="#1a1a2e" stop-opacity="1"/>
</linearGradient>
```

## Arrow Marker Definitions

```xml
<marker id="arrow" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
  <polygon points="0 0,10 3.5,0 7" fill="#8b8b8b"/>
</marker>
<marker id="arrow-blue" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
  <polygon points="0 0,10 3.5,0 7" fill="#60a5fa"/>
</marker>
<marker id="arrow-purple" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
  <polygon points="0 0,10 3.5,0 7" fill="#a78bfa"/>
</marker>
<marker id="arrow-orange" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
  <polygon points="0 0,10 3.5,0 7" fill="#f59e0b"/>
</marker>
<marker id="arrow-green" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
  <polygon points="0 0,10 3.5,0 7" fill="#34d399"/>
</marker>
```

## Text Patterns

### Centered text with two lines
```html
<rect x="X" y="Y" width="WIDTH" height="40" rx="8" fill="#0f2744" stroke="#COLOR" stroke-width="1"/>
<text x="CENTER_X" y="Y+18" text-anchor="middle" fill="#e2e8f0" font-size="12">Primary text</text>
<text x="CENTER_X" y="Y+33" text-anchor="middle" fill="#64748b" font-size="10">Secondary text</text>
```

### Left-aligned multi-line text (list items)
```html
<text x="X" y="Y" fill="#94a3b8" font-size="11" font-weight="bold">Section Title:</text>
<text x="X" y="Y+20" fill="#64748b" font-size="10">• Item one</text>
<text x="X" y="Y+37" fill="#64748b" font-size="10">• Item two</text>
```

### Small annotation text (off to the side of arrows)
```html
<text x="X" y="Y" text-anchor="end" fill="#64748b" font-size="9">Feedback label</text>
```

## Block Layout Checklist

1. Set SVG viewBox/height to accommodate total content height
2. Top section (cluster architecture): fixed at y=80
3. Sequential stages: calculate each block's bottom = top + height
4. Between stages: gap of 20px minimum
5. Legend at the bottom: minimum 20px below last block
6. Footer below legend: 30px padding
7. After adding a new stage at position N, shift stages N+1 through N+k and everything below by (new_block_height + 20)
8. Cross-block arrows: use the OLD bottom position as source Y, not the new one (before shifting)

## Playwright Rendering Tips

- Playwright is installed via `pip install playwright` if not already available
- Use `viewport` matching the SVG dimensions for accurate rendering
- Wait at least 500ms after page load for SVG to render
- `full_page=True` in screenshot to capture the entire SVG

Example:
```python
from playwright.async_api import async_playwright
async def render(svg_path, png_path, width=1400, height=1660):
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": width, "height": height})
        await page.goto(f"file://{svg_path}")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=png_path, full_page=True)
        await browser.close()
```
