# Subagent definitions

One `.md` per subagent Claude Code can dispatch. Each definition mirrors the
boundaries declared in the agent's spec under `docs/agents/`.

- The **spec** (`docs/agents/<name>.md`) is the human system of record.
- The **definition** here is the machine-readable subagent Claude Code loads.

Keep them in sync: the `tools` a definition grants must match the least-privilege
tool list in the corresponding spec.

## How to add a subagent
1. Ensure `docs/agents/<name>.md` exists (copy the spec template first).
2. Copy `_TEMPLATE.md` here to `<name>.md`.
3. Fill in the frontmatter and system prompt. Grant only the tools the spec allows.
