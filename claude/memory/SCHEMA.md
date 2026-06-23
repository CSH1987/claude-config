<!--
  PUBLIC FILE — claude-config repo (auto-pushed on SessionEnd).
  This file documents the STRUCTURE of the private lifelong-memory store.
  It MUST NOT contain real PII, secrets, real names, emails, or tokens.
  Use placeholders only:  <full_name>  user@example.com  <gh_handle>  <machineId>
  Real data lives ONLY under $CLAUDE_MEMORY_DIR (PRIVATE, never committed to this repo).
  Gate1 allowlist: this file is one of {SCHEMA.md, memory-promotion.md, recall-budget.md, objective-function.md}.
-->

# Lifelong Memory — Schema & Rules (PUBLIC)

This document is the **authoritative schema** for the private, lifelong-growing memory
store used by the Claude Code orchestrator. It defines *structure and rules only*. The
actual data is **PRIVATE** and lives under the path resolved by the memory resolver
(`~/.claude/lib/memdir.{ps1,sh}`), never inside this PUBLIC repo.

- **Resolver (single source of truth for paths)** — never hardcode paths.
  - PowerShell: `& "$env:USERPROFILE\.claude\lib\memdir.ps1" -Export | iex` (or `-NoEnsure` for read-only).
  - POSIX: `eval "$(bash ~/.claude/lib/memdir.sh --export)"` (or `--no-ensure`).
  - Resolves `CLAUDE_MEMORY_DIR` (the store root, hereafter `$MEM`) and the derived
    `OMC_STATE_DIR=$MEM/omc-state`. In unattended/cloud contexts use `-Strict` / `--strict`
    (fail-closed: no `$HOME` fallback, abort if `CLAUDE_MEMORY_DIR` is unset).
- **PII boundary (hard rule).** `$MEM/` is PRIVATE. This PUBLIC file shows only the *shape*
  of each artifact with **placeholders**. Never paste a real value here. The leak guard
  (`claude/githooks/pre-commit`, gate2a/gate2b) will `abort` a commit that contains a real
  email/token/identity in any allowlisted PUBLIC file.

---

## 0. Store layout (`$MEM/`)

Complete enumeration of git-tracked durable artifacts (per plan v9 §0-C). Everything
under `omc-state/` is **git-ignored** (live OMC warm tier, not a canonical artifact).

```
$MEM/
├── profile/
│   └── user-profile.json            # mode-A owned (single writer = main PC)
├── decisions/
│   ├── <machineId>/                 # SHARDED, append-only, read-time union
│   │   └── <decision-id>.md
│   ├── <hostA>/                     # main-PC shard (mode-A authored)
│   │   └── <decision-id>.md
│   └── github/                      # cloud shard (GitHub Actions authored, PC-off)
│       └── <decision-id>.md
├── events/
│   └── <machineId>.jsonl            # SHARDED append-only; merge=union
├── _sync-log/
│   └── <machineId>.jsonl            # SHARDED backup/observability log; merge=union
├── metrics.md                       # mode-A DERIVE only (cloud never touches it)
├── cloud-digest/
│   └── <runId>.md                   # cloud per-run, append-only, pruned/rolled up
├── _pending/
│   └── <runId>/                     # PRIVATE promotion-hop1 staging (edit proposals)
├── _resolver-manifest.json          # mode-A owned (machineId / path / mode assertion)
├── _snapshot-manifest.json          # mode-A owned (OMC warm snapshot guard)
├── wiki-mirror/                     # snapshot of OMC warm wiki (mode-A)
├── .leakwords                       # PRIVATE, gitignored — identity tokens for gate2b
├── .gitattributes                   # events/*.jsonl, _sync-log/*.jsonl  merge=union
└── omc-state/                       # GIT-IGNORED (OMC live warm/state tier)
```

**Single-writer ownership (per file / per shard).** Each machine/mode writes *only its own
shard* — same-file contention is structurally impossible.

| Artifact | Owner | Cloud (mode-B) may write? |
|---|---|---|
| `profile/user-profile.json` | mode-A (main PC) | no — propose via `_pending/` (hop1) |
| `metrics.md` | mode-A derive | **no** (pre-commit rejects; 0-C2) |
| `decisions/<hostA>/` | mode-A | **no** (pre-commit rejects) |
| `decisions/github/` | mode-B (Actions) | yes — append-only, PC-off canonical advance |
| `events/<machineId>.jsonl` | that machine | yes (own shard only) |
| `_sync-log/<machineId>.jsonl` | that machine | yes (own shard only) |
| `cloud-digest/<runId>.md` | mode-B | yes (per-run) |
| `_pending/<runId>/` | mode-B proposes / mode-A reconciles | yes (proposals) |
| `_resolver-manifest.json`, `_snapshot-manifest.json` | mode-A | **no** |

`<machineId>` is read from `_resolver-manifest.json` and is the single token reused across
`events/`, `_sync-log/`, and `decisions/` shard names. Conventional values:
mode-A = `<hostname>`; GitHub Actions = `github`; Anthropic `/schedule` = `cloud`.

---

## 1. `profile/user-profile.json` — schema

**Purpose.** Durable, cross-project user model injected deterministically at session start
(A1) so a preference never has to be explained twice. **mode-A owned** (single writer).

**Conventions.**
- Encoding: UTF-8 **without BOM**, LF line endings.
- All keys are stable, lowercase `snake_case`, ASCII. Values may be any JSON type.
- `schema_version` is an integer; bump on breaking key changes.
- Every value below is a **PLACEHOLDER**. Real values live only in the PRIVATE store.
- Unknown/optional keys are allowed (forward-compatible); consumers must tolerate absence.
- The A1 SessionStart hook (`claude/hooks/memory-inject.{ps1,sh}`) is **schema-agnostic**:
  it flattens whatever top-level keys exist (scalars direct, arrays comma-joined, nested
  objects as `key=val; ...`, blanks skipped). Adding/renaming keys never breaks the hook.

```json
{
  "schema_version": 1,
  "updated_at": "2026-01-01T00:00:00Z",
  "updated_by": "<machineId>",

  "identity": {
    "display_name": "<full_name>",
    "handles": { "github": "<gh_handle>" },
    "contact_domain": "example.com",
    "locale": "ko-KR",
    "timezone": "Asia/Seoul"
  },

  "preferences": {
    "response_language": "ko",
    "tone": "<concise|detailed|...>",
    "effort_default": "xhigh",
    "code_comment_language": "ko",
    "emoji": false,
    "units": "metric"
  },

  "roles": [
    { "role": "<role_label>", "context": "<where_this_role_applies>", "priority": 1 }
  ],

  "working_style": {
    "plan_first": true,
    "tools_aggressive": true,
    "deep_interview_default": true,
    "commit_when_asked_only": true,
    "preferred_stacks": ["<stack_a>", "<stack_b>"],
    "preferred_tools": ["<tool_a>", "<tool_b>"]
  },

  "constraints": {
    "do_not": [
      "<forbidden_action_or_topic>",
      "<another_taboo>"
    ],
    "sensitive_topics": ["<topic_to_avoid_proactively>"],
    "no_proactive_mentions": ["<thing_to_mention_only_on_request>"]
  },

  "projects": [
    {
      "id": "<projectId>",
      "name": "<project_name>",
      "summary": "<one_line_summary>",
      "proactive": false
    }
  ],

  "anchors": ["<anchor-id>"]
}
```

**Field semantics.**
- `identity` — who the user is. Display name, handles, contact domain (placeholders here;
  these exact tokens are extracted by bootstrap into `.leakwords` so gate2b blocks them in
  PUBLIC commits). `locale`/`timezone` drive defaults.
- `preferences` — durable answer defaults (language, tone, effort, emoji, units). These are
  injected at A1 so they need not be restated.
- `roles[]` — hats the user wears and where each applies; `priority` orders conflicts.
- `working_style` — how the user wants work done (plan-first, aggressive tool use,
  deep-interview default, commit-only-when-asked, preferred stacks/tools).
- `constraints.do_not` / `sensitive_topics` / `no_proactive_mentions` — **taboos and
  guardrails**: things to never do, topics to avoid, and items to surface only when the user
  asks (e.g. a project that must not be mentioned proactively).
- `projects[]` — durable per-project facts; `proactive=false` means "do not bring this up
  unless the user does."
- `anchors[]` — decision anchor-ids most relevant to the user globally (links into §2).

---

## 2. `decisions/<machineId>/<decision-id>.md` — canonical decision format

**Purpose.** A durable, recallable record of a non-trivial decision, retrievable across
projects (A3) by fixed-path direct read over the **union of all shards**.

**Sharding & merge.**
- Path: `decisions/<machineId>/<decision-id>.md`. Each writer owns its own shard directory,
  so two writers can never edit the same file — directory separation means no merge conflict.
- A **new** cloud decision is appended to `decisions/github/` (PC-off canonical advance).
- **Editing an existing mode-A decision** goes through `_pending/` + mode-A reconcile (hop1);
  see `memory-promotion.md`.
- Readers (recall skill / dashboard) `union` all `decisions/*/` directories.

**`<decision-id>` convention.** `YYYYMMDD-<slug>` (date + short kebab slug), unique within a
shard. The anchor-id used for recall is `decision:<machineId>/<decision-id>`.

**File format (Markdown with YAML front-matter).** Encoding UTF-8 (no BOM), LF.

```markdown
---
id: 20260101-example-slug
anchor: decision:<machineId>/20260101-example-slug
writer: <machineId>
created_at: 2026-01-01T00:00:00Z
status: active            # active | superseded | revised
supersedes: null          # anchor-id this replaces, or null
projects: ["<projectId>"] # scope; [] or ["*"] for global
tags: ["<tag_a>", "<tag_b>"]
---

# <Decision title — short, imperative>

## Context
<What situation/problem prompted this decision. 1-3 sentences. No PII.>

## Decision
<The decision itself, stated unambiguously. What we will do from now on.>

## Rationale
<Why this over alternatives. Key trade-offs. Evidence/links if any.>

## Consequences
<Follow-on effects, what it constrains or enables, any revisit trigger.>
```

**Required sections** (consumers depend on them): the YAML keys `id`, `anchor`, `writer`,
`created_at`, `status`; and the headings **Context**, **Decision**, **Rationale**. The
`anchor` value is what `recall_hit` matches against (see §3 and `recall-budget.md`).
`supersedes` lets a later decision retire an earlier anchor without deleting history.

---

## 3. `events/<machineId>.jsonl` — metrics event schema

**Purpose.** Append-only, machine-sharded instrumentation backbone. `metrics.md` is a
**mode-A derive** over the read-time **union** of all shards (the cloud shard is written by
mode-B but mode-A never touches another machine's shard). One JSON object per line.

**Conventions.**
- Encoding UTF-8 (no BOM), LF. One compact JSON object per line, append-only.
- Written **only via the resolver-resolved path** for the current `machine_id`; never write
  another shard. `.gitattributes` sets `events/*.jsonl merge=union` so concurrent appends
  from two sessions on the same machine are line-preserved (read-time dedup).
- All keys ASCII. `null` is allowed where a field is not applicable.

**Schema (one line = one event).** Fields mirror plan v9 §2 exactly.

```json
{
  "ts": "2026-01-01T00:00:00Z",
  "session_id": "<session_id>",
  "cwd_repo": "<repo_path_or_id>",
  "omc_state_dir": "<resolved_OMC_STATE_DIR>",
  "machine_id": "<machineId>",
  "resolver_mode": "local-env",
  "runner_verified": true,

  "type": "task",
  "skill_id": null,
  "skill_reused": false,

  "rework": false,
  "rework_anchor": null,

  "recall_query": null,
  "recall_hit": false,
  "recall_anchor": null,
  "recall_source": "decisions",

  "reask_count": 0,
  "anchor_reinject_count": 0,

  "label_n": 0,
  "gate_suspended": true,
  "degraded_to_proxy": false,

  "decision_writer": null,
  "pending_age_days": null,

  "outcome": null,
  "duration_ms": null,
  "token_cost": null,
  "user_rating": null,

  "counts": { "skills": 0, "wiki": 0, "profile_keys": 0, "digest_files": 0 },

  "backup": {
    "result": "success",
    "sha": null,
    "ahead_count": 0,
    "last_snapshot_ts": null,
    "actions_minutes_left": null,
    "actions_budget_used": null,
    "ratelimit_headroom": null,
    "token_days_left": null,
    "reason": null
  }
}
```

**Field semantics & enums.**

| Field | Type | Meaning / allowed values |
|---|---|---|
| `ts` | ISO8601 string | event timestamp (UTC). |
| `session_id` | string | Claude Code session id. |
| `cwd_repo` | string | repo/worktree the event occurred in. |
| `omc_state_dir` | string | resolved `OMC_STATE_DIR` (path divergence audit). |
| `machine_id` | string | shard owner; equals the filename stem. |
| `resolver_mode` | enum | `local-env` \| `cloud-repo`. |
| `runner_verified` | bool | mode-B positive runner-id verification passed (0-B). |
| `type` | enum | `task` \| `recall` \| `skill_invoke` \| `promote` \| `sync` \| `snapshot` \| `actions_run` \| `decision_append`. |
| `skill_id` | string\|null | skill involved, if any. |
| `skill_reused` | bool | an existing skill was reused (vs. created). |
| `rework` | bool | rework detected (target: file+symbol diff heuristic; A11). **v1 hooks fill a file-level cross-session proxy only** — see `recall-budget.md` §4 implementation status. |
| `rework_anchor` | string\|null | anchor-id the rework relates to. v1 uses `file:<path>` to mark file-level scope. |
| `recall_query` | string\|null | the recall query, if `type=recall`. |
| `recall_hit` | bool | a prior anchor-id was correctly recalled/linked. |
| `recall_anchor` | string\|null | anchor-id that was hit. |
| `recall_source` | enum | `profile` \| `decisions` \| `wiki` \| `session_search`. |
| `reask_count` | int | times the user had to re-explain the same preference (A1/A2 proxy). |
| `anchor_reinject_count` | int | times the same anchor-id was re-injected (cold-start proxy). |
| `label_n` | int | size of the hand-labeled validation set so far (gate is suspended until ≥30). |
| `gate_suspended` | bool | precision/recall hard-gate suspended (cold-start; see `recall-budget.md`). |
| `degraded_to_proxy` | bool | A2 measured by cold-start proxy only (not the real success condition). |
| `decision_writer` | string\|null | shard writer for a `decision_append` event (0-C sharding). |
| `pending_age_days` | int\|null | age of the oldest `_pending/` item (drives `reconcile-stale`; 0-G3). |
| `outcome` | enum\|null | (T4 데이터화 확장·선택) `success` \| `fail` \| `partial` — 작업 산출물 결과. |
| `duration_ms` | int\|null | (선택) 작업/세션 소요 시간(ms). |
| `token_cost` | int\|null | (선택) 토큰 비용(알 때). |
| `user_rating` | int\|null | (선택) 1–5 사용자 품질 평가(`claude-rate`). 목적함수 입력(objective-function.md). |
| `counts.skills` | int | count of durable skills. |
| `counts.wiki` | int | count of wiki nodes. |
| `counts.profile_keys` | int | count of profile keys. |
| `counts.digest_files` | int | count of `cloud-digest/` files (pruning health). |
| `backup.result` | enum | see enum table below. |
| `backup.sha` | string\|null | commit SHA pushed, if any. |
| `backup.ahead_count` | int | local commits ahead of remote (stalled detection). |
| `backup.last_snapshot_ts` | ISO8601\|null | last warm snapshot-export time. |
| `backup.actions_minutes_left` | int\|null | GitHub Actions minutes remaining this month. |
| `backup.actions_budget_used` | int\|null | Actions minutes used vs. the self-skip threshold. |
| `backup.ratelimit_headroom` | string\|null | subscription rate-limit headroom indicator. |
| `backup.token_days_left` | int\|null | days until the OAuth secret expires. |
| `backup.reason` | string\|null | free-text reason/detail for the result. |

**`backup.result` enum** (single source for sync/health states):
`success` \| `skip` \| `fail` \| `blocked` \| `stale` \| `diverged` \| `stalled` \|
`rclone-fail` \| `token-expiring` \| `actions-quota` \| `actions-budget-skip` \|
`reconcile-stale` \| `mode-mismatch`.

- `success` is only emitted when a push actually reached the remote (no empty/stale/diverged
  "success" — A5 honesty rule).
- `blocked` = a git-native leak/ownership guard aborted the commit/push (A9).
- `mode-mismatch` = mode-B positive runner-id verification failed (main PC entered mode-B on
  stale env) — guarded path refused (0-B).
- `actions-budget-skip` = workflow self-skipped because the monthly Actions-minute budget
  pre-check exceeded threshold (no-charge fail-stop; 0-G).
- `reconcile-stale` = a `_pending/` item has gone unreconciled past the threshold (0-G3).

---

## 4. Cross-references

- **Promotion / ownership rituals** (hop1 `_pending→PRIVATE` auto, hop2 `PRIVATE→PUBLIC`
  via `/promote` full-scan ∧ human review): see `claude/protocols/memory-promotion.md`.
- **Recall budget, rework/recall_hit heuristics, precision/recall ≥ 0.8 (N≥30) provisional
  threshold, cold-start suspension, M-A2 milestone gate, labeling procedure**: see
  `claude/protocols/recall-budget.md`.
- **Path resolution**: `claude/lib/memdir.{ps1,sh}` (resolver; deploy-only to `~/.claude/lib/`).
- **A1 deterministic injection**: SessionStart hook `claude/hooks/memory-inject.{ps1,sh}`
  reads `profile/user-profile.json` via the resolver and emits it as `additionalContext`
  (model-independent; fail-open).
