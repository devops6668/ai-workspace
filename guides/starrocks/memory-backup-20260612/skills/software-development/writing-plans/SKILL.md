---
name: planning
description: "Write implementation plans, plan mode for non-execution work, and throwaway spike experiments to validate ideas before build."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [planning, design, implementation, workflow, documentation, spike, prototype]
    related_skills: [subagent-driven-development, test-driven-development, requesting-code-review]
---

# Planning & Spikes

## Plan Mode

For this turn, you are planning only — no execution, no file edits except the plan markdown.

### Output Requirements

Write a markdown plan with: Goal, context, approach, steps, files likely to change, tests/validation, risks/tradeoffs.

### Save Location

`.hermes/plans/YYYY-MM-DD_HHMMSS-<slug>.md` (relative to workspace).

If no explicit instruction, infer from conversation context. If underspecified, ask a brief clarifying question.

---

## Writing Implementation Plans

Write comprehensive implementation plans assuming the implementer has zero context.

### Core Principle

A good plan makes implementation obvious. If someone has to guess, the plan is incomplete.

### Bite-Sized Task Granularity

**Each task = 2-5 minutes of focused work.**

Right size:
```markdown
### Task 1: Create User model with email field
[10 lines, 1 file]
### Task 2: Add password hash field
[8 lines, 1 file]
```

Too big:
```markdown
### Task 1: Build authentication system
[50 lines across 5 files]
```

### Plan Document Structure

Every plan MUST start with:
```markdown
# [Feature Name] Implementation Plan

**Goal:** [One sentence]
**Architecture:** [2-3 sentences]
**Tech Stack:** [Key technologies]
---
```

Each task:
```markdown
### Task N: [Name]

**Objective:** One sentence

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/file.py:45-67`

**Step 1:** Write failing test (complete code)
**Step 2:** Run test (exact command, expected FAIL)
**Step 3:** Write minimal implementation (complete code)
**Step 4:** Run test (exact command, expected PASS)
**Step 5:** Commit (exact git add + git commit)
```

### Writing Process

1. Understand requirements and acceptance criteria
2. Explore codebase structure and similar features
3. Design approach (architecture, dependencies, testing)
4. Write tasks in order: setup → core (TDD) → edge cases → integration → cleanup
5. Include: exact file paths, complete code, exact commands, verification steps
6. Review: sequential, bite-sized, exact paths, copy-pasteable code
7. Save to `.hermes/plans/`

### Principles

**DRY:** Extract shared logic
**YAGNI:** No future-proofing
**TDD:** Every task that produces code follows RED-GREEN-REFACTOR
**Frequent commits:** After every task

### Execution Handoff

"Plan complete. Ready to execute using subagent-driven-development — I'll dispatch a fresh subagent per task with two-stage review. Shall I proceed?"

---

## Spike: Throwaway Experiments

Use when the user wants to "feel out an idea" before committing to a build — validate feasibility, compare approaches, surface unknowns.

Load when user says: "let me try this", "spike this out", "is this even possible?", "compare A vs B".

### Method Loop

```
decompose → research → build → verdict  ↺ iterate on findings
```

### 1. Decompose

Break into 2-5 independent feasibility questions as Given/When/Then:

| # | Spike | Validates (Given/When/Then) | Risk |
|---|-------|----------------------------|------|
| 001 | websocket-streaming | Given WS, when LLM streams, then client receives < 100ms | High |

- **standard** — one approach, one question
- **comparison** — same question, different approaches (002a / 002b)
- Order by risk (hardest to kill first)

### 2. Align

Present spike table. Ask user to drop, reorder, or re-frame.

### 3. Research

Brief each spike, surface competing approaches, pick one. Skip for pure logic.

### 4. Build

One dir per spike: `spikes/NNN-name/` with `README.md` + code.

**Bias toward interactivity:** runnable CLI > HTML page > web server > unit test.

For parallel comparison spikes, use `delegate_task` to fan out.

### 5. Verdict

Each spike's `README.md` closes with:

```markdown
## Verdict: VALIDATED | PARTIAL | INVALIDATED

### What worked
### What didn't
### Surprises
### Recommendation for the real build
```

- **VALIDATED** — core question answered yes, with evidence
- **PARTIAL** — works under constraints; document them
- **INVALIDATED** — doesn't work; this is a successful spike

### Frontier Mode

If spikes exist and user asks "what next?", look for:
- Integration risks (two validated spikes sharing a resource)
- Data handoff gaps (A's output ≠ B's input)
- Vision gaps (assumed capabilities unproven)
- Alternative approaches for PARTIAL/INVALIDATED
