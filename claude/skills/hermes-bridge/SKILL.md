---
name: hermes-bridge
description: hermes-agent(헤르메스) 연동 오케스트레이터 — 설치 확인, claude-config 규칙 자동 동기화(hermes-sync), 텔레그램 게이트웨이 연결, 옵시디언 볼트 연동, 연동 상태 점검·재실행·업데이트까지 전 과정을 조율. "헤르메스 연동", "hermes 설정", "텔레그램 봇 연결", "규칙 동기화 확인", "헤르메스 다시 동기화", "연동 상태 점검", "옵시디언 연결" 요청 시 반드시 이 스킬을 사용할 것.
---

# hermes-bridge — 헤르메스 연동 오케스트레이션

**실행 모드**: 서브 에이전트 (담당: `hermes-liaison`, model: opus). 단일 전문가 작업이라 팀 오버헤드 불필요.

## Phase 0: 컨텍스트 확인 (초기/후속 판별)

- `~/.hermes`(Windows: `%LOCALAPPDATA%\hermes`) 존재 여부 확인
  - **미존재** → 설치 전 준비 상태 점검 모드 (Phase 1만: 준비물 검증 + 체크리스트 안내)
  - **존재 + 첫 연동** → 전체 실행 (Phase 1→3)
  - **존재 + "다시/점검/업데이트" 요청** → Phase 2~3만 (동기화 재실행 + 검증)

## Phase 1: 준비물 검증

다음이 모두 존재·유효한지 확인한다:
- `~/.claude/exports/portable-rules.md` (규칙 정본 배포본)
- `~/.claude/hooks/hermes-sync.ps1` (Windows) / `.sh` (기타)
- settings.json SessionStart 체인에 hermes-sync 등록 여부
- 누락 시: claude-config 레포에서 재배포(config-sync) 후 재확인

## Phase 2: 동기화 실행

- `hermes-sync` 실행 (자동: 세션 시작 시 / 수동: 직접 실행)
- 멱등성: 재실행해도 AGENTS.md 마커 블록은 1개만 유지되어야 함

## Phase 3: 검증 (증거 기반)

| 항목 | 검증 방법 |
|---|---|
| 규칙 주입 | `~/.hermes/AGENTS.md`에 `claude-config:portable-rules` 마커 블록 정확히 1쌍 존재 |
| 블록 밖 보존 | sync 전후 AGENTS.md의 블록 밖 내용 동일 |
| 스킬 복사 | `~/.hermes/skills/workload-optimization/SKILL.md`가 `~/.claude/skills/...`와 해시 일치 |
| 텔레그램 | `hermes gateway start` 후 봇 응답 (토큰 값은 다루지 않음) |
| 옵시디언 | 볼트 경로가 AGENTS.md의 hermes 영역(블록 밖)에 기재되고 hermes가 읽기 가능 |

## 에러 핸들링

- 1회 재시도 후 재실패 시: 실패 항목을 명시하고 진행 (누락 보고), 수동 개입 지점을 짚어줌
- 마커 블록 중복 발견: hermes-sync 버그 → 스크립트 수정이 우선, AGENTS.md 수동 편집은 금지
- 상세 배경·내일 체크리스트: `~/.claude/exports/HERMES-INTEGRATION.md` 참조

## 테스트 시나리오

1. **정상 흐름**: 가짜 hermes 디렉터리(-HermesDir 오버라이드)에 sync 2회 실행 → AGENTS.md 블록 1쌍 + 스킬 해시 일치 + 기존 내용 보존
2. **에러 흐름**: hermes 미설치 상태에서 sync → 무동작 exit 0 (세션 시작을 방해하지 않음)
