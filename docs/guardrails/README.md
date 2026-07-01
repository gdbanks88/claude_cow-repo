# Guardrails — invariants & review personas

A guardrail is an **invariant that agents must satisfy**, expressed as a review
persona: a specific point of view that inspects a change and either passes it or
blocks it with a clear reason and remediation.

Two complementary forms:
- **Human/agent-readable review personas** — this directory (`*.md`). Used during
  self-review before opening a PR.
- **Deterministic checks** — `.claude/hooks/`. Where a guardrail can be verified
  mechanically, encode it as a hook so it fails the run automatically.

## Principle
Never solve the same failure twice. When something breaks, add a guardrail here
(and a hook if it's checkable) so it can never silently break again.

## How to add a guardrail
1. Copy `_TEMPLATE.md` to `<guardrail-name>.md`.
2. Define the invariant, the persona that enforces it, and its remediation.
3. If the invariant is mechanically checkable, add a hook in `.claude/hooks/`
   and reference it from the guardrail file.

## Index
[PLACEHOLDER: list your guardrails here as you add them]
- `_TEMPLATE.md` — copy this to create a new guardrail
