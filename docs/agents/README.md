# Agents — system of record

One spec per agent lives in this directory. Each spec is the authoritative
description of an agent's **role, allowed tools, boundaries, and deterministic
done-criteria**.

## How to add an agent
1. Copy `_TEMPLATE.md` to `<agent-name>.md`.
2. Fill in every section — no placeholders left when the agent goes live.
3. Grant least privilege: list only the tools and paths the agent actually needs.
4. If the agent runs as a Claude Code subagent, also add a definition in
   `.claude/agents/<agent-name>.md` that mirrors these boundaries.
5. Add any new invariants the agent must satisfy to `docs/guardrails/`.

## Index
[PLACEHOLDER: list your agents here as you add them]
- `_TEMPLATE.md` — copy this to create a new agent spec
