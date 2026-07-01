# Architecture

> Top-level map of components and how the agents relate. This is the system of
> record for structure — `CLAUDE.md` only points here.

## Overview
[PLACEHOLDER: One or two paragraphs describing the system at a high level. What
are the major components? What is the flow of work from input to output? Where do
agents sit in that flow?]

## Component map
[PLACEHOLDER: Replace with your real components. The tree below is a scaffold.]

```
claude_cow-repo/
├── CLAUDE.md              # map / table of contents
├── STATE.md              # cross-session working memory
├── docs/                 # system of record
│   ├── ARCHITECTURE.md   # this file
│   ├── agents/           # one spec per agent
│   ├── guardrails/       # invariants + review personas
│   ├── exec-plans/       # active/completed plans + tech-debt
│   └── references/       # distilled external docs
└── .claude/              # Claude Code components
    ├── agents/           # subagent definitions
    ├── skills/           # reusable skills
    ├── hooks/            # deterministic gates
    └── settings.json     # hook + permission wiring
```

## Agents and how they relate
[PLACEHOLDER: Describe each agent's role and the hand-offs between them. A table
often works well:]

| Agent | Responsibility | Consumes | Produces |
|-------|----------------|----------|----------|
| [name] | [what it owns] | [inputs] | [outputs] |

See `docs/agents/` for the full spec of each agent.

## Data / control flow
[PLACEHOLDER: How does data move between agents? Where are the trust boundaries?
What is deterministic vs. model-driven?]

## Invariants (enforced elsewhere)
Invariants are NOT documented here in prose — they are encoded as guardrails in
`docs/guardrails/` and, where possible, as deterministic checks in `.claude/hooks/`.
This section only lists which invariants exist and points to their enforcement.

- [PLACEHOLDER: invariant name] → `docs/guardrails/[file].md` / `.claude/hooks/[script]`
