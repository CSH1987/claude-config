---
name: retro
description: >
  Distill the current session into a candidate playbook update. Use at session end (or when
  the user says "retro"/"회고") to check whether a repeatable *working method* emerged that's
  worth generalizing into the PUBLIC playbooks catalog. Stages a PII-safe draft under
  $CLAUDE_MEMORY_DIR/playbook-drafts/ for later human-reviewed `/promote`.
---

# retro — playbook-candidate distillation

retro is narrowly scoped to **playbooks only** — durable facts about the user, standing
preferences, and cross-project decisions are already captured automatically by Claude Code's
native per-session memory (the auto-memory files under
`~/.claude/projects/<project>/memory/`), so retro does not duplicate that. retro's only job:
notice when *how you worked this session* generalizes into a reusable method, and draft it.

(2026-08-02: replaces the old `_pending`/hop1-hop2 four-kind design, which never actually got
used for its profile/decision role in practice — that role was always native auto-memory's
job. This version matches what CLAUDE.md has described all along: "반복되는 잘 통하는 방법을
발견하면 `/retro`→`/promote`로 플레이북에 증식하세요" — it just finally makes it real.)

## When to use
- At the end of a session where a genuinely repeatable method proved out (not just "did the
  task" — something reusable across future sessions/projects).
- When the user says "retro" / "회고".
- NOT for trivial/conversational sessions, and NOT for one-off facts/decisions (those belong
  in native auto-memory, which you should already be writing to directly — no `/retro` needed).

## Hard rules
- **PII-safe by construction.** Drafts are staged locally (PRIVATE, outside the `claude-config`
  git tree) precisely so a human can strip real names/client details before `/promote` ever
  touches the PUBLIC repo. Still write drafts as if they might leak — generalize, don't
  transcribe verbatim.
- **Propose, don't publish.** retro only writes a draft file. It never edits
  `claude/playbooks/` directly and never commits — that's `/promote`'s job, with human review.
- **De-duplicate.** Before staging, check `claude/playbooks/` (and any existing
  `$CLAUDE_MEMORY_DIR/playbook-drafts/*.md`) for an entry already covering the same method —
  update/skip instead of restaging a near-duplicate.

## Steps
1. **Resolve the store.** `eval "$(bash ~/.claude/lib/memdir.sh --export)"` (POSIX) or
   `& "$env:USERPROFILE\.claude\lib\memdir.ps1" -Export | Out-String | Invoke-Expression`
   (PowerShell). Use the resolved `$CLAUDE_MEMORY_DIR`; never hardcode paths.
2. **Ask: did a repeatable method emerge?** Not "what happened" — "what would I do the same
   way next time, on a different project?" If nothing qualifies, say so and stop (most
   sessions won't produce a playbook candidate — that's expected, not a failure).
3. **De-dupe** against `claude/playbooks/*.md` and existing drafts in
   `$CLAUDE_MEMORY_DIR/playbook-drafts/`.
4. **Write the draft** to `$CLAUDE_MEMORY_DIR/playbook-drafts/<slug>.md` (plain file write —
   no special library needed) with frontmatter:
   ```markdown
   ---
   slug: <short-kebab-case-slug>
   created_at: <ISO8601>
   source: retro
   status: pending
   ---

   ## Method
   <the generalized, PII-free method — what to do, when, why it works>

   ## Where this came from
   <one line of context on the session that surfaced it, generalized (no real names/clients)>
   ```
5. **Report** what was staged (or that nothing qualified), and remind the user that `/promote`
   is needed before this reaches the PUBLIC playbooks catalog.

## Cross-references
- Promotion (human review → PUBLIC commit): `claude/skills/promote/SKILL.md`.
- Playbook catalog + quality bar: `claude/skills/playbooks/SKILL.md`, `claude/playbooks/README.md`.
- Path resolver: `claude/lib/memdir.{sh,ps1}`.
