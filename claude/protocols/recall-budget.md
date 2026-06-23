<!--
  PUBLIC FILE — claude-config repo (SessionEnd auto-push).
  Rules, budgets, and thresholds ONLY. NEVER put real PII, secrets, real names, emails,
  or tokens here. Use placeholders such as <full_name>, user@example.com, <machineId>.
  gate1 (commit-allowlist) admits this file by exact name. Keep the filename stable.
-->

# Recall Budget & Metric Determinism (PUBLIC · canonical)

Plan v9 references: 0-I (A1 deterministic injection), 0-J (A2/A3 metrics, cold-start
longitudinalization, M-A2 post-acceptance gate), M5 (determinism honesty + thresholds),
0-C/0-H (decisions union, fixed-path direct read).

This document governs (1) the **token budget** for what is injected/recalled per session,
(2) **what** is recalled and from where, and (3) the **deterministic filling** of the A2/A3
growth metrics with their precision/recall thresholds. It is consumed by the SessionStart
injection hook, the `recall` skill, and the metric hooks. Rules only — never real data.

---

## 1. SessionStart injection budget (A1 — deterministic, v9 0-I)

SessionStart injection is **model-independent and deterministic**: a hook
(`claude/hooks/memory-inject.{ps1,sh}`) reads `profile/user-profile.json` via the resolver
and emits it as `additionalContext` (same `hookSpecificOutput.additionalContext` shape as
`effort-reminder.{ps1,sh}`). No model call decides what is injected — this is A1's only hard
acceptance gate (v9 0-J).

**Budget (per SessionStart):**

| Slice | What | Soft cap | Overflow policy |
|---|---|---|---|
| profile core | stable preferences / standing constraints from `profile/user-profile.json` | ~800 tokens | keep highest-priority keys; spill rest to on-demand `recall` |
| recent decisions pointers | anchor-ids of N most-relevant `decisions/<machineId>/*.md` (union) | ~400 tokens | pointers only (ids + one-line titles), not full bodies |
| health/status line | counts + last backup/snapshot + degraded flags from `metrics.md` | ~150 tokens | single line; drop detail before dropping the warning |
| **total injected** | | **~1500 tokens** | strictly bounded; deep content via on-demand `recall`, never auto-injected |

- **Path discipline (v9 0-B):** the hook resolves the store via
  `~/.claude/lib/memdir.ps1 -Export` / `eval "$(bash ~/.claude/lib/memdir.sh --export)"`
  or `CLAUDE_MEMORY_DIR`. No hardcoded paths.
- **Fail-safe (v9 0-B/0-I):** the hook **never blocks a session**. On any error (missing
  env, unreadable profile, malformed JSON) it injects nothing and exits 0 silently — same
  fail-open convention as the existing SessionStart hooks and `config-sync`.
- **Determinism over relevance:** injection selection is by static priority/recency, not by
  a model judgment, so the same profile yields the same injection every session (A1).
- **PUBLIC safety:** this budget doc holds no profile data. The *data* lives PRIVATE in
  `profile/`; only the *budget rules* are public.

---

## 2. On-demand recall (deep, `recall` skill)

Beyond the bounded SessionStart injection, the `recall` skill performs deep retrieval on
demand and assigns an **anchor-id** to each recalled item (so a later reference can be
matched — see §4 `recall_hit`).

**Recall sources and what each is allowed to answer:**

| Source | `recall_source` | Scope | Crosses projects? |
|---|---|---|---|
| `profile/user-profile.json` | `profile` | stable preferences/constraints | yes (fixed-path direct read) |
| `decisions/<machineId>/*.md` (all shards, union) | `decisions` | past decisions — **A3 canonical** | **yes** — fixed-path direct read, all shards unioned |
| `wiki_query [[link]]` | `wiki` | same-project semantic enrichment **only** | **no** — OMC `projectId` shards by cwd |
| `session_search` (FTS5 transcripts) | `session_search` | cold full-text recall | per-project |

- **A3 carrier (v9 0-H):** cross-project decision recall is satisfied **only** by
  `decisions/*.md` fixed-path direct read with **all shards unioned** (`recall_source =
  "decisions"`). `wiki_query` is same-project enrichment only and **must not** be used to
  judge A3 — `projectId` sharding would otherwise produce a cross-project false-PASS.
- **Recall budget per query:** return **top-N** ranked items (N tuned per source); do not
  dump whole shards. Working-memory pressure is relieved by `notepad_prune` / PreCompact /
  Stop hooks, not by shrinking recall correctness.

---

## 3. Why these budgets (rationale, kept honest)

- The ~1500-token SessionStart cap exists to make injection **cheap and deterministic** —
  large/relevance-ranked content is precisely what belongs in on-demand `recall`, not in
  every session's prefix.
- Caps above are **provisional starting points**, not measured optima. Re-tune when the
  health line shows repeated injection truncation or when `anchor_reinject_count` rises
  (the system re-injecting the same anchor suggests the cap is too tight). Record any
  re-tune here with date and reason.

---

## 4. Deterministic metric filling (A2/A3/A11 — v9 0-J, M5)

Two heuristics are filled **deterministically** by hooks into the events shard
(`events/<machineId>.jsonl`); `metrics.md` is a **mode-A-only derive** from those shards.

### `rework` (quality proxy)
- **Definition (v9 0-J, target):** a PostToolUse/Stop hook sets `rework=true` when a **file +
  symbol diff** shows the same file/symbol being re-edited to undo or redo prior work within a
  window. `rework_anchor` records the anchored unit.
- **Implementation status (v1 — `edit-track`/`stop-metrics` hooks):** the shipped v1 is a
  **file-level cross-session proxy**, intentionally weaker than the target above. It sets
  `rework=true` when a file path edited in the current session was previously edited by a
  *different* session (tracked in `$OMC_STATE_DIR/edit-history.json`, path→last_session). It has
  **no symbol granularity, no diff comparison, and no time window** — so pure forward-progress
  (continuing work on a file across sessions/days) and high-churn shared files (e.g. settings)
  also flag. `rework_anchor` carries a `file:` prefix to mark this file-level scope so consumers
  can tell the weak signal apart. This is an honest under-implementation (M5): the signal stays
  **gate-suspended** (§5) until a labeled set validates/tightens it.
- **Roadmap (v2):** add a time window + symbol/diff (closing the gap to the target definition),
  and add state GC for `edit-history.json` / orphan `edit-track/` shards (currently unbounded —
  a local, git-ignored `omc-state` cost, not a correctness risk).
- Deterministic: v1 is an id/path-equality comparison, not a model judgment. It is **not**
  marketed as semantically perfect (M5 honesty) — its validity is gated by §5 precision/recall.

### `recall_hit` (recall effectiveness)
- **Definition (v9 0-J):** set `recall_hit=true` when a later turn **references an
  anchor-id** that an earlier `recall` assigned (anchor-id cross-check), with
  `recall_anchor` = the matched id and `recall_source` = the producing source.
- Deterministic: id-equality match, not a model judgment.

### Honesty label (M5)
- The two heuristics are **not** claimed to be perfectly "deterministic measures of
  quality/recall". They are deterministic *signals* whose *measurement validity* is itself
  gated by a labeled validation set (§5). Do not over-claim.

---

## 5. Precision/recall threshold gate (v9 M5, 0-J)

The metric-filling heuristics are only declared **valid** ("결정 채움 유효") once they pass
a labeled check:

- **Gate:** on a hand-labeled validation set of **N ≥ 30** examples, both
  **precision ≥ 0.8 AND recall ≥ 0.8** for `rework` and `recall_hit`.
- **Provisional values (M5):** `0.8` and `N ≥ 30` are **provisional**. Recorded here with:
  - **selection basis:** 0.8 is a conventional "usable signal, not noise" floor; N ≥ 30 is
    the small-sample threshold where a proportion estimate first stabilizes enough to act on;
  - **sensitivity (one line):** below N ≈ 30 the precision/recall estimate is too wide to
    trust (a few mislabels swing it materially); raising the bar toward 0.9 trades recall for
    precision and should follow real false-positive cost, not aesthetics;
  - **re-tune trigger:** revise these values if, after the gate opens, the health line shows
    persistent disagreement between the heuristic and observed rework, or if labelers report
    systematic mislabeling. Log each change here with date and reason.

---

## 6. Cold-start handling & the M-A2 post-acceptance gate (v9 0-J)

Accumulated history starts at ~0 (spec:85), so A2 cannot be a measured hard gate at
acceptance time.

- **A2 is longitudinal:** declared a post-acceptance metric. **No hard A2 verdict at
  acceptance** — only A1 (deterministic injection) is hard at acceptance.
- **Suspended until N ≥ 30:** while `label_n < 30`, the §5 gate is **suspended**
  (`gate_suspended = true`); A11 metric determinism is honored but not gated.
- **Cold-start proxy (honest):** before history exists, only measure "the system is doing
  its job" — that injection happened and the same anchor isn't needlessly re-injected
  (`anchor_reinject_count`, `reask_count` near zero). This does **not** measure spec:62 real
  success; that limitation is stated openly.
- **M-A2 milestone gate:** the moment `label_n ≥ 30` is reached is a **scheduled
  post-acceptance acceptance gate**. At that milestone the system must pass:
  - precision ≥ 0.8 **AND** recall ≥ 0.8 on the validation set (§5), **AND**
  - rework rate `t2 < t1` (later window improves on earlier).
  This is documented as a **post-acceptance acceptance condition**, closing the AC#2
  evidence gap without forcing a measured verdict at cold-start acceptance.

---

## 7. Labeling procedure (operator-facing · `[USER ACTION]`)

- **Labeler:** the user.
- **Minimum sample:** N ≥ 30 hand-labeled examples per heuristic (`rework`, `recall_hit`).
- **Procedure:** sample events with the heuristic's boolean set; the labeler marks each as
  true/false ground truth; compute precision/recall against the heuristic; record N and the
  two scores into the events stream (`label_n`) and the `metrics.md` health line.
- **Re-measurement cadence:** re-label and recompute periodically (and whenever a §5 re-tune
  trigger fires) so the gate reflects current behavior rather than a one-time snapshot.

---

## 8. Health surfacing

`metrics.md` (mode-A derive) exposes the recall/metric health on one line each:
counts, rework rate, recall-hit rate, `label_n`, `gate_suspended`, `degraded_to_proxy`,
and `reconcile-stale`. SessionStart shows a compact status; the dashboard (component ⑥) is
read-only. None of these surfaces ever contain real PII — only counts and flags.

---

## 9. Cross-references

- Leak-guard gates, shard schema, ownership map → `claude/memory/SCHEMA.md`.
- Promotion hops, identity-class default-on, `/promote` non-bypass → `claude/protocols/memory-promotion.md`.
- Path resolver (no hardcoded paths) → `claude/lib/memdir.ps1` · `claude/lib/memdir.sh`.
- SessionStart `additionalContext` output shape → `claude/hooks/effort-reminder.ps1` · `effort-reminder.sh`.
- A1 deterministic injection hook → `claude/hooks/memory-inject.ps1` · `memory-inject.sh`.
