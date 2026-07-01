#!/usr/bin/env bash
#
# guardrail-check.sh — deterministic verification gate (worked example).
#
# This is a WORKED EXAMPLE of the "encode invariants as hooks" principle. It
# enforces one mechanically-checkable guardrail: CLAUDE.md is a MAP, not a
# manual, so it must stay short. If it grows past the cap, this gate fails the
# run and tells the author exactly how to fix it.
#
# Wired via .claude/settings.json (PostToolUse on Write|Edit, and Stop). Hooks
# receive a JSON event on stdin; this check does not need it, so stdin is
# ignored and the script also runs standalone:  .claude/hooks/guardrail-check.sh
#
# Exit codes: 0 = pass. 2 = blocking failure (Claude Code surfaces stderr).
#
# Add more guardrails by appending checks below and calling `fail` on violation.
set -euo pipefail

# Resolve repo root from this script's location so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

status=0
fail() {
  # $1 = what failed, $2 = how to fix
  printf '\n\033[31m✗ GUARDRAIL VIOLATED\033[0m\n' >&2
  printf '  What failed: %s\n' "$1" >&2
  printf '  How to fix:  %s\n' "$2" >&2
  status=2
}

# --- Guardrail: CLAUDE_MD_STAYS_A_MAP -------------------------------------
# Invariant: CLAUDE.md is a table of contents (~100 lines). Hard cap 120.
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
CLAUDE_MD_MAX_LINES=120
if [ -f "$CLAUDE_MD" ]; then
  lines=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
  if [ "$lines" -gt "$CLAUDE_MD_MAX_LINES" ]; then
    fail \
      "CLAUDE.md is $lines lines (cap: $CLAUDE_MD_MAX_LINES). It is meant to be a MAP, not a manual." \
      "Move detail into docs/ (the system of record) and leave only pointers in CLAUDE.md. See docs/guardrails/."
  fi
else
  fail \
    "CLAUDE.md is missing at repo root." \
    "Restore CLAUDE.md — it is the entry-point map every session reads first."
fi

# --- Guardrail: SYSTEM_OF_RECORD_EXISTS -----------------------------------
# Invariant: the docs/ system of record CLAUDE.md points to must exist.
for d in docs/agents docs/guardrails docs/exec-plans docs/references; do
  if [ ! -d "$REPO_ROOT/$d" ]; then
    fail \
      "Expected system-of-record directory '$d' is missing." \
      "Recreate '$d' — CLAUDE.md points to it. Do not delete the docs/ scaffold."
  fi
done

# --- Add further deterministic guardrails above this line -----------------

if [ "$status" -eq 0 ]; then
  printf '\033[32m✓ guardrails passed\033[0m\n'
fi
exit "$status"
