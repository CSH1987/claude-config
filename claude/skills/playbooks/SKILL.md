---
name: playbooks
description: >
  Discover, apply, and grow the work-type playbooks (requirements, research, decision,
  review) — the sanitized, generic "how I work" catalog. Use when starting a common work
  type, when the user says "플레이북대로 / use the playbook", or when a fresh install / new
  domain needs a cold-start starting point. Points to claude-config/claude/playbooks/ (PUBLIC).
---

# playbooks — 작업유형 카탈로그 발견 · 적용 · 증식

PUBLIC, 일반화된 "일하는 법". 개인 노하우(`claude-memory`, PRIVATE)는 전달되지 않지만 *방법*은
여기서 누구에게나 전달된다(기둥2). 새 사용자/새 분야의 콜드스타트 시드이기도 하다.

## When to use
- 공통 작업유형(요구사항 확정 · 리서치 · 의사결정 · 검토)을 시작할 때.
- 사용자가 "플레이북대로", "리서치 플레이북 적용" 등으로 언급.
- 축적이 0인 콜드스타트에서 "어떻게 일하나"의 출발점이 필요할 때.

## How to find them
- 위치: claude-config 레포의 `claude/playbooks/`. 레포 경로는 `~/.claude/.config-sync-path`에 기록됨.
  - POSIX: `repo="$(cat ~/.claude/.config-sync-path)"; ls "$repo/claude/playbooks/"`
  - PowerShell: `$repo = (Get-Content "$env:USERPROFILE\.claude\.config-sync-path" -Raw).Trim(); ls "$repo\claude\playbooks"`
- 색인: `claude/playbooks/README.md`.

## How to apply
1. 작업유형을 식별하고 해당 플레이북을 읽는다.
2. 그 플레이북의 **방법(steps)** 을 따르고 **품질 바**를 완료 기준으로 삼는다.
3. 결정이 나오면 Claude Code 네이티브 auto-memory(`~/.claude/projects/<project>/memory/`)에
   type: project/decision 메모리로 기록한다.

## How to grow (증식 — PII 절대 금지)
- 반복되는 *잘 통하는 방법* 발견 → `/retro`가 PII-safe 초안을
  `$CLAUDE_MEMORY_DIR/playbook-drafts/`에 스테이징.
- 사람이 검토해 일반적이고 PII가 없으면 → `/promote`로 이 PUBLIC playbooks 카탈로그에 반영.
- **절대 규칙**: 개인정보·실명·고객/사건/환자 정보는 PUBLIC 금지. *일반화한 방법*만 올린다.

## Cross-references
- 카탈로그 색인: `claude/playbooks/README.md`
- 증식(발견 → 초안 → 승격): `claude/skills/retro/SKILL.md`, `claude/skills/promote/SKILL.md`
