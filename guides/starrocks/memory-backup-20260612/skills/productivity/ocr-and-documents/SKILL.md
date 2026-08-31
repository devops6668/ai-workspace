---
name: ocr-and-documents
description: "Extract text from PDFs, scanned documents, and images (screenshots, photos, chat images) via OCR."
version: 2.4.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [PDF, Documents, Research, Arxiv, Text-Extraction, OCR]
    related_skills: [powerpoint]
---

# PDF & Document Extraction

For DOCX: use `python-docx` (parses actual document structure, far better than OCR).
For PPTX: see the `powerpoint` skill (uses `python-pptx` with full slide/notes support).
This skill covers **PDFs, scanned documents, and general image OCR** (screenshots, photos with text, chat images).

## Step 1: Remote URL Available?

If the document has a URL, **always try `web_extract` first**:

```
web_extract(urls=["https://arxiv.org/pdf/2402.03300"])
web_extract(urls=["https://example.com/report.pdf"])
```

This handles PDF-to-markdown conversion via Firecrawl with no local dependencies.

Only use local extraction when: the file is local, web_extract fails, or you need batch processing.

## Step 2: Choose Local Extractor

| Feature | pymupdf (~25MB) | marker-pdf (~3-5GB) |
|---------|-----------------|---------------------|
| **Text-based PDF** | ✅ | ✅ |
| **Scanned PDF (OCR)** | ❌ | ✅ (90+ languages) |
| **Tables** | ✅ (basic) | ✅ (high accuracy) |
| **Equations / LaTeX** | ❌ | ✅ |
| **Code blocks** | ❌ | ✅ |
| **Forms** | ❌ | ✅ |
| **Headers/footers removal** | ❌ | ✅ |
| **Reading order detection** | ❌ | ✅ |
| **Images extraction** | ✅ (embedded) | ✅ (with context) |
| **Images → text (OCR)** | ❌ | ✅ |
| **EPUB** | ✅ | ✅ |
| **Markdown output** | ✅ (via pymupdf4llm) | ✅ (native, higher quality) |
| **Install size** | ~25MB | ~3-5GB (PyTorch + models) |
| **Speed** | Instant | ~1-14s/page (CPU), ~0.2s/page (GPU) |

**Decision**: Use pymupdf unless you need OCR, equations, forms, or complex layout analysis.

If the user needs marker capabilities but the system lacks ~5GB free disk:
> "This document needs OCR/advanced extraction (marker-pdf), which requires ~5GB for PyTorch and models. Your system has [X]GB free. Options: free up space, provide a URL so I can use web_extract, or I can try pymupdf which works for text-based PDFs but not scanned documents or equations."

---

## pymupdf (lightweight)

```bash
pip install pymupdf pymupdf4llm
```

**Via helper script**:
```bash
python scripts/extract_pymupdf.py document.pdf              # Plain text
python scripts/extract_pymupdf.py document.pdf --markdown    # Markdown
python scripts/extract_pymupdf.py document.pdf --tables      # Tables
python scripts/extract_pymupdf.py document.pdf --images out/ # Extract images
python scripts/extract_pymupdf.py document.pdf --metadata    # Title, author, pages
python scripts/extract_pymupdf.py document.pdf --pages 0-4   # Specific pages
```

**Inline**:
```bash
python3 -c "
import pymupdf
doc = pymupdf.open('document.pdf')
for page in doc:
    print(page.get_text())
"
```

---

## marker-pdf (high-quality OCR)

```bash
# Check disk space first
python scripts/extract_marker.py --check

pip install marker-pdf
```

**Via helper script**:
```bash
python scripts/extract_marker.py document.pdf                # Markdown
python scripts/extract_marker.py document.pdf --json         # JSON with metadata
python scripts/extract_marker.py document.pdf --output_dir out/  # Save images
python scripts/extract_marker.py scanned.pdf                 # Scanned PDF (OCR)
python scripts/extract_marker.py document.pdf --use_llm      # LLM-boosted accuracy
```

**CLI** (installed with marker-pdf):
```bash
marker_single document.pdf --output_dir ./output
marker /path/to/folder --workers 4    # Batch
```

---

## Arxiv Papers

```
# Abstract only (fast)
web_extract(urls=["https://arxiv.org/abs/2402.03300"])

# Full paper
web_extract(urls=["https://arxiv.org/pdf/2402.03300"])

# Search
web_search(query="arxiv GRPO reinforcement learning 2026")
```

## Split, Merge & Search

pymupdf handles these natively — use `execute_code` or inline Python:

```python
# Split: extract pages 1-5 to a new PDF
import pymupdf
doc = pymupdf.open("report.pdf")
new = pymupdf.open()
for i in range(5):
    new.insert_pdf(doc, from_page=i, to_page=i)
new.save("pages_1-5.pdf")
```

```python
# Merge multiple PDFs
import pymupdf
result = pymupdf.open()
for path in ["a.pdf", "b.pdf", "c.pdf"]:
    result.insert_pdf(pymupdf.open(path))
result.save("merged.pdf")
```

```python
# Search for text across all pages
import pymupdf
doc = pymupdf.open("report.pdf")
for i, page in enumerate(doc):
    results = page.search_for("revenue")
    if results:
        print(f"Page {i+1}: {len(results)} match(es)")
        print(page.get_text("text"))
```

No extra dependencies needed — pymupdf covers split, merge, search, and text extraction in one package.

---

## General Image OCR (screenshots, chat images, photos with text)

When the user sends or references a standalone image file (screenshot, Telegram photo, camera image with text) rather than a PDF, use **Tesseract OCR** via `pytesseract`.

### Setup

```bash
apt-get install -y tesseract-ocr
pip install pytesseract Pillow
# Install language packs for non-English text:
apt-get install -y tesseract-ocr-ara  # Arabic
apt-get install -y tesseract-ocr-ind  # Indonesian
tesseract --list-langs                 # Verify installed languages
```

### Basic Usage

```python
from PIL import Image
import pytesseract

img = Image.open(path)
text = pytesseract.image_to_string(img)
```

### Improving Results on Difficult Images

Small text, colored backgrounds (Telegram bubbles, screenshots), and mixed scripts often need preprocessing:

**1. Try all PSM modes** — start with 3, 6, 11, and 12:

```python
for psm in [3, 6, 11, 12]:
    text = pytesseract.image_to_string(img, config=f'--psm {psm}')
```

- PSM 3 = fully automatic (good baseline)
- PSM 6 = assume uniform block of text
- PSM 11 = sparse text (good for scattered text on colored bg)
- PSM 12 = sparse text with OSD

**2. Language selection**: pass a `+`-separated string like `'ara+eng'` or `'ind+eng'` as the `lang` parameter. Always include `eng` as fallback.

**3. Grayscale + thresholding** — essential for colored-background images:

```python
gray = img.convert('L')
binary = gray.point(lambda x: 0 if x < 120 else 255, '1')
text = pytesseract.image_to_string(binary, config='--psm 6')
```

Try threshold values between 80–180. Use Otsu's method for automatic threshold finding if available via OpenCV.

**4. Upscale** — small images (<600px on a side) benefit from 2–4x scaling:

```python
w, h = img.size
big = img.resize((w*4, h*4), Image.LANCZOS)
text = pytesseract.image_to_string(big)
```

**5. OpenCV preprocessing** (when available) — bilateral filter + Otsu threshold:

```python
import cv2
import numpy as np
gray = cv2.cvtColor(cv2.imread(path), cv2.COLOR_BGR2GRAY)
big = cv2.resize(gray, (w*3, h*3), interpolation=cv2.INTER_CUBIC)
filtered = cv2.bilateralFilter(big, 9, 75, 75)
_, binary = cv2.threshold(filtered, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
pil_img = Image.fromarray(binary)
text = pytesseract.image_to_string(pil_img)
```

### Pitfalls

- **Small text on colored backgrounds** (Telegram chat bubbles, UI screenshots) is the hardest case — expect garbled results with mixed scripts. Be honest with the user about quality limitations rather than fabricating plausible text.
- **Always try multiple thresholds and PSM modes** — no single configuration works for all images.
- **No single OCR tool handles every image well.** If Tesseract fails, suggest the user provide a higher-resolution version or copy the text directly.
- **Don't skip preprocessing on colored-background images.** Raw OCR on a Telegram-green chat bubble gives terrible results.
- **Language packs are per-language**, not per-script. For Arabic text you need `tesseract-ocr-ara`; for Indonesian `tesseract-ocr-ind`. Installing all available packs wastes disk.
- **Inverted text** (light text on dark bg): invert the image before OCR (`ImageOps.invert()`).

---

## Notes

- `web_extract` is always first choice for URLs
- pymupdf is the safe default — instant, no models, works everywhere
- marker-pdf is for OCR, scanned docs, equations, complex layouts — install only when needed
- Both helper scripts accept `--help` for full usage
- marker-pdf downloads ~2.5GB of models to `~/.cache/huggingface/` on first use
- For Word docs: `pip install python-docx` (better than OCR — parses actual structure)
- For PowerPoint: see the `powerpoint` skill (uses python-pptx)
