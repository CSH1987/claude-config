<!--
  PUBLIC FILE — claude-config repo (SessionEnd auto-push).
  Objectives, rules, and thresholds ONLY. NEVER put real PII, secrets, real names, emails,
  or tokens here. Use placeholders such as <full_name>, user@example.com, <machineId>.
  gate1 (commit-allowlist) admits this file by exact name. Keep the filename stable.
-->

# Optimization Objective & Tuning (PUBLIC · canonical)

Plan v10 Track 1 (G5). This document defines **what** the lifelong-growth orchestrator
optimizes, the **thresholds** that raise tuning signals, and **how** `metrics.md` surfaces
them. It is consumed by the metrics derivation (`claude/lib/metrics.{sh,ps1,py}`) and the
SessionStart/SessionEnd hooks. Rules and thresholds only — never real data.

---

## 1. Objective function (strict priority order)

The growth loop optimizes the following, **lexicographically** (never trade a regression in a
higher item for a gain in a lower one):

1. **Rework DOWN — primary.** Minimize re-doing the same file/symbol work (the `rework`
   signal). Lower rework = the system learned and is not repeating itself. This is the
   headline success signal (deep-interview AC: 재작업↓).
2. **Recall-hit UP — secondary.** Maximize correct cross-session recall/linking (the
   `recall_hit` signal): a prior anchor-id is correctly recalled when relevant. Higher recall
   = accumulated memory is actually load-bearing.
3. **Token-cost — CONSTRAINT (a bound, not a target).** Stay within the per-session injection
   /recall budget (see `recall-budget.md` §1). Cost is minimized only **after** (1) and (2)
   are satisfied; never sacrifice correctness/recall to shave tokens.

> Why lexicographic, not weighted: a weighted sum lets a cheap-but-wrong path score well.
> Priority order makes "correct and learning" dominate "cheap" by construction.

---

## 2. Thresholds (provisional — tune with evidence, not aesthetics)

| Signal | Threshold | Source of truth | Action when crossed |
|---|---|---|---|
| `rework_rate` | `> 0.30` (env `REWORK_WARN_RATE`) | `metrics.py` | emit TUNING line: review recent rework; consider recall-budget / routing tuning |
| `recall_hit_rate` | target set **after** `label_n ≥ 30` | `recall-budget.md` §5 | until then: report only (no hard target at cold-start) |
| `label_n` | `< 30` | `recall-budget.md` §5/§6 | precision/recall gate **suspended** (cold-start); label more to open the M-A2 gate |
| `reconcile-stale` | oldest `_pending` age `≥ 7d` (env `RECONCILE_STALE_DAYS`) | `reconcile-check.{sh,ps1}` | emit TUNING line: run `/reconcile` to apply the `_pending` backlog |
| token-cost | per-session injection ≤ ~1500 tok | `recall-budget.md` §1 | trim injection to highest-priority; spill to on-demand recall |

- `0.30` is a **provisional** "usable signal, not noise" floor for rework, consistent with the
  `0.8 / N≥30` provisional convention in `recall-budget.md` §5. Record any change here with
  date + reason.
- Thresholds are kept in ONE engine (`metrics.py`) so `.sh` and `.ps1` cannot drift; this doc
  is the human-readable mirror of those values.

---

## 3. Tuning mechanism — propose, never auto-apply

- `metrics.md` (mode-A derive) emits a **`## TUNING`** section whenever a threshold above is
  crossed. Each line names the signal, the value, and the suggested action.
- Tuning is **surfaced to the human / staged**, never auto-applied. Closed-loop optimization
  stays human-gated by design (a bad auto-tune could degrade the primary objective). The
  operator (or a future routine via `_pending` + reconcile) decides whether to apply.
- This honors the v9 honesty stance: heuristics are **signals**, not ground truth, until the
  precision/recall validation gate opens at `label_n ≥ 30` (M-A2 milestone).
- **Re-tune log** (append date + reason on each change):
  - 2026-06-22 — initial thresholds set (rework 0.30, reconcile-stale 7d) — provisional.

---

## 4. Cross-references
- Recall budget, precision/recall gate, cold-start, M-A2 milestone → `recall-budget.md`.
- Metrics derivation engine → `claude/lib/metrics.{sh,ps1,py}`.
- Reconcile-stale detector → `claude/hooks/reconcile-check.{sh,ps1}`; apply → `reconcile` skill.
- Promotion ladder & ownership → `memory-promotion.md`.
- Event schema (the raw signals) → `claude/memory/SCHEMA.md` §3.
