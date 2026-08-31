---
name: architecture-diagram
description: "Dark-themed SVG architecture/cloud/infra diagrams as HTML."
version: 1.0.0
author: Cocoon AI (hello@cocoon-ai.com), ported by Hermes Agent
license: MIT
dependencies: []
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [architecture, diagrams, SVG, HTML, visualization, infrastructure, cloud]
    related_skills: [concept-diagrams, excalidraw]
---

# Architecture Diagram Skill

Generate professional, dark-themed technical architecture diagrams as standalone HTML files with inline SVG graphics. No external tools, no API keys, no rendering libraries — just write the HTML file and open it in a browser.

## Editing Existing Diagrams

When inserting new sections into an existing SVG diagram:

### Coordinate Shifting (critical)
1. **Increase `viewBox` height** first to make room for new content.
2. **Insert the new section** between existing sections at the desired position.
3. **Shift all elements below** by adding `+N` to their `y` coordinates:
   - `rect y=` → shift +N
   - `text y=` → shift +N
   - `line y1=` / `y2=` → shift +N
   - `path d="M... L..."` → shift ALL Y values in the path string +N
   - Arrow connections must shift their endpoints too, or they break.
4. Use `patch` for precision — never `sed` or manual edit.

### Mapping Workflow Templates to Diagram Blocks
When the diagram needs to reflect a provisioning workflow (e.g., a GitOps CI/CD pipeline):

1. **Read the source of truth first.** Clone the repo or read the workflow YAMLs. Never guess pipeline step order.
2. **Read the main `WorkflowTemplate` YAML** to get the step sequence (`steps:` or `dag:` blocks).
3. **Trace `templateRef:` references.** For each step, follow the `templateRef.name` to understand what resources are created. Note `withParam:` loops that indicate X-per-environment execution.
4. **Map templates to labeled boxes.** Use the template name as the box title and the resource list as sub-items.
5. **Group per-environment steps** (e.g., `withParam: ["snd", "prd"]`) with a clear multiplier annotation.

### Multi-Environment Diagram Patterns
CI/CD pipeline diagrams often span Sandbox/Staging and Production. Structure them as stacked sections with a clear separation:

1. **Two environment boxes** — one for `snd` (or `staging`), one for `prd` (production), with distinct border colors (blue vs purple, or similar).
2. **Same bootstrap, different audience** — Both environments often have identical bootstrap steps. Show them side by side or one above the other to make the symmetry obvious.
3. **Separate workflow lanes** — Sandbox gets an automated CI pipeline (push → build → GitOps → deploy). Production gets a manual/triggered promotion path (verify → promote → sync).
4. **Connecting arrow** — Draw a prominent dashed arrow from Sandbox → Production labeled "Promote" to show the gating relationship.
5. **Numbered phases** — Use "1. Bootstrap", "2. Development", "3. Deployment" etc. as running headers so the sequence is unambiguous across the two sections.

### CI/CD Pipeline Rendering (Build → Deploy Flow)
For continuous deployment pipeline diagrams:

1. **Build step starts with a branch/tag split box** — Show two side-by-side sub-boxes for commit-push vs tag-push, each feeding into the same build step.
2. **kpack/CNB build** — Use emerald-green stroke boxes. Show the build script name and output (image_tag).
3. **GitOps repo update** — Amber/orange stroke. Show the overlay path being updated (e.g., `app/overlays/snd`).
4. **ArgoCD sync** — Purple stroke. Show what branch ArgoCD watches.
5. **Deploy** — Green stroke. Show target namespace (`snd-{project}`).
6. **Add a "Dev Loop" arrow** — A dashed line going from the Deploy step back to JupyterHub/git push to show the iterative cycle.
7. **Footnotes panel** — Reserve a right-side area for detailed notes about scripts, configs, and important warnings (e.g., "CI only updates snd, not production").

### Notation: Manual vs Automated Actions
Diagrams with provisioning workflows must distinguish:

| Action Type | Visual Cue | Example |
| :--- | :--- | :--- |
| **Automated CI/CD** | Solid arrows, bold boxes | CI pipeline steps |
| **Manual admin action** | Dashed border boxes, labeled "Admin does X" | "Admin runs promotion-workflow" |
| **User/developer action** | Distinct border color (indigo) | "Developer pushes code" |
| **Auto-triggered event** | Small intermediate box with thin border | ArgoEvents → Sensor → Dispatcher

## Scope

**Best suited for:**
- Software system architecture (frontend / backend / database layers)
- Cloud infrastructure (VPC, regions, subnets, managed services)
- Microservice / service-mesh topology
- Database + API map, deployment diagrams
- Anything with a tech-infra subject that fits a dark, grid-backed aesthetic

**Look elsewhere first for:**
- Physics, chemistry, math, biology, or other scientific subjects
- Physical objects (vehicles, hardware, anatomy, cross-sections)
- Floor plans, narrative journeys, educational / textbook-style visuals
- Hand-drawn whiteboard sketches (consider `excalidraw`)
- Animated explainers (consider an animation skill)

If a more specialized skill is available for the subject, prefer that. If none fits, this skill can also serve as a general SVG diagram fallback — the output will just carry the dark tech aesthetic described below.

Based on [Cocoon AI's architecture-diagram-generator](https://github.com/Cocoon-AI/architecture-diagram-generator) (MIT).

## Workflow

1. User describes their system architecture (components, connections, technologies)
2. Generate the HTML file following the design system below
3. Save with `write_file` to a `.html` file (e.g. `~/architecture-diagram.html`)
4. User opens in any browser — works offline, no dependencies

### Output Location

Save diagrams to a user-specified path, or default to the current working directory:
```
./[project-name]-architecture.html
```

### Preview

After saving, suggest the user open it:
```bash
# macOS
open ./my-architecture.html
# Linux
xdg-open ./my-architecture.html
```

## Design System & Visual Language

### Color Palette (Semantic Mapping)

Use specific `rgba` fills and hex strokes to categorize components:

| Component Type | Fill (rgba) | Stroke (Hex) |
| :--- | :--- | :--- |
| **Frontend** | `rgba(8, 51, 68, 0.4)` | `#22d3ee` (cyan-400) |
| **Backend** | `rgba(6, 78, 59, 0.4)` | `#34d399` (emerald-400) |
| **Database** | `rgba(76, 29, 149, 0.4)` | `#a78bfa` (violet-400) |
| **AWS/Cloud** | `rgba(120, 53, 15, 0.3)` | `#fbbf24` (amber-400) |
| **Security** | `rgba(136, 19, 55, 0.4)` | `#fb7185` (rose-400) |
| **Message Bus** | `rgba(251, 146, 60, 0.3)` | `#fb923c` (orange-400) |
| **External** | `rgba(30, 41, 59, 0.5)` | `#94a3b8` (slate-400) |

### Typography & Background
- **Font:** JetBrains Mono (Monospace), loaded from Google Fonts
- **Sizes:** 12px (Names), 9px (Sublabels), 8px (Annotations), 7px (Tiny labels)
- **Background:** Slate-950 (`#020617`) with a subtle 40px grid pattern

```svg
<!-- Background Grid Pattern -->
<pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
  <path d="M 40 0 L 0 0 0 40" fill="none" stroke="#1e293b" stroke-width="0.5"/>
</pattern>
```

## Technical Implementation Details

### Component Rendering
Components are rounded rectangles (`rx="6"`) with 1.5px strokes. To prevent arrows from showing through semi-transparent fills, use a **double-rect masking technique**:
1. Draw an opaque background rect (`#0f172a`)
2. Draw the semi-transparent styled rect on top

### Connection Rules
- **Z-Order:** Draw arrows *early* in the SVG (after the grid) so they render behind component boxes
- **Arrowheads:** Defined via SVG markers
- **Security Flows:** Use dashed lines in rose color (`#fb7185`)
- **Boundaries:**
  - *Security Groups:* Dashed (`4,4`), rose color
  - *Regions:* Large dashed (`8,4`), amber color, `rx="12"`

### Spacing & Layout Logic
- **Standard Height:** 60px (Services); 80-120px (Large components)
- **Vertical Gap:** Minimum 40px between components
- **Message Buses:** Must be placed *in the gap* between services, not overlapping them
- **Legend Placement:** **CRITICAL.** Must be placed outside all boundary boxes. Calculate the lowest Y-coordinate of all boundaries and place the legend at least 20px below it.

## Document Structure

The generated HTML file follows a four-part layout:
1. **Header:** Title with a pulsing dot indicator and subtitle
2. **Main SVG:** The diagram contained within a rounded border card
3. **Summary Cards:** A grid of three cards below the diagram for high-level details
4. **Footer:** Minimal metadata

### Info Card Pattern
```html
<div class="card">
  <div class="card-header">
    <div class="card-dot cyan"></div>
    <h3>Title</h3>
  </div>
  <ul>
    <li>• Item one</li>
    <li>• Item two</li>
  </ul>
</div>
```

## Output Requirements
- **Single File:** One self-contained `.html` file
- **No External Dependencies:** All CSS and SVG must be inline (except Google Fonts)
- **No JavaScript:** Use pure CSS for any animations (like pulsing dots)
- **Compatibility:** Must render correctly in any modern web browser

## Template Reference

Load the full HTML template for the exact structure, CSS, and SVG component examples:

```
skill_view(name="architecture-diagram", file_path="templates/template.html")
```

The template contains working examples of every component type (frontend, backend, database, cloud, security), arrow styles (standard, dashed, curved), security groups, region boundaries, and the legend — use it as your structural reference when generating diagrams.

## Supporting Files

- `references/cicd-pipeline-diagram-example.md` — Detailed walkthrough of the multi-environment CI/CD pipeline diagram from this session (Luban CI + Dagster). Covers SVG layout, color conventions, iteration process, and file outputs.
- `references/verification-driven-iteration.md` — Case study on iterating a diagram as architectural claims are verified against running code (Dagster OTel example). Covers verification techniques, status badges, and summary panel pattern.

## Pitfalls

- **Large SVG + write_file timeout:** If the HTML/SVG content exceeds ~8K tokens, write_file may stream-timeout. Split into parts: write the scaffold (DOCTYPE/head/body/defs) first, then use patch to append sections one at a time.
- **execute_code blocks for screenshots:** execute_code requires user consent and can time out while waiting. Use terminal directly to run the Playwright screenshot script instead.
- **Text Y ≠ rect Y:** SVG text y= is the baseline, not the top of the bounding box. Always shift text y by the same amount as the corresponding rect y= when renumbering.
- **Broken arrows after insert:** After inserting a new section and shifting downstream elements, arrow endpoints (x1/y1/x2/y2) must be shifted too — missing an endpoint creates an arrow pointing to empty space.
- **Legend overlaps:** The most common layout bug. Place legend elements last and calculate their Y offset based on the lowest element in the diagram, not the first batch of elements you finish editing.
