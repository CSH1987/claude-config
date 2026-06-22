---
name: retro
description: >
  Distill the current session into durable memory proposals. Use at session end (or on
  demand / via a routine) to extract stable user facts/preferences, non-trivial decisions,
  and repeatable workflows, then STAGE each as a PRIVATE proposal under _pending/<runId>/
  via the pending library, for later hop1 reconcile into canonical memory. Plan v9 0-D hop1
  / v10 T1-G1.
---

# retro — session distillation into PRIVATE _pending proposals

This is the LLM half of the growth loop (v10 T1-G1). The deterministic half (SessionEnd
snapshot, instrumentation) is handled by hooks; this skill turns a session's *content* into
durable knowledge. It only ever writes to the PRIVATE memory store (`$CLAUDE_MEMORY_DIR`),
never to the PUBLIC `claude-config` repo.

## When to use
- At the end of a substantive session, or when the user says "retro" / "회고".
- When a routine (PC-on headless or cloud) periodically harvests durable knowledge.
- NOT for trivial/conversational sessions (nothing durable to stage).

## Hard rules (read first)
- **PRIVATE only.** Every proposal goes under `$CLAUDE_MEMORY_DIR/_pending/<runId>/`. Never
  write proposals into the `claude-config` tree (that path is PUBLIC; PII would leak).
- **No PUBLIC promotion here.** This skill only *stages* PRIVATE proposals. Promotion to
  PUBLIC (`/promote`, hop2) is a separate, human-reviewed step and is out of scope.
- **Propose, don't apply.** Do not edit `profile/` or `decisions/` directly — staging to
  `_pending/` lets the hop1 reconcile step (a PC-on session) apply or reject deliberately.
- **De-duplicate.** Before staging, recall existing `decisions/*` and `profile` so you don't
  restage something already canonical.

## Steps
1. **Resolve the store.** `eval "$(bash ~/.claude/lib/memdir.sh --export)"` (POSIX) or
   `& "$env:USERPROFILE\.claude\lib\memdir.ps1" -Export | Out-String | Invoke-Expression`
   (PowerShell). Use the resolved `$CLAUDE_MEMORY_DIR`; never hardcode paths.
2. **Scan the session** for three proposal kinds:
   - `profile` — a stable user preference/identity/constraint that should never need
     re-explaining (e.g. response language, tone, a standing taboo).
   - `decision` — a non-trivial, cross-project decision with rationale (the kind worth
     recalling later). Use the `decisions` format (Context / Decision / Rationale).
   - `skill` — a repeatable workflow worth distilling into a reusable skill draft.
3. **Recall to de-dupe.** Check existing `profile/user-profile.json` and `decisions/*` for
   each candidate; drop anything already captured.
4. **Stage each surviving candidate** with the pending library (one file per proposal):
   ```sh
   printf '%s' "<proposal body markdown>" | \
     bash ~/.claude/lib/pending.sh --kind decision --slug 20260101-short-slug --source retro
   ```
   ```powershell
   & "$env:USERPROFILE\.claude\lib\pending.ps1" -Kind decision -Slug 20260101-short-slug -Source retro -Body "<proposal body>"
   ```
   The library writes `_pending/<runId>/<slug>.md` with YAML frontmatter
   (`kind, slug, run_id, created_at, status: pending, source`) plus your body.
5. **Body conventions.** Keep bodies concise and PII-aware (this is PRIVATE, so real values
   are allowed here — but never echo secrets/tokens). For `decision`, include
   **Context / Decision / Rationale**. For `profile`, state the single durable fact and the
   target profile key. For `skill`, describe the trigger and the steps.
6. **Report** what was staged (counts by kind) and remind that hop1 reconcile (next PC-on
   session) will apply or reject — `_pending` items unreconciled past the threshold surface
   as `reconcile-stale` in `metrics.md`.

## Cross-references
- Staging library: `claude/lib/pending.{sh,ps1}`.
- Reconcile (hop1 apply): `claude/skills/reconcile/SKILL.md` + the SessionStart staleness check.
- Promotion ladder & gates: `claude/protocols/memory-promotion.md`.
- Canonical schema: `claude/memory/SCHEMA.md`.
