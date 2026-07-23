# Agent: [PLACEHOLDER: agent-name]

> Copy this file to `<agent-name>.md` to define a new agent. Fill in every
> section. Leave no placeholders once the agent is live.

## Role
[PLACEHOLDER: One or two sentences. What is this agent accountable for? State it
as an outcome, not a list of steps.]

## Inputs
[PLACEHOLDER: What does this agent consume? Files, prompts, upstream agent output,
external data. Note trust boundaries for any external/untrusted input.]

## Allowed tools (least privilege)
List ONLY the tools this agent needs. Anything not listed is denied.

| Tool | Why it's needed |
|------|-----------------|
| [Read] | [reason] |
| [Edit/Write] | [reason — scope to which paths?] |
| [Bash] | [reason — which commands?] |

## Boundaries (what this agent must NOT do)
- [PLACEHOLDER: paths it must not touch]
- [PLACEHOLDER: actions requiring human approval]
- [PLACEHOLDER: other agents' territory it must not cross into]

## Deterministic done-criteria
The agent's work is DONE only when ALL of these are objectively true. Prefer
machine-checkable criteria (a command exits 0, a file exists, a test passes)
over subjective judgment.

- [ ] [PLACEHOLDER: e.g. `<test command>` exits 0]
- [ ] [PLACEHOLDER: e.g. no guardrail in `docs/guardrails/` is violated]
- [ ] [PLACEHOLDER: e.g. `STATE.md` updated with what changed]

## Applicable guardrails
[PLACEHOLDER: link the guardrail files in `docs/guardrails/` this agent must satisfy]

## Escalation
[PLACEHOLDER: When should this agent stop and ask a human instead of proceeding?]
