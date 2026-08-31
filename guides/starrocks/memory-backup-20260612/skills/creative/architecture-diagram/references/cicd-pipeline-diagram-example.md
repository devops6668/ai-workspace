# CI/CD Pipeline Diagram Example: Luban CI + Dagster

This reference documents the structure used for the Luban CI Dagster lifecycle diagram (v5), 
which can serve as a template for similar GitOps-based multi-environment CI/CD diagrams.

## Structure Overview

```
┌─────────────────────────────────────────────────────┐
│              SANDBOX ENVIRONMENT (snd)               │
│  ┌─────────────────────────────────────────────────┐ │
│  │ 1. Bootstrap (Project Admin)                    │ │
│  │   Step A: luban-project-setup-template          │ │
│  │   Step B: luban-dagster-platform-setup-template │ │
│  │   Step C: luban-code-location-setup-template    │ │
│  ├─────────────────────────────────────────────────┤ │
│  │ 2. Code Development (Developer)                 │ │
│  │   Jupyter Hub → git push → ArgoEvents/Pipeline  │ │
│  ├─────────────────────────────────────────────────┤ │
│  │ 3. Sandbox Deployment (CI Pipeline)             │ │
│  │   Dispatcher → [commit/tag split] → kpack build │ │
│  │   → git-update → ArgoCD sync → deploy to snd   │ │
│  └───────────────╥─────────────────────────────────┘ │
└──────────────────╬═══════════════════════════════════┘
                   ║  Promote (dashed arrow)
                   ║
┌──────────────────╬──────────────────────────────────┐
│  PRODUCTION ENVIRONMENT (prd)                       │
│  ┌─────────────────────────────────────────────────┐│
│  │ 1. Bootstrap (Project Admin) - same 3 steps     ││
│  ├─────────────────────────────────────────────────┤│
│  │ 2. Promotion (luban-promotion-template)         ││
│  │   Admin: promote dagster-platform               ││
│  │   Developer: promote code location              ││
│  ├─────────────────────────────────────────────────┤│
│  │ 3. Production Deployment (Admin → ArgoCD)       ││
│  │   Sync Infra → Sync Platform → Sync Code Loc    ││
│  └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

## Key SVG Techniques Used

### Color Coding
- **Sandbox outer box**: Blue (`#3b82f6`), gradient background `#sndBg`
- **Production outer box**: Purple (`#8b5cf6`), gradient background `#prdBg`
- **Bootstrap actions**: Green/emerald (`#34d399`)
- **Code development**: Indigo (`#6366f1`)
- **CI pipeline steps**: Amber/orange (`#f59e0b`) for GitOps, green for deploy
- **Promotion**: Amber (`#f59e0b`)
- **Production deploy**: Green (`#34d399`)

### Arrow Conventions
- Regular solid arrow → automated flow
- Dashed arrow with "Promote" label → manual trigger / gating step
- Dev loop: dashed path from Deploy back to JupyterHub (left side of diagram)
- Bootstrap → Dev → Deployment: straight down arrows in center

### Box Hierarchy
1. **Environment sections**: full-width (1340px), rounded (rx=12), 2px stroke
2. **Phase boxes**: ~1285px inside each section, rounded (rx=10), labeled "1.", "2.", "3."
3. **Step cards**: 280-600px sub-boxes, contain specific resources created
4. **Pipeline step sub-boxes**: small (28-40px height) for individual CI steps

### Note/Info Panels
- Right-side notes panel below the CI pipeline for tool-level details
- Warning box (amber-tinted) at the bottom of the pipeline
- Run Pod env injection note across full width
- Dagster Workloads + CI/CD Components as side-by-side footer boxes

## Building Large Diagrams (Iteration Strategy)
When the diagram has 5+ versions and the user keeps refining:
1. **Start with a reasonable first draft** covering the core flow based on repo docs
2. **Expect iteration** — the user will correct structure, ordering, and naming
3. **Keep SVG coordinates modular** — each major section uses its own `y` offset, so shifting is isolated
4. **Don't over-design upfront** — add detail notes (right panels, footnotes) after the main layout is validated
5. **Copy final HTML to a stable path** after each iteration so the user can always reference the latest

## Output Files from This Session
- `/root/luban-ci-v5.html` — Final HTML diagram
- `/root/luban-ci-v5.png` — 1420×1944 PNG rendering
- Data source: `github.com/metasync/luban-ci` v1.3.3, workflow templates under `manifests/workflows/`
