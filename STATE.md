# STATE.md — cross-session working memory

> Read this FIRST each session. It is the durable memory between sessions: what
> is done, what is in flight, and where to pick up. Update it before you stop.

## Current status
Harness scaffold is in place. No domain/business logic yet — the repo is an empty
environment for agents to work in.

## What exists
- `CLAUDE.md` — root map (placeholders unfilled).
- `docs/` system of record: ARCHITECTURE, agents/, guardrails/, exec-plans/
  (active/ + completed/ + tech-debt-tracker), references/ — all with templates.
- `.claude/` components: agents/ (subagent defs), skills/, hooks/
  (`guardrail-check.sh` worked example), settings.json (wires the hook).

## In flight
- Nothing. Awaiting a human to fill placeholders (see "Needs a human" below).

## Needs a human (placeholders to fill)
- `CLAUDE.md`: "What this repo is", tooling commands, conventions.
- `docs/ARCHITECTURE.md`: overview, component map, agent relationships, flow.
- First real agent spec (`docs/agents/`) + subagent def (`.claude/agents/`).
- First real guardrail (`docs/guardrails/`).

## How to update this file
When you finish a unit of work: move items from "In flight" to "What exists",
note any new "Needs a human" items, and log deferred work in
`docs/exec-plans/tech-debt-tracker.md`.
