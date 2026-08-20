<!--
  PUBLIC FILE — claude-config repo (config-sync). Rules and structure ONLY.
  NEVER put the real vault absolute path, API tokens, or real note content here.
  vaultPath lives only in the local, non-synced `~/.claude/vault-scope.json`.
-->

# Vault Write Protocol (PUBLIC · canonical)

Plan: `~/.omc/plans/vault-llm-wiki.md`.
Enforcement: `claude/hooks/guardrails.py` Vault block (`_ev_guard`/`_ev_check_target`).
Read-side index injection: `claude/hooks/vault-context.sh` + `vault-index.py`.

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
  and the `vault-obsidian` MCP tools. If a Bash write to a protected path is denied
  even though this document says direct writes are allowed, this is why — switch to one
  of those two channels.
- The `'..'`-escape block for `vault-obsidian` tools (paths are schema-guaranteed
  vault-relative; a leftover `..` is never legitimate regardless of write policy).
- `00_홈.md` sentinel self-protection — not approval friction, a structural safety valve
  (`_ev_config()`'s sentinel check depends on this file; corrupting it fail-opens the
  *entire* Vault guard block, including the safeguards above). The sentinel check
  itself requires the first line to be an actual Markdown H1 (`^#\s.*에버스 위키 홈`), not
  just a substring match anywhere in the line — tightened 2026-08-01 to match the
  original deep-interview spec (a bare substring match was weaker than intended, though
  low practical risk since a stray file happening to contain that exact phrase is
  unlikely). `_ev_config()` **fail-opens** on a sentinel mismatch — see the Claude-side
  check in §2a step 3, which is the only defense in exactly that failure scenario.

**Current OS permission policy:** the Phase 1 `444`/`555` read-only experiment has been
retired. `10_컨텍스트` follows normal Vault permissions (files 644, directories 755), so
the current direct-write policy works without a separate chmod step. Do not reapply
folder-wide read-only permissions during restore. `00_홈.md` remains the only sentinel
whose modification is prohibited by the existing system instructions and guard.

`_ev_has_approved_proposal` (the old gate-check function) and the staged `_pending`
workflow described below are **not deleted** — they're simply no longer *required*.
Reverting to the gated policy means restoring the folder-specific branches in
`_ev_check_target` (see the inline comment in `guardrails.py` for the exact code to
restore) and re-enabling the sections below.

---

## 0. Channels (current policy)

| Vault path | Write channel | Gate |
|---|---|---|
| `10_컨텍스트` | Write/Edit/MultiEdit, or `vault-obsidian` `vault_write`/`vault_patch`/`open_file`/`vault_append` | none — direct write allowed |
| `90_Hermes` | same as above | none — direct write allowed (no longer Hermes-exclusive; provenance is no longer guaranteed) |
| `30_결정로그` | Write tool, direct | none (unchanged from before) |
| `20_업무위키/_pending/<id>/` | Write tool, direct | none — Write channel unchanged from before; `vault_append` here was blocked pre-2026-07-31 ("예외없이") and is now allowed along with everything else, since that block existed only to protect the now-removed approval queue |
| `20_업무위키/<category>/*.md` (canonical) | any of the above | none — direct write allowed, no `_pending` approval required |
| `00_홈.md` | — | always deny (self-protection, kept) |

Vault-wide, regardless of path: `delete_file`/`move_file`/`command_execute` always deny;
Bash commands referencing the local REST API host:port always deny; Bash file-write
commands (`tee`/`>`/`cp`/`sed -i`/`chmod`/etc.) targeting a protected folder *or the vault
root itself* always deny (Write/Edit/MultiEdit and the MCP tools are the only write
channels); `vault-obsidian` paths with a leftover `'..'` always deny.

This guard covers Claude's own interactive Bash tool calls (guardrails.py is a PreToolUse
hook — it inspects tool invocations, not arbitrary processes). Deterministic infra
processes that Claude Code's own hook/launchd runtime spawns outside any tool call
(e.g. `vault-session-log.sh` on SessionEnd, the learning-pipeline's launchd job) are
intentionally out of scope and do write to the vault directly via plain Bash/Python —
that's expected, not a guard bypass. Don't mistake a `source:`-tagged file appearing in
`90_Hermes/로그` with no matching tool-call log for an incident.

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
Write/Edit/MultiEdit or the `vault-obsidian` MCP tools, same as any other file.
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
3. **Sentinel check before touching canonical content:** read `00_홈.md`, confirm the
   first line is a Markdown H1 containing "에버스 위키 홈" (`^#\s.*에버스 위키 홈`). If it
   doesn't match, stop — do not reflect. `_ev_config()` performs the same check
   internally but **fail-opens** on a mismatch (the whole Vault guard block goes
   silent rather than blocking), so in exactly the scenario where the sentinel is wrong,
   the guard isn't checking anything — this Claude-side check is the only defense at
   that point.
4. Call `vault-obsidian`'s `vault_patch` (surgical edit) or `vault_write` (only if
   `target:` doesn't exist yet) against the `target:` path.
5. Edit the proposal again: `status: approved` → `status: applied` (or `rejected` if
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
`vault-obsidian`, pointing at the Obsidian Local REST API with MCP plugin's
endpoint on the machine that hosts the vault. The machine gate itself is hostname-based
(`_ev_is_mac_mini` in guardrails.py, mirrored in `vault-context.sh`'s `*macmini*`
case) — `vault-scope.json` isn't a gate mechanism, it's just a file that only
happens to exist on that machine. The bearer token lives only in that local
`~/.claude.json` entry and in the plugin's own `data.json`; it is never written to this
repo.

A newly-registered MCP server only loads for sessions started after registration — if
its tools are unavailable, restart the session before assuming something is broken.

**`vault_list` silently omits folders it hasn't indexed** — an empty or newly-created
folder does not appear in `vault_list`'s output at all, even though it exists on disk.
Do not use `vault_list` to check "does this folder exist / is it really empty" — use
filesystem `Read`/`glob` (the same approach `vault-index.py`/
`vault-staleness-scan.py` already use) for that.

**Token rotation.** The bearer token is a static literal in `~/.claude.json`'s
`vault-obsidian` entry — it does not auto-refresh. If the plugin re-issues a token
(manual re-generation in plugin settings, plugin reinstall, or vault re-registration),
every `vault-obsidian` call starts failing with an auth error. Re-registration
procedure:
1. Read the new key from the plugin's `data.json` (`Vault/.obsidian/plugins/
   obsidian-local-rest-api/data.json`, `apiKey` field) — Obsidian must be running for
   this file to be current.
2. Replace the `Authorization: Bearer <token>` value in `~/.claude.json`'s
   `vault-obsidian` entry with the new key (this file is machine-local, not
   config-synced — edit it directly on the affected machine).
3. Restart the Claude Code session — a running session won't pick up the change.

---

## 4. Staleness scan (governance, unaffected by the 2026-07-31 policy change)

`claude/hooks/vault-staleness-scan.py <vaultPath>` — on-demand, not auto-injected
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

## 5. Known low-priority items, deliberately not fixed

From the 2026-07-31 full-system test workflow, kept as documented trade-offs rather than
fixed:

- **Bash `cp`/`mv` reading *out of* a protected folder is over-blocked.** `_ev_bash_writes_to`
  scans every token uniformly (by design — a prior fix moved away from position-dependent
  capture specifically to avoid `rm -rf`/`cp -r`/`chmod -R` flag-position bugs), so
  `cp <protected-file> /tmp/x` gets treated as a vault write even though the vault path is
  only the *source*, not the destination. Reintroducing "only the last positional arg is
  the write target" for `cp`/`mv` specifically would reopen exactly the class of bug the
  position-independent rewrite fixed. Workaround: use the `Read` tool instead of Bash `cp`
  to get vault content out — always available, no reason to hit this in practice.
- **`_ev_frontmatter`'s 200-line-from-disk read vs. `vault-index.py`/
  `vault-staleness-scan.py`'s whole-file-read-then-200-line-scan are inconsistent.**
  Currently moot: `_ev_frontmatter`'s only caller, `_ev_has_approved_proposal`, is unreachable
  since the 2026-07-31 gate removal (see above) — revisit if the gated policy is ever
  reinstated.
- **`search_query`'s regex resilience at scale is unverified.** Confirmed safe against small
  test inputs; large-corpus (tens of KB+) ReDoS behavior was out of scope for a review that
  couldn't risk hanging a shared session. Not expected to matter at this vault's actual size.

## 6. Cross-references

- Guard rules (source of truth for allow/deny) → `claude/hooks/guardrails.py`
  (`_ev_guard`, `_ev_check_target`, and helpers — see the inline comment on
  `_ev_check_target` for exactly what to restore if the gated policy is reinstated).
- Read-side index injection → `claude/hooks/vault-context.sh`,
  `claude/hooks/vault-index.py` (also surfaces `10_컨텍스트` `review:` cadence
  overdue warnings — read-only alerting, not enforcement; `review: on-change` is
  event-triggered and intentionally never flagged as overdue).
- Staleness scan → `claude/hooks/vault-staleness-scan.py` (§4 above).
- Vault path + in-scope project list (local-only) → `~/.claude/vault-scope.json`.
- Full plan, ADR, and verification history → `~/.omc/plans/vault-llm-wiki.md`.
