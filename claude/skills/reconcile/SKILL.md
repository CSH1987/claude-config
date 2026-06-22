---
name: reconcile
description: >
  Apply or reject staged PRIVATE _pending proposals into canonical memory (hop1). Use in a
  PC-on (mode-A) session to process _pending/<runId>/*.md created by retro/cloud: apply good
  proposals into profile/ and decisions/, reject the rest, and clear the staged files. Plan
  v9 0-D hop1 (no human gate — both sides PRIVATE). Surfaces as reconcile-stale in metrics.md
  when items sit unreconciled past the threshold.
---

# reconcile — hop1: apply PRIVATE _pending proposals into canonical memory

The deterministic SessionStart check (`reconcile-check`) only *flags* staleness. This skill
is the mode-A actor that actually applies proposals. Both source (`_pending/`) and target
(`profile/`, `decisions/`) are inside the PRIVATE `claude-memory` tree, so no human/PUBLIC
gate is needed (that is hop2 `/promote`, which is separate and out of scope here).

## When to use
- A PC-on session where `_pending/` has items (or `reconcile-stale` showed in the status line).
- After a `retro` run, or after a cloud run left edit proposals.

## Hard rules
- **Mode-A / PC-on only.** Applying requires the live canonical store; do not run from a
  cloud/headless context.
- **PRIVATE to PRIVATE.** Never push anything to PUBLIC `claude-config` here.
- **Decide deliberately.** Apply only proposals that are correct and durable; reject the rest
  with a one-line reason. Never blindly accept.
- **New decisions shard-append; edits reconcile.** A brand-new decision just becomes
  `decisions/<machineId>/<id>.md` (no hop). Hop1 is for *edits to existing mode-A records*
  and `profile/` changes proposed by another writer.

## Steps
1. **Resolve the store** via `memdir.{sh,ps1}` (`$CLAUDE_MEMORY_DIR`). List `_pending/*/*.md`.
2. **For each proposal**, read its frontmatter (`kind`, `slug`, `source`, `created_at`) and body:
   - `kind: decision` -> write/merge into `decisions/<machineId>/<slug>.md` in the canonical
     decision format (Context / Decision / Rationale / Consequences). New id = shard-append.
   - `kind: profile` -> set the named key in `profile/user-profile.json` (schema-agnostic;
     bump `updated_at`/`updated_by`). De-dupe against existing values.
   - `kind: skill` -> stage a skill draft for later `/skillify` + hop2 `/promote` (do NOT
     auto-publish to PUBLIC).
   - `kind: note` -> evaluate; usually fold into a decision or drop.
3. **Apply or reject.** On apply: write the canonical target, then delete the `_pending` file.
   On reject: delete the `_pending` file and record a one-line reason (e.g. append to a
   `_pending/<runId>/REJECTED.log`), so staleness clears either way.
4. **Emit a result.** Record an event (`type: promote`) noting applied/rejected counts so
   `metrics.md` reflects the reconcile and `reconcile-stale` clears.
5. **Report** applied/rejected counts and any follow-up.

## Cross-references
- Staleness detector (SessionStart): `claude/hooks/reconcile-check.{sh,ps1}`.
- Staging (hop1 input): `claude/lib/pending.{sh,ps1}` + `claude/skills/retro/SKILL.md`.
- Promotion ladder, ownership, gates: `claude/protocols/memory-promotion.md`.
- Canonical decision/profile schema: `claude/memory/SCHEMA.md`.
