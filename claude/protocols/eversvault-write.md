<!--
  PUBLIC FILE — claude-config repo (config-sync). Rules and structure ONLY.
  NEVER put the real vault absolute path, API tokens, or real note content here.
  vaultPath lives only in the local, non-synced `~/.claude/eversvault-scope.json`.
-->

# EversVault Write Protocol (PUBLIC · canonical)

Plan: `~/.omc/plans/eversvault-llm-wiki.md`.
Enforcement: `claude/hooks/guardrails.py` EversVault block (`_ev_guard`/`_ev_check_target`).
Read-side index injection: `claude/hooks/eversvault-context.sh` + `eversvault-index.py`.

## 2026-07-31 policy change — approval gates removed by explicit user decision

Through 2026-07-30, `10_컨텍스트` and `90_Hermes` were write-blocked for Claude Code
unconditionally, and `20_업무위키` canonical notes required a staged, human-approved
`_pending` proposal before any reflection. **The user explicitly decided to remove all
three restrictions**, for self-evolution ("자가발전") — Claude (and, separately, Hermes)
should be able to modify any part of the vault directly, without a staged-approval
round-trip. This was a deliberate, informed choice: the risks (compounding drift/
corruption of the `10_컨텍스트` "사람 정본" layer that every session calibrates against,
loss of the `90_Hermes` provenance guarantee — "this was genuinely produced by Hermes,
not written by Claude and mislabeled" — and the general loss of a backstop against
honest mistakes) were laid out and the user confirmed the maximal scope on both axes
(fold in `10_컨텍스트`/`90_Hermes`, and remove the `20_업무위키` gate entirely, not just
loosen it) via an explicit multi-choice confirmation.

**What stayed, because it isn't "approval friction" — it's a separate safety category**
(data-loss prevention / out-of-band bypass prevention), not something the user was asked
about or opted to remove:
- Vault-wide `delete_file`/`move_file` block (still unconditional, everywhere).
- `command_execute` block (no path parameter to apply any rule to).
- The Bash-channel block on the local Obsidian REST API host/port.
- **The Bash-channel block on direct filesystem writes into protected folders** — Bash
  `tee`/`>`/`cp`/`sed -i`/`chmod`/etc. targeting `10_컨텍스트`/`90_Hermes`/`20_업무위키`/
  `00_홈.md` (or the vault root itself — see below) are still blocked even though the
  guard-level gate is gone; the only allowed write channels remain Write/Edit/MultiEdit
  and the `eversvault-obsidian` MCP tools. If a Bash write to a protected path is denied
  even though this document says direct writes are allowed, this is why — switch to one
  of those two channels.
- The `'..'`-escape block for `eversvault-obsidian` tools (paths are schema-guaranteed
  vault-relative; a leftover `..` is never legitimate regardless of write policy).
- `00_홈.md` sentinel self-protection — not approval friction, a structural safety valve
  (`_ev_config()`'s sentinel check depends on this file; corrupting it fail-opens the
  *entire* EversVault guard block, including the safeguards above).

**Known gap this change does *not* by itself close:** `10_컨텍스트`'s files/directory
were set to `444`/`555` (read-only, no-write-even-for-owner) at the OS level back in
Phase 1, independently of the guard. Removing the guard-level block does **not** revert
that — an actual write attempt there still fails with `EACCES` (confirmed empirically:
`Write` to a new file under `10_컨텍스트` throws `EACCES` even with the code-level gate
removed). Claude Code cannot revert this itself either — the Bash-channel `chmod`
protection (kept, see above) blocks any `chmod` command whose target path normalizes
under a protected folder, **and** (after a follow-up fix — the vault root itself was
initially a gap here, since it doesn't normalize *under* any specific protected prefix)
any write-marker command targeting the vault root, so a `chmod -R` on the whole vault is
blocked too, not just one aimed directly at `10_컨텍스트`. **If the intent is for
`10_컨텍스트` to be genuinely writable, the human needs to manually run**
`chmod -R u+w` (or `644`/`755`) **on it** the same way they manually set it to `444`/`555`
during Phase 1. Until then, the guard *permits* the write attempt but the filesystem
still rejects it.

`_ev_has_approved_proposal` (the old gate-check function) and the staged `_pending`
workflow described below are **not deleted** — they're simply no longer *required*.
Reverting to the gated policy means restoring the folder-specific branches in
`_ev_check_target` (see the inline comment in `guardrails.py` for the exact code to
restore) and re-enabling the sections below.

---

## 0. Channels (current policy)

| Vault path | Write channel | Gate |
|---|---|---|
| `10_컨텍스트` | Write/Edit/MultiEdit, or `eversvault-obsidian` `vault_write`/`vault_patch`/`open_file`/`vault_append` | none — direct write allowed (see OS-permission caveat above) |
| `90_Hermes` | same as above | none — direct write allowed (no longer Hermes-exclusive; provenance is no longer guaranteed) |
| `30_결정로그` | Write tool, direct | none (unchanged from before) |
| `20_업무위키/_pending/<id>/` | Write tool, direct | none — Write channel unchanged from before; `vault_append` here was blocked pre-2026-07-31 ("예외없이") and is now allowed along with everything else, since that block existed only to protect the now-removed approval queue |
| `20_업무위키/<category>/*.md` (canonical) | any of the above | none — direct write allowed, no `_pending` approval required |
| `00_홈.md` | — | always deny (self-protection, kept) |

Vault-wide, regardless of path: `delete_file`/`move_file`/`command_execute` always deny;
Bash commands referencing the local REST API host:port always deny; Bash file-write
commands (`tee`/`>`/`cp`/`sed -i`/`chmod`/etc.) targeting a protected folder *or the vault
root itself* always deny (Write/Edit/MultiEdit and the MCP tools are the only write
channels); `eversvault-obsidian` paths with a leftover `'..'` always deny.

---

## 1. `30_결정로그` — direct decision log

One note per confirmed decision (vault's own convention, `00_홈.md`: "날짜별 1건 1노트").

- **Filename:** `YYYY-MM-DD_<짧은-슬러그>.md` (date + short kebab slug — avoids
  collisions when multiple decisions land the same day; still "날짜별").
- **Frontmatter** (mirrors the `10_컨텍스트` style already in use):
  ```yaml
  ---
  type: decision
  created: YYYY-MM-DD
  project: <scope.json project name, or "전역">
  tags: [...]
  ---
  ```
- **When:** only when the human has actually confirmed a decision in the current
  turn — this is a log of what was decided, not a place to stage drafts.
- The vault-wide blocks still apply: MCP `delete_file`/`move_file` are blocked
  everywhere, and `00_홈.md` can never be touched.

## 2. `20_업무위키` and `10_컨텍스트`/`90_Hermes` — direct write

As of 2026-07-31 there is no approval gate: write, edit, or append directly with
Write/Edit/MultiEdit or the `eversvault-obsidian` MCP tools, same as any other file.
Still worth doing well even without enforcement:

- **Canonical note frontmatter** (7-field schema, convention only, not guard-enforced):
  ```yaml
  ---
  title: <string>
  created: YYYY-MM-DD
  updated: YYYY-MM-DD
  category: <채널운영|시술가격|프로세스|FAQ>
  status: pristine | user_modified | approved
  tags: [...]
  related: [...]
  ---
  ```
  This `status` is unrelated to the `_pending` proposal `status` field described below
  (same key name, different file, different meaning) — don't conflate them.
- **`10_컨텍스트` is still the "사람 정본" layer** by convention even though it's no
  longer guard-enforced — every session calibrates against it, so a careless or
  hallucinated edit here has an outsized, compounding downside compared to `20_업무위키`.
  Treat edits here with more care than the removed gate now technically requires:
  prefer surfacing a proposed change to the user before writing when the edit is
  substantive (not just a typo fix), even though nothing forces this.
- **`90_Hermes` no longer has a provenance guarantee.** Before this change, a file there
  being present meant "Hermes actually produced this." That's no longer true — Claude
  can write there too. If preserving that distinction still matters for a given note, say
  who/what actually produced it in the note itself (e.g. a `source:` field) rather than
  relying on folder location alone.

### 2a. Optional: staged review via `_pending` (previous policy, pre-2026-07-31)

The old propose→approve→reflect workflow still works mechanically (nothing in the guard
prevents it) and remains available as an *opt-in* paper trail for any specific edit where
staged review is still wanted — it is just no longer required.

1. Create `20_업무위키/_pending/<runId>/<slug>.md` via Write tool with:
   ```yaml
   ---
   status: proposed
   target: 20_업무위키/<category>/<note>.md
   ---
   ```
2. Get human approval, then edit the proposal: `status: proposed` → `status: approved`.
3. Call `eversvault-obsidian`'s `vault_patch` (surgical edit) or `vault_write` (only if
   `target:` doesn't exist yet) against the `target:` path.
4. Edit the proposal again: `status: approved` → `status: applied` (or `rejected` if
   declined). This is now just a record-keeping convention — the guard no longer checks
   or requires any of these transitions before allowing a canonical write.

Since this path is opt-in now rather than enforced, the previously-documented race
condition (`_ev_has_approved_proposal` has no atomic claim on a ticket, so two sessions
reflecting the same `approved` proposal near-simultaneously could both succeed) matters
less as a *gate* concern, but the same double-write risk exists for **any** concurrent
direct edit to the same canonical note now, staged or not — there is no locking anywhere
in this system. If that ever matters in practice, treat it as a fresh problem to solve,
not something the removed gate was protecting against.

Cleanup of `applied`/`rejected` `_pending` files is still out of scope for Claude Code —
the vault-wide `delete_file`/`move_file` block still applies to them. A human clears them
manually when `_pending/` grows large enough to matter.

---

## 3. MCP server

Registered locally (NOT config-synced — `~/.claude.json` is machine-local) as
`eversvault-obsidian`, pointing at the Obsidian Local REST API with MCP plugin's
endpoint on the machine that hosts the vault. The machine gate itself is hostname-based
(`_ev_is_mac_mini` in guardrails.py, mirrored in `eversvault-context.sh`'s `*macmini*`
case) — `eversvault-scope.json` isn't a gate mechanism, it's just a file that only
happens to exist on that machine. The bearer token lives only in that local
`~/.claude.json` entry and in the plugin's own `data.json`; it is never written to this
repo.

A newly-registered MCP server only loads for sessions started after registration — if
its tools are unavailable, restart the session before assuming something is broken.

**`vault_list` silently omits folders it hasn't indexed** — an empty or newly-created
folder does not appear in `vault_list`'s output at all, even though it exists on disk.
Do not use `vault_list` to check "does this folder exist / is it really empty" — use
filesystem `Read`/`glob` (the same approach `eversvault-index.py`/
`eversvault-staleness-scan.py` already use) for that.

---

## 4. Staleness scan (governance, unaffected by the 2026-07-31 policy change)

`claude/hooks/eversvault-staleness-scan.py <vaultPath>` — on-demand, not auto-injected
into SessionStart. Filesystem-only (works with Obsidian closed). Scans `20_업무위키`
canonical notes for four candidate defects — stale `updated` field (>90 days; falls back
to file mtime, flagged as such, when the field is missing or unparseable), broken
`[[wikilinks]]` (vault-wide basename resolution; embeds of non-note attachments like
`![[image.png]]` are excluded, not treated as broken), orphan notes (nothing links to
it), oversized notes (>300 lines or >20KB). It only reports candidates; it never deletes
or edits anything.

`20_업무위키/_pending` gets three additional reports (still meaningful even though
staging is now optional rather than required): a status-count summary covering every
file regardless of age; proposals stuck at `status: proposed` for >30 days or
`status: approved` for >7 days; and `status: applied`/`rejected` files older than 90
days, listed as cleanup candidates (Claude Code cannot delete them). Age for the two
age-based listings is measured by file mtime, not a `created:` field — any edit inside
`_pending/` resets the clock. The status-count summary itself has no age dimension.

## 5. Cross-references

- Guard rules (source of truth for allow/deny) → `claude/hooks/guardrails.py`
  (`_ev_guard`, `_ev_check_target`, and helpers — see the inline comment on
  `_ev_check_target` for exactly what to restore if the gated policy is reinstated).
- Read-side index injection → `claude/hooks/eversvault-context.sh`,
  `claude/hooks/eversvault-index.py` (also surfaces `10_컨텍스트` `review:` cadence
  overdue warnings — read-only alerting, not enforcement; `review: on-change` is
  event-triggered and intentionally never flagged as overdue).
- Staleness scan → `claude/hooks/eversvault-staleness-scan.py` (§4 above).
- Vault path + in-scope project list (local-only) → `~/.claude/eversvault-scope.json`.
- Full plan, ADR, and verification history → `~/.omc/plans/eversvault-llm-wiki.md`.
