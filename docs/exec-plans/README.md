# Execution plans

Plans that span more than a single change live here so multi-session work has a
durable record.

- `active/`   — plans currently being worked. Move to `completed/` when done.
- `completed/` — finished plans, kept for history and context.
- `tech-debt-tracker.md` — running list of known debt and deferred work.

## Plan lifecycle
1. Copy `_TEMPLATE.md` into `active/` as `<short-slug>.md`.
2. Work the plan; keep its checklist current as you go.
3. When done, move the file to `completed/` and note the outcome.
4. Anything deferred → log it in `tech-debt-tracker.md`.
