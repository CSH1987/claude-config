---
name: promote
description: >
  Review staged playbook drafts (from `/retro`) and, on approval, commit them into the PUBLIC
  playbooks catalog. Use when the user says "promote" / "승격", or after a `/retro` run left
  drafts under $CLAUDE_MEMORY_DIR/playbook-drafts/. This is the human-reviewed gate that keeps
  PII out of the PUBLIC claude-config repo — never auto-commit without the user's explicit
  approval of each draft.
---

# promote — human-reviewed playbook drafts → PUBLIC catalog

The other half of `/retro`. `/retro` stages PII-safe *candidate* playbook updates locally;
`/promote` is where a human actually decides each one is fit to land in the PUBLIC
`claude-config` repo. (2026-08-02: first real implementation — CLAUDE.md and
`claude/skills/playbooks/SKILL.md` have referenced this promotion step since the playbooks
catalog was created, but no `/promote` command existed anywhere in the repo until now.)

## When to use
- The user says "promote" / "승격해줘".
- Right after a `/retro` run reports it staged one or more drafts.
- Periodically, to clear out accumulated drafts under `$CLAUDE_MEMORY_DIR/playbook-drafts/`.

## Hard rules
- **Never auto-commit.** Show each draft's content to the user and get explicit approval
  before writing anything into `claude/playbooks/` or running `git commit`. This is the entire
  point of the two-step retro/promote split — skipping review defeats it.
- **PII is the user's call, not yours.** Even a draft that looks generic to you may contain
  something the user recognizes as sensitive. Ask if genuinely unsure; don't guess and commit.
- **One-time precondition (leak-guard gate2b).** Before the *first* promote on a machine,
  confirm `$CLAUDE_MEMORY_DIR/.leakwords` has been seeded with the user's real name(s)/handles
  (one per line) — this activates the repo's pre-commit bare-name scan
  (`claude/githooks/leakscan.sh`) as a second line of defense on top of your own review. If
  it's missing, tell the user once and offer to seed it (ask for the values; do not guess).

## Steps
1. **Resolve the store.** `eval "$(bash ~/.claude/lib/memdir.sh --export)"` (POSIX) or
   `& "$env:USERPROFILE\.claude\lib\memdir.ps1" -Export | Out-String | Invoke-Expression`
   (PowerShell).
2. **List drafts.** `ls "$CLAUDE_MEMORY_DIR/playbook-drafts/"*.md`. If empty, say so and stop.
3. **For each draft, show it to the user** and ask: apply, edit-then-apply, or reject.
4. **On approval**: write/merge the draft's "Method" content into the appropriate file under
   `claude/playbooks/` (new topic → new file following the existing catalog's format; existing
   topic → merge into that file, don't just append a duplicate section). Update
   `claude/playbooks/README.md`'s index if a new file was added. `git add` the changed
   playbook file(s) + README, then `git commit` (this runs the repo's leak-guard pre-commit
   hook automatically — if it blocks, stop and tell the user why, don't bypass it). Delete the
   consumed draft file only after the commit succeeds.
5. **On rejection**: delete the draft file, no commit. Optionally note the one-line reason for
   future reference.
6. **Report** what was promoted (with the resulting commit), what was rejected, and what (if
   anything) is still pending.

## Cross-references
- Staging (input): `claude/skills/retro/SKILL.md`.
- Target catalog + quality bar: `claude/skills/playbooks/SKILL.md`, `claude/playbooks/README.md`.
- Leak-guard: `claude/githooks/leakscan.{sh,py}`.
- Path resolver: `claude/lib/memdir.{sh,ps1}`.
