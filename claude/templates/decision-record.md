<!--
  PUBLIC TEMPLATE. 복사해서 PRIVATE `$CLAUDE_MEMORY_DIR/decisions/<machineId>/<id>.md` 로 저장한다.
  이 템플릿 자체는 placeholder만(PII 금지). 실제 값은 PRIVATE 저장소에만 채운다.
  형식 정본: claude/memory/SCHEMA.md §2.  사용 가이드: claude/playbooks/decision.md.
-->
---
id: <YYYYMMDD-short-slug>
anchor: decision:<machineId>/<YYYYMMDD-short-slug>
writer: <machineId>
created_at: <YYYY-MM-DDThh:mm:ssZ>
status: active            # active | superseded | revised
supersedes: null          # 이 결정이 대체하는 anchor-id, 없으면 null
projects: ["<projectId>"] # 범위. 전역이면 [] 또는 ["*"]
tags: ["<tag_a>", "<tag_b>"]
---

# <결정 제목 — 짧고 명령형, 예: "로그는 JSON 한 줄로 출력한다">

## Context
<이 결정을 부른 상황/문제. 1~3문장. PII 없이.>

## Decision
<무엇을 할지 모호함 없이. "앞으로 X 한다.">

## Rationale
<왜 이 선택인가. 검토한 대안과 핵심 트레이드오프. 증거/링크(있으면).>

## Consequences
<무엇이 제약되고 무엇이 가능해지나. 재검토 트리거("X가 바뀌면 다시 본다").>
