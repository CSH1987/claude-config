<!--
  PUBLIC FILE — claude-config repo (config-sync). Rules and structure ONLY.
  NEVER put the real vault absolute path, API tokens, or real note content here.
  vaultPath lives only in the local, non-synced `~/.claude/eversvault-scope.json`.
-->

# EversVault Write Protocol (PUBLIC · canonical)

Plan: `~/.omc/plans/eversvault-llm-wiki.md` (Phase 2 — 쓰기배선).
Enforcement: `claude/hooks/guardrails.py` EversVault block. Below, the **Gate** column
is what the guard actually enforces (deny/allow by approval-ticket state — it does not
distinguish which tool/MCP-call performed the write); the **Channel** column is a
behavioral convention this document defines on top of that, not a separate
enforcement layer. Read-side index injection: `claude/hooks/eversvault-context.sh` +
`eversvault-index.py`.

**Not the same contract as `memory-promotion.md`.** That protocol governs
`claude-memory` (`profile/`, `decisions/<machineId>/`, `_pending/` hop1/hop2). This
protocol governs EversVault (Obsidian) vault paths only. Do not conflate the two
`_pending/` staging areas or the two promotion/approval flows — they are isolated by
design (plan Phase 2 note, "Round 1 확정에서의 이탈").

---

## 0. Channels

| Vault path | Write channel (convention) | Gate (guard-enforced) |
|---|---|---|
| `10_컨텍스트` | none — Claude Code never writes here | always deny (사람 정본) |
| `90_Hermes` | none — Claude Code never writes here | always deny (읽기는 승격목적 허용) |
| `30_결정로그` | Write tool, direct | no folder-specific rule — but the vault-wide `delete_file`/`move_file` block and the `00_홈.md` block still apply here too |
| `20_업무위키/_pending/<id>/` | Write tool, direct | always allow (new file, or edit of an existing proposal's frontmatter) |
| `20_업무위키/<category>/*.md` (canonical) | MCP `patch_content`[^1] (this doc's convention — the guard itself also passes Write/Edit/MultiEdit when the ticket matches, but only a targeted patch does a surgical edit instead of a full overwrite) | allowed only when a matching `_pending` proposal has `status: approved` and `target:` normalizes to the same path |

[^1]: "`patch_content`" is this doc's generic name for the operation (matches `guardrails.py`'s
older substring-matching naming). The actual registered MCP tool is `eversvault-obsidian`'s
`vault_patch` — see §3.

`00_홈.md` (vault sentinel) is never written by Claude Code under any circumstance —
the guard blocks it unconditionally to protect its own self-check.

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
- No approval step, no MCP call needed to write here. Note the vault-wide blocks still
  apply: MCP `delete_file`/`move_file` are blocked everywhere in the vault, and
  `00_홈.md` can never be touched — this folder just has no *folder-specific* rule.

## 2. `20_업무위키` — propose then reflect

### 2a. Proposing (always allowed, no approval needed to draft)

Create `20_업무위키/_pending/<runId>/<slug>.md` via Write tool.

Required frontmatter:
```yaml
---
status: proposed
target: 20_업무위키/<category>/<note>.md
---
```
`target:` is mandatory — the guard normalizes both this value and the MCP call's path
to vault-relative form and string-matches them. A proposal without `target:` can never
be reflected.

**Do not add an inline `#` comment on the `target:` line.** The guard's frontmatter
parser (`_ev_frontmatter` in guardrails.py) only strips surrounding quotes, not trailing
comments — a value like `20_업무위키/x.md   # some note` is taken literally, will never
normalize-match the real path, and the proposal will be silently unreflectable (blocked,
not erroring loudly). Put any explanatory note in the note body, never on the
`target:` line itself.

### 2b. Approval reflection (only after explicit human approval this turn)

1. Human approves the specific proposal in the current conversation turn.
2. Edit the proposal file: `status: proposed` → `status: approved`. (Always allowed —
   edits inside `_pending/` are unconditionally permitted, including this transition.)
3. **Sentinel check before touching canonical content:** read `00_홈.md`, confirm the
   first line contains "에버스 위키 홈". If it does not match, stop — do not call
   `patch_content`. The guard performs the same check internally, but `_ev_config`
   **fail-opens** on a sentinel mismatch (the whole EversVault guard block goes silent
   rather than blocking) — so in exactly the scenario where the sentinel is wrong, the
   guard is not checking anything. This Claude-side check is the *only* defense at that
   point, not a redundant second layer.
4. **If the proposal is already `approved` from a previous, interrupted attempt**
   (e.g. resuming after a crash), read the target note first and check whether the
   intended change is already present before calling `patch_content` again — a prior
   attempt may have applied it but died before step 5 recorded that. If already present,
   skip straight to step 5. This is the only way to detect that case, since the guard
   only sees the frontmatter status, not the note content.
5. Call the `eversvault-obsidian` MCP server's `patch_content` tool against the
   proposal's `target:` path, targeting the appropriate heading/block.
6. **On success:** edit the proposal file again, `status: approved` → `status: applied`.
   This is what prevents replay — the guard only treats `status: approved` as a valid
   reflection ticket, so an already-applied proposal cannot be reflected a second time
   without a fresh, explicitly re-approved proposal. (This step is what step 4 exists to
   protect against skipping when resumed mid-flight.)
7. **On failure:** leave `status: approved` as-is (so a retry is still possible) and
   surface the error to the user — do not silently mark it `applied`.

Never use `append_content` or `delete_file` against `20_업무위키` — both are
unconditionally blocked by the guard (no legitimate path exists; that is intentional).

### 2c. Promoting from `90_Hermes` (Phase 3 governance)

Plan: `~/.omc/plans/eversvault-llm-wiki.md` Phase 3. Claude Code may **read** `90_Hermes`
freely (the guard allows it — "읽기는 승격목적으로만 허용") to look for durable, reusable
knowledge worth folding into `20_업무위키`. It may never write there under any
circumstance — that stays exclusively Hermes's write domain, unconditionally, including
for staging or simulating content.

When a `90_Hermes` file contains something worth promoting, follow the exact same
proposing flow as §2a, with one addition: record provenance so the human reviewer knows
this originated from an automated Hermes output, not a Claude Code observation.

```yaml
---
status: proposed
target: 20_업무위키/<category>/<note>.md
source: 90_Hermes/<original-path>.md
---
```

Everything else — approval, reflection, `applied` transition, replay protection — is
identical to §2b: `patch_content` (§0 footnote 1) for a surgical edit to an **existing**
canonical note; `vault_write` only when `target:` names a note that does not exist yet
(patch_content edits a document's structure, it cannot create the file itself — see the
plan's Phase 1 note, "승인된 신규개념의 최초 생성도 동일 규칙으로 커버"). Never use
`vault_write` to blanket-overwrite an existing canonical note when a targeted patch would
do. There is no separate promotion mechanism; `source:` is purely informational metadata
for the human approving the proposal.

**Verification note (2026-07-30):** live end-to-end promotion could not be demonstrated
because `90_Hermes` currently has zero files — Hermes has not written any output to this
vault yet. This is a legitimate blocker, not a design gap: the read/propose codepath is
identical to the already-verified §2a/2b flow (same guard rules, same `_pending` staging),
so there is no new mechanism left un-exercised — only the trigger condition (an actual
Hermes artifact to read) is currently absent. Re-verify with a real file once Hermes
starts producing output here.

**Cleanup of `applied` proposals is out of scope for Claude Code by design.** Every
delete/move channel into `_pending/` is blocked vault-wide (MCP `delete_file` always;
Bash writes anywhere under `20_업무위키` always), so old `applied` proposal files
accumulate indefinitely. This is intentional, not an oversight — a human clears them
manually from Finder or Obsidian when `_pending/` grows large enough to matter (it only
affects the guard's `_pending` glob-scan cost, not correctness).

---

## 3. MCP server

Registered locally (NOT config-synced — `~/.claude.json` is machine-local) as
`eversvault-obsidian`, pointing at the Obsidian Local REST API with MCP plugin's
HTTPS endpoint on the machine that hosts the vault. The machine gate itself is
hostname-based (`_ev_is_mac_mini` in guardrails.py, mirrored in
`eversvault-context.sh`'s `*macmini*` case) — `eversvault-scope.json` isn't a gate
mechanism, it's just a file that only happens to exist on that machine. The bearer
token lives only in that local `~/.claude.json` entry and in the plugin's own
`data.json`; it is never written to this repo.

A newly-registered MCP server only loads for sessions started after registration —
if `patch_content` is unavailable, restart the session before assuming something is
broken.

---

## 4. Staleness scan (Phase 3 governance)

`claude/hooks/eversvault-staleness-scan.py <vaultPath>` — on-demand, not auto-injected
into SessionStart (a staleness sweep is a deliberate/periodic action, not something
every session needs). Filesystem-only (works with Obsidian closed). Scans
`20_업무위키` canonical notes for four candidate defects — stale `updated` field
(>90 days; falls back to file mtime, flagged as such, when the field is missing or
unparseable), broken `[[wikilinks]]` (vault-wide basename resolution; embeds of non-note
attachments like `![[image.png]]` are excluded, not treated as broken), orphan notes
(nothing links to it), oversized notes (>300 lines or >20KB) — plus `20_업무위키/_pending`
proposals stuck at `status: proposed` for >30 days or at `status: approved` (a live,
unexpired write ticket — treated as more urgent) for >7 days. Age for both is measured by
file mtime, not a `created:` field (proposals don't have one) — any permitted edit inside
`_pending/` (including the `proposed`→`approved` transition itself) resets the clock. It
only reports candidates; it never deletes or edits anything (that stays a human decision,
same principle as everywhere else in this protocol).

## 5. Cross-references

- Guard rules (source of truth for allow/deny) → `claude/hooks/guardrails.py`
  (`_ev_guard` and helpers).
- Read-side index injection → `claude/hooks/eversvault-context.sh`,
  `claude/hooks/eversvault-index.py`.
- Staleness scan → `claude/hooks/eversvault-staleness-scan.py` (§4 above).
- Vault path + in-scope project list (local-only) → `~/.claude/eversvault-scope.json`.
- Full plan, ADR, and Phase 2/3 verification matrices → `~/.omc/plans/eversvault-llm-wiki.md`.
