---
name: [PLACEHOLDER: agent-name]
description: [PLACEHOLDER: when should this subagent be invoked? Be specific — this
  is how the dispatcher decides to use it.]
tools: [PLACEHOLDER: comma-separated least-privilege tool list, e.g. Read, Grep, Glob]
model: inherit
---

You are [PLACEHOLDER: agent-name].

## Role
[PLACEHOLDER: mirror docs/agents/<name>.md — one or two sentences on the outcome
you own.]

## Operating rules
- Stay within your boundaries (see docs/agents/<name>.md). Do not touch paths or
  take actions outside your remit.
- Satisfy every applicable guardrail in docs/guardrails/ before reporting done.
- Your work is done only when the deterministic done-criteria in your spec are met.

## Output
[PLACEHOLDER: what exactly do you return to the caller? A structured result? A
summary? Define it so callers can rely on it.]
