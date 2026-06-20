<!--
  PUBLIC FILE — claude-config repo (SessionEnd auto-push).
  Rules and structure ONLY. NEVER put real PII, secrets, real names, emails, or tokens here.
  Use placeholders such as <full_name>, user@example.com, <machineId>.
  gate1 (commit-allowlist) admits this file by exact name. Keep the filename stable.
-->

# Memory Promotion Protocol (PUBLIC · canonical)

Plan v9 references: 0-C (decisions sharding), 0-C2 (ownership machine-enforcement),
0-D (two-hop promotion split + /promote non-bypass), 0-D2 (identity-class default-on).

This document is the authoritative ritual for moving knowledge **up the durability
ladder**: from per-turn working memory, to the PRIVATE canonical store, to the PUBLIC
`claude-config` repo and the warm graph/vector tier. It is consumed by hooks, skills,
and the `/promote` flow. It contains rules only — never real personal data.

---

## 0. Promotion ladder (where things live)

```
Tier W  working memory      OMC notepad / context window        (ephemeral, never committed)
Tier P  PRIVATE canonical   $CLAUDE_MEMORY_DIR/profile|decisions (git-tracked, PRIVATE repo: claude-memory)
Tier G  warm graph/vector   $OMC_STATE_DIR/.../{wiki,shared}     (live OMC, NOT git-tracked; snapshot-mirrored)
Tier U  PUBLIC rules/skills  claude-config/claude/**             (git-tracked, PUBLIC repo, SessionEnd auto-push)
```

- **Path discipline (v9 0-B):** never hardcode store paths. Resolve with
  `~/.claude/lib/memdir.ps1 -Export` (PowerShell) / `eval "$(bash ~/.claude/lib/memdir.sh --export)"` (POSIX),
  or read `CLAUDE_MEMORY_DIR` / `OMC_STATE_DIR` from the environment.
- **PRIVATE vs PUBLIC (v9 0-D):** `profile/`, `decisions/`, `_pending/`, `events/`,
  `_sync-log/`, `metrics.md`, manifests live in the PRIVATE `claude-memory` repo.
  Only Tier U (rule docs + vetted skills) ever lives in PUBLIC `claude-config`.
- **PII never travels to PUBLIC except via Hop 2 (/promote).** There is no auto-push
  path from Tier P to Tier U. The PUBLIC repo's SessionEnd auto-push only sees files
  already inside the `claude-config` working tree.

---

## 1. The two promotion hops (v9 0-D — the core split)

v9 splits promotion into two distinct hops with **different gates**. Conflating them
was the R7 self-contradiction; keep them separate.

### Hop 1 — `_pending/` → PRIVATE canonical  (NO human gate)

- **Scope (v9 0-D, 0-C):** only **edits to existing mode-A-owned canonical records**
  (e.g. a cloud run proposes changing an existing `decisions/<hostA>/<id>.md` or a
  `profile/` field). Both sides are inside the PRIVATE `claude-memory` tree and PUBLIC
  is never touched, so **no human gate is required** — mode-A reconciles automatically
  in a PC-on session.
- **NEW cloud decisions do NOT use Hop 1 at all.** Under decisions sharding (0-C) a
  cloud-authored *new* decision is appended directly to its own shard
  `decisions/<machineId>/<id>.md` (machineId = `github` for GitHub Actions, `cloud` for
  `/schedule`) — append-only, read-time union. PC-off canon advances with no `_pending`
  and no reconciliation hop.
- **Mechanism:** cloud writes proposal to `_pending/<runId>/...` (PRIVATE). On the next
  mode-A (PC-on) session, the reconcile step applies or rejects it and records the
  outcome. Both trees are PRIVATE → safe to automate.
- **Staleness is observable (v9 0-G3):** a `_pending/` item unapplied for **N days
  (default 7)** raises the `reconcile-stale` health signal in `metrics.md` (an acceptance
  health threshold, not a mere follow-up). This bounds reconciliation latency. Because
  *new* decisions advance via sharding, this stale gate applies only to *edit proposals*.

### Hop 2 — PRIVATE canonical → PUBLIC  (`/promote`, human-review gate)

- **Scope (v9 0-D):** the **only** path that moves a PRIVATE canonical record/skill into
  the PUBLIC `claude-config` allowlist (new rule doc, distilled reusable skill).
- **Label (v9 0-D, corrected):** `/promote` is a **human-review gate (machine full-scan
  AND required)** — it is NOT "fail-closed by the human alone". Two conditions, both
  mandatory:
  - **(i) machine full-scan** — gates 1 / 2a / 2b / 3 run as a full pre-commit scan.
    A non-zero exit is a native git abort, so the scan **cannot be skipped or bypassed**.
  - **(ii) human review** — the operator actually reviews and approves the changed lines.
- **Non-bypass clause (v9 0-D):** the sole exit is *full-scan pass ∧ human review*. Any
  attempt to skip the scan (e.g. a skip flag) ends in a non-zero abort. The machine gates
  are fail-closed (uncircumventable); human review is the *additional* defense for the
  bare-name residue (gate 2b default-on already covers most of it — see §3).

```
working memory ──(SessionEnd retro)──► PRIVATE canonical (profile / decisions/<machineId>)
   cloud NEW decision ───(0-C shard append, no hop)────────────► decisions/<machineId>/ (PC-off canon)
   cloud EDIT of existing ──(Hop 1: _pending, auto-reconcile)──► PRIVATE canonical
   PRIVATE rule/skill ──(Hop 2: /promote = full-scan ∧ human)──► PUBLIC claude-config
```

---

## 2. Promotion triggers (when does something move up)

| From → To | Trigger | Gate | Owner |
|---|---|---|---|
| Tier W → auto-memory | end of a turn/session with a durable fact | none | hook |
| auto-memory → project-memory (warm) | fact survives ~7 days / reused | none | retro |
| project-memory → `decisions/<machineId>/` + `profile/` | fact is **cross-project** / load-bearing | none (PRIVATE, mode-A) | retro (SessionEnd / periodic) |
| cloud **new** decision → `decisions/<machineId>/` | cloud run reaches a decision | none — direct shard append (0-C) | mode-B (cloud) |
| cloud **edit** of existing record → `_pending/` → canonical | cloud wants to change a mode-A record | Hop 1 auto-reconcile | mode-B propose → mode-A apply |
| PRIVATE rule/skill → PUBLIC `claude-config` | a rule/skill is generic & reusable | **Hop 2 /promote** (full-scan ∧ human) | operator |
| canonical record → warm graph (`wiki_add`) / vector | record should be semantically recallable | none (warm, derived) | retro / snapshot |

- **Cross-project test:** a fact graduates to `decisions/`/`profile/` only when it is
  useful outside the recording session's `cwd`. OMC `projectId` shards by cwd, so warm
  graph recall does not cross projects — canonical fixed-path records are the cross-project
  carrier (see `recall-budget.md` A3).
- **Skill distillation:** a repeatable workflow first lands in `_pending/` for review,
  then graduates to PUBLIC/OMC via **Hop 2 /promote** (human-reviewed) — never auto-pushed.

---

## 3. Identity-class enforcement on promotion (v9 0-D2)

PUBLIC promotion must not leak `<full_name>`-class identity tokens. v9 makes the
identity gate **default-on** instead of opt-in:

- **bootstrap auto-extracts** identity tokens (real name, email domain, unique user id)
  from `profile/user-profile.json` into `$CLAUDE_MEMORY_DIR/.leakwords`
  (PRIVATE · gitignored). gate 2b then blocks bare identity tokens **by default**.
- The `[USER ACTION] confirm .leakwords` step is **required** (promoted from optional):
  the operator reviews/augments the auto-extracted token list.
- **Cold-start fail-closed (v9 M1):** if `profile/` is empty so `.leakwords` cannot be
  seeded, gate 2b is *disabled* — this is labeled a **cold-start-disabled** state, not
  "enforced". In that state the health line reads `identity-class disabled` and the FIRST
  PUBLIC push is held for a one-time LOUD confirmation. Do not claim bare-name PII is
  enforced until `.leakwords` exists.
- These gates are specified in full in `claude/memory/SCHEMA.md` (the leak-guard
  reference). This document only states *when* they fire during promotion.

> **PUBLIC-safety reminder for authors of this file and SCHEMA.md:** examples must use
> placeholders only — `<full_name>`, `user@example.com`, `<machineId>`,
> `ghp_EXAMPLEEXAMPLEEXAMPLE`. Never paste a real name, real email, or real token into a
> Tier U file. (Critic M1 found exactly this leak in an earlier SCHEMA.md draft.)

---

## 4. Ownership during promotion (v9 0-C, 0-C2)

Promotion writes must respect single-writer ownership; the pre-commit hook enforces it
mechanically (a native abort on violation), so promotion logic must already stage the
right paths.

- **mode-A (PC-on) owns:** `profile/`, `decisions/<hostA>/`, `metrics.md`,
  `_resolver-manifest.json`, `_snapshot-manifest.json`. Only mode-A promotes into these.
- **mode-B (cloud) writes only:** `events/<machineId>.jsonl`, `decisions/<machineId>/`,
  `cloud-digest/<runId>.md`, `_pending/`. A cloud run staging a mode-A-owned path is
  **rejected by pre-commit** (v9 0-C2); cloud commits use path-scoped `git add` (never
  `git add -A`).
- **Reconciliation (Hop 1)** is the only path by which a cloud-originated change reaches
  a mode-A-owned record, and it always runs under mode-A.

---

## 5. Promotion checklist (operator-facing)

1. Identify the hop: editing an existing mode-A record (Hop 1) vs. moving PRIVATE → PUBLIC
   (Hop 2). New cloud decisions need neither — they shard-append.
2. **Hop 1:** ensure proposal sits in `_pending/<runId>/`; let mode-A auto-reconcile;
   watch `reconcile-stale` (≥ 7 days unapplied = health warning).
3. **Hop 2 (`/promote`):**
   - confirm `.leakwords` is seeded (gate 2b default-on) — `[USER ACTION]` required;
   - run the full-scan (gates 1/2a/2b/3) — it cannot be skipped;
   - perform human line-by-line review of the staged PUBLIC diff;
   - only on *full-scan pass ∧ human approval* does the file enter `claude-config/claude/**`.
4. Verify the promoted record is registered in the gate1 allowlist (PUBLIC files admit
   by exact name) and appears in both backup locations (PRIVATE repo + PUBLIC repo).

---

## 6. Cross-references

- Leak-guard gate definitions (1 / 2a / 2b / 3), shard schema, ownership map → `claude/memory/SCHEMA.md`.
- Recall budget, metric determinism, precision/recall thresholds → `claude/protocols/recall-budget.md`.
- Path resolver (no hardcoded paths) → `claude/lib/memdir.ps1` · `claude/lib/memdir.sh`.
- A1 deterministic injection hook → `claude/hooks/memory-inject.ps1` · `memory-inject.sh`.
