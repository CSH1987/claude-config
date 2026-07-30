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
| `20_업무위키/<category>/*.md` (canonical) | MCP `patch_content` (this doc's convention — the guard itself also passes Write/Edit/MultiEdit/`write_file`/`edit_file` when the ticket matches, but only `patch_content` does a targeted surgical edit instead of a full overwrite) | allowed only when a matching `_pending` proposal has `status: approved` and `target:` normalizes to the same path |

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

## 4. Cross-references

- Guard rules (source of truth for allow/deny) → `claude/hooks/guardrails.py`
  (`_ev_guard` and helpers).
- Read-side index injection → `claude/hooks/eversvault-context.sh`,
  `claude/hooks/eversvault-index.py`.
- Vault path + in-scope project list (local-only) → `~/.claude/eversvault-scope.json`.
- Full plan, ADR, and Phase 2 verification matrix → `~/.omc/plans/eversvault-llm-wiki.md`.
