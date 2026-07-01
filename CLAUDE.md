# CLAUDE.md — claude_cow-repo

> This file is a MAP, not a manual. It points to the system of record in `docs/`.
> Keep it short (~100 lines). When a rule matters, encode it in code/tests, not here.

## What this repo is
[PLACEHOLDER: One paragraph — what the agents you're building are for, who/what
they serve, and the outcome they're accountable for. Replace this before the
first real change lands.]

## Core beliefs (agent-first operating principles)
- Humans steer; agents execute. Prefer prompts + guardrails over hand-written code.
- Never solve the same failure twice — encode each fix as a durable guardrail.
- Enforce invariants, not implementations. Constrain boundaries; allow local freedom.
- Least privilege: every agent gets exactly the tools and paths it needs, nothing more.

## Where to look (system of record)
- `docs/ARCHITECTURE.md`        — top-level map of components and how agents relate
- `docs/agents/`                — one spec per agent (role, tools, boundaries, done-criteria)
- `docs/guardrails/`            — review personas + invariants agents must satisfy
- `docs/exec-plans/`            — active/completed plans + tech-debt tracker
- `docs/references/`            — external docs distilled for agent consumption (llms.txt style)
- `STATE.md`                    — cross-session working memory (read this first each session)

## Claude Code component layout
- `.claude/agents/`             — subagent definitions (one `.md` per subagent)
- `.claude/skills/`             — reusable skills invocable via `/`
- `.claude/hooks/`              — deterministic gates that run automatically
- `.claude/settings.json`       — wires hooks + permissions (least privilege)

## Operating loop (run this every session)
1. Ground yourself: read this file, `STATE.md`, the relevant `docs/agents/<name>.md`,
   and the task.
2. Check `docs/guardrails/` for invariants that apply to this change.
3. Implement, then self-review against those guardrails before opening a PR.
4. If you hit a missing capability, ask: "what's missing, and how do we make it
   legible and enforceable?" — then add it to the repo, don't just work around it.
5. Update `STATE.md` so the next session starts where you left off.

## Tooling / commands
- Install: [PLACEHOLDER: install command]
- Test:    [PLACEHOLDER: test command]
- Lint:    [PLACEHOLDER: lint command]
- Run:     [PLACEHOLDER: run command]
- Verify guardrails: `.claude/hooks/guardrail-check.sh` (runs automatically; see hook config)

## Conventions
- [PLACEHOLDER: naming, structure, what NOT to touch, commit style]
- Keep this file under ~100 lines — it is a table of contents, not documentation.
- New agent? Add a spec in `docs/agents/` (copy `_TEMPLATE.md`) and, if it runs
  as a subagent, a definition in `.claude/agents/`.
- New invariant? Add a guardrail in `docs/guardrails/` and, where possible, a
  deterministic check in `.claude/hooks/`.
