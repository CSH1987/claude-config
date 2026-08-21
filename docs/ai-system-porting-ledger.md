---
schema_version: 1
checked_at: 2026-08-21T12:09:14+09:00
source_baseline_before_change: 756255f793d1d5dcaa2cfd0b2cfde4ad181d04b6
status: active
---

# Claude → Codex·Hermes 기능 이식 대장

## 목적과 정본 관계

Claude Code에 있는 기능을 이름이나 설정 파일 그대로 복사하지 않고, 기능 계약을 Codex·Hermes의 공식 방식으로 다시 구현했는지 추적한다. 지속 원칙의 정본은 Vault `10_컨텍스트/업무_원칙_방법론.md` §4-14이고, 이 문서는 버전·구현·테스트·남은 차이처럼 바뀌는 운영 증거의 정본이다.

모든 원본 패턴은 대장에 남긴다. 실제 적용은 관련성·공식 지원·로컬 호환성·보안·테스트·복구 조건을 통과한 항목만 한다. 보류하거나 기각한 패턴도 이유와 재검토 조건을 지우지 않는다.

## 항상 최신 상태를 유지하는 규칙

1. 이식 평가를 시작할 때와 적용 직전에 원본·대상 시스템의 공식 문서와 공식 저장소를 다시 확인한다.
2. `checked_at`, 공식 최신 버전 또는 commit, 로컬 버전, 근거 URL을 함께 기록한다. 하나라도 없으면 `unverified`다.
3. 새 release·폐기 공지·보안 경고·로컬 버전 변경이 생기면 관련 행을 즉시 `stale`로 바꾸고 재평가한다.
4. 실행 코드·시크릿 접근 후보의 증거는 7일, 일반 참고 자료는 30일이 지나면 `stale`로 본다. 설치 직전에는 기간과 관계없이 다시 확인한다.
5. 최신판이나 인기 도구라는 이유만으로 자동 설치하지 않는다. 호환·격리·회귀·복구 시험을 통과하고 필요한 승인을 받은 뒤 적용한다.

생활 속 예로, 휴대폰에 새 운영체제가 나왔는지는 계속 확인하지만 업무 앱이 정상 작동하는지 확인하기 전에는 바로 업데이트하지 않는 방식이다.

## 상태 정의

### 최신성

- `current`: 공식 최신 상태와 로컬 상태를 현재 증거로 확인함
- `update_available`: 공식 최신판보다 로컬이 뒤에 있지만 현재 구현은 검증된 로컬 버전에서 작동함
- `stale`: 새 release·폐기·보안 경고·증거 만료로 재확인이 필요함
- `unverified`: 공식 또는 로컬 버전 증거가 빠짐

### 구현

- `verified`: 격리 또는 실제 환경 시험을 통과함
- `implemented_unverified`: 구현됐지만 필요한 실제 시험이나 신뢰 승인이 남음
- `partial`: 기능 계약의 일부만 충족함
- `planned`: 설계만 있고 구현 전
- `policy_only`: 실행 코드 없이 공통 지침으로만 적용됨
- `rejected_pattern`: 원본 패턴을 검토했지만 오작동 위험 때문에 복제하지 않음
- `not_applicable`: 대상 시스템에 필요하지 않으며 이유가 기록됨
- `retired`: 과거에는 사용했지만 공식 폐기·대체 또는 운영 결정으로 종료됨

`verified`와 최신성 `current`를 함께 충족해야 “현재 완료”로 표시한다. 로컬이 공식 최신보다 뒤에 있으면 기능 구현이 통과했어도 버전 최신성은 별도로 `update_available`로 남긴다.

`source_baseline_before_change`는 이 대장을 만들기 전 출발 커밋이다. 이 문서와 새 회귀 테스트가 포함된 재현 가능한 결과는 이 변경을 커밋한 Git 이력으로 확인한다.

## 런타임 최신 버전 스냅샷

확인 시각: `2026-08-21T12:09:14+09:00`

| 런타임 | 공식 최신 | 로컬 | 최신성 | 공식 근거 | 활성·인기도 보조 신호 |
|---|---|---|---|---|---|
| Claude Code | `v2.1.238` | `2.1.238` | `current` | [release](https://github.com/anthropics/claude-code/releases/tag/v2.1.238) | 2026-08-20 release/push, stars 142,166, forks 22,801 |
| Codex CLI | `0.149.0` | `0.148.0` | `update_available` | [release](https://github.com/openai/codex/releases/tag/rust-v0.149.0) | 2026-08-20 release, 2026-08-21 push, stars 108,142, forks 16,486 |
| Hermes Agent | `v0.20.4` | `0.20.4` / `76952ba5` | `current` | [release](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.8.18) | 2026-08-18 release, 2026-08-21 push, stars 233,584, forks 46,815 |

stars·forks는 관심과 채택의 보조 신호다. 공식 기능 지원·유지보수·보안·내 환경 호환성을 대신하지 않는다.

## 원본 Claude 기능 인벤토리

여기서 “전체 목록”은 이번 이식 범위인 컨텍스트·확장·자동화·복구 기능군과 바로 인접한 공식 기능을 뜻한다. UI 테마처럼 기능 계약과 무관한 제품 기능까지 억지로 이식 대상으로 만들지는 않지만, 범위 밖 항목도 이유를 남긴다.

| 원본 기능군 | 공식 표면 | 이식 대장 연결 | 누락 판정 |
|---|---|---|---|
| 지속 지침·경로 규칙 | `CLAUDE.md`, rules | `PORT-001` | 포함 |
| 자동 기억 | auto memory | `PORT-006` | 포함 |
| 세션·재개·내보내기 | sessions, resume/export | `PORT-010`, `PORT-012` | 포함 |
| 컨텍스트·압축 | context window, compact | `PORT-002`, `PORT-005` | 포함 |
| 수명주기 자동화 | hooks | `PORT-004`, `PORT-010` | 포함 |
| 재사용 절차 | skills, custom commands | `PORT-003` | 포함 |
| 격리 작업자 | subagents, background, worktree | `PORT-008` | 포함 |
| 외부 도구·데이터 | MCP, tool search | `PORT-007` | 포함 |
| 설치 가능한 묶음 | plugins | `PORT-011` | 포함 |
| 설정·권한·신뢰 | settings, permissions, hook trust | `PORT-004`, `PORT-012` | 포함 |
| 비대화형 실행 | headless/noninteractive | `PORT-009`, `PORT-012` | 포함 |
| IDE·화면 편의 기능 | IDE integration, UI commands | 없음 | 현재 기능 계약 밖. 필요가 생기면 새 ID로 추가 |

공식 목록과 제약은 [Claude Code 기능 개요](https://code.claude.com/docs/en/features-overview) 및 아래 공식 기능 근거에서 재확인한다.

## 기능별 상태

각 행의 `확인·시험`은 `evidence_checked_at / tested_at / tested_local_version / 근거` 순서다.

| ID | 기능 계약 | Codex 착지점·상태 | Hermes 착지점·상태 | 확인·시험 | 위험·복구·재검토 |
|---|---|---|---|---|---|
| `PORT-001` | 공통 규칙을 항상 읽는다 | `AGENTS.md` 동기화 · `verified` | 실효 cwd와 `~/.hermes/AGENTS.md` 동기화 · `implemented_unverified` | `2026-08-21 / 2026-08-21 / Codex 0.148.0, Hermes 파일 fixture / test/codex-integration.sh, test/online-bootstrap.sh` | 마커 드리프트 시 관리 블록 재생성. Hermes 실제 모델 로드와 portable rule 또는 런타임 로딩 규칙 변경 때 재검증 |
| `PORT-002` | Vault 전체를 누락 없이 파악하고 관련 원문만 읽는다 | 전체 카탈로그 + SessionStart 지도 + 파일/MCP 검색 · `partial` | 전체 지도 + 파일시스템 검색 지침 · `partial` | `2026-08-21 / 2026-08-21 / Codex 0.148.0, Hermes 미실행 / test/vault-catalog.sh, MCP initialize HTTP 200` | 지도·연결만 검증됨. 질문→검색→원문 사용 E2E 필요. 캐시 삭제 후 재생성 가능. Vault 지문·검색 방식 변경 때 재검증 |
| `PORT-003` | 긴 절차는 필요할 때만 읽는다 | `SKILL.md` · `verified` | 동기화된 `SKILL.md` · `implemented_unverified` | `2026-08-21 / 2026-08-21 / Codex 0.148.0 실제 사용, Hermes 파일 해시만 / workload-optimization` | Hermes 실제 skill 호출 필요. 스킬 스키마·검색 예산 변경 때 재검증. 제거하면 기본 지침으로 복귀 |
| `PORT-004` | 세션 시작·종료에 결정적 작업을 실행한다 | `SessionStart`·`SessionEnd` command hook · `partial` | 공통 규칙 로드와 로그 수집 경로 · `partial` | `2026-08-21 / 2026-08-21 / Codex 0.148.0 / 사용자 화면에서 두 훅 Active 확인, 실제 SessionEnd 로그 생성, test/codex-integration.sh` | 활성화와 종료 로그는 확인됨. SessionStart가 새 세션에 주입한 지도의 내용 품질은 별도 E2E 필요. 훅 비활성화로 복구. hook schema 변경 때 재검증 |
| `PORT-005` | 압축 전 중요 상태를 보존하고 압축 뒤 정본을 복원한다 | `compact_prompt` + `SessionStart(source=compact)` · `partial` | Vault 정본·로컬 memory 정책 · `policy_only` | `2026-08-21 / 2026-08-21 / Codex 0.148.0 설정 fixture, Hermes 미실행 / config merge test` | 실제 장기 세션 압축 전후 E2E 없음. 기본 압축 설정으로 복구. 압축 사고·런타임 변경 때 재검증 |
| `PORT-006` | 로컬 기억은 캐시, Vault는 공통 정본으로 사용한다 | Codex memories + Vault · `partial` | Hermes memory + Vault · `policy_only` | `2026-08-21 / 2026-08-21 / Codex 0.148.0 설정 fixture, Hermes 미실행 / 설정 병합은 검증, 회상 품질은 미측정 / test/codex-integration.sh` | 낡은 회상 위험. memory 기능을 꺼도 Vault 정본 유지. 오회상·schema 변경 때 재검증 |
| `PORT-007` | 외부 데이터·행동은 표준 도구로 연결한다 | 파일 검색 우선, Obsidian 필요 기능만 MCP · `partial` | 파일시스템 우선, 현재 MCP 0개 · `partial` | `2026-08-21 / 2026-08-21 / Codex 0.148.0 MCP initialize, Hermes 0.20.4 config 확인 / 연결·비밀 비노출만 검증, 실제 도구 E2E는 미실행 / local MCP secrecy test` | 실제 도구 E2E와 Hermes 외부 연결은 범위 제한. MCP 제거 후 파일 검색으로 복구. API·인증 변경 때 재검증 |
| `PORT-008` | 계획·검증·구현·대량 탐색을 분리한다 | native subagents + `workload-optimization` · `partial` | skill + routing self-review · `partial` | `2026-08-21 / 미실행 / Codex 0.148.0, Hermes 0.20.4 / 정책·파일 검토` | 실제 역할별 표본 측정 전. 단일 상위 역할로 복귀. 모델 세대·반려율 기준 변경 때 재검증 |
| `PORT-009` | Claude·Hermes·Codex 대화와 Vault 변경분을 증분 학습한다 | 루트 사용자 발화 수집 · `verified` | export 수집 경로 · `verified` | `2026-08-21 / 2026-08-21 / Claude Code 2.1.238, Codex 0.148.0, Hermes 0.20.4 / 실제 launchd 실행: 대화 201건(127+37+37), Vault 63문서, 3개 렌즈 성공, v2 커서 커밋, 17분 45초, Claude CLI 추정 비용 $12.98. 후속 실제 gather: 8건(0+7+1), 세 소스 ok, 최장 2,419자. test/codex-user-prompt-collector.sh, test/learning-pipeline-sources.sh, test/learning-pipeline-run.sh, test/learning-pipeline-output-validation.sh` | 첫 실행은 Claude headless의 10분 백그라운드 대기 상한으로 중단됐으나 커서는 보존됨. `bb82f1c`·`6b7690c`에서 유한 1시간 상한·단일실행 락·구조화 완료 검증·셸 소유 커밋을 적용한 뒤 성공. 후속 감사에서 생성 본문 되먹임·식별정보 복제·Codex Desktop의 과거 세션 일괄 가져오기·자동 compaction 연속 요약을 발견했다. 생성 문서와 별도 원문으로 읽는 캐노니컬 3문서의 본문은 입력에서 제외하고, 세션 별칭·정확한 합성 입력 필터·legacy import 경계·compaction 고정문 필터·소스별 실패 상태를 적용했다. 세 소스의 대상 행과 Vault 순회를 전수 검사하고, UTC 시각을 고정 정밀도로 비교하며 최근 24시간 처리 ID를 커서에 보존해 다른 세션 파일에 조금 늦게 기록된 발화도 재수집한다. 출력은 구조화 플래그로 만든 실행별 정확한 경로만 허용하고, 커서 전진 전후 전체 Vault 상태·경계 ID·삭제·파일명/본문 식별정보·빈/스킵 렌즈·필수 감사 산출물을 fail-closed로 검증한다. 검증 중 종료되면 2단계 marker로 안전한 미쓰기·부분 커밋만 자동 복구하고 그 밖의 변경은 격리한다. 비용은 CLI의 클라이언트 측 추정치이며 실제 청구액으로 간주하지 않는다. launchd 중지·커서 복원으로 rollback. export schema·CLI 제한 변경 또는 다음 예약 실행 때 재검증 |
| `PORT-010` | 세션 종료 후 재개 단서를 남긴다 | `SessionEnd` → 공용 logger · `verified` | 주간 수집 및 Vault 기록 · `partial` | `2026-08-21 / 2026-08-21 / Codex 0.148.0, Hermes 0.20.4 / 실제 Codex SessionEnd 로그 생성·Vault 원격 백업, test/vault-session-log.sh` | 로그에는 계정명·프로젝트명·절대경로·전체 세션 ID를 저장하지 않는다. 작업 위치는 범주, 종료 사유는 허용 목록, 파일명은 비식별 nonce만 사용하고 로컬 전용 해시 상태로 같은 세션 중복을 막는다. 헤드리스 학습 실행은 자체 SessionEnd 로그를 끈다. 훅 해제 가능. hook schema·로그 포맷 변경 때 재검증 |
| `PORT-011` | 여러 기능을 설치 가능한 묶음으로 배포한다 | 개인 구조는 repo+installer, plugin은 필요 시만 · `not_applicable` | repo+sync, bundle/plugin은 필요 시만 · `not_applicable` | `2026-08-21 / 2026-08-21 / N/A(런타임 비의존 bootstrap fixture), 소스는 이 대장 도입 commit / test/online-bootstrap.sh` | 현재 개인 배포 계약에는 plugin이 불필요함. 모바일·팀 배포 요구가 생기면 재평가 |
| `PORT-012` | 새 PC에서 비밀 없이 복구·동기화한다 | online bootstrap · `verified` | online bootstrap · `verified` | `2026-08-21 / 2026-08-21 / N/A(런타임 비의존 격리 fixture), 소스는 이 대장 도입 commit / test/online-bootstrap.sh, fresh cursor regression` | 실제 GUI 로그인·provider 차이. 기존 설정 백업 복원. 설치기·인증 방식 변경 때 재검증 |
| `PORT-013` | 후보의 유명함·활성·안전·적합성을 분리 평가한다 | 공통 평가 규격 · `planned` | 공통 평가 규격 · `planned` | `2026-08-21 / 미실행 / N/A / docs/software-candidate-evaluation-standard.md` | 기존 `skill-watch`는 star·최근 push 중심이라 최종 판정에 사용 금지. 평가기 도입 때 재검증 |
| `PORT-014` | 공식 최신 상태를 지속 확인하고 검증된 버전만 적용한다 | 버전 스냅샷·재검토 규칙 · `partial` | `hermes --version` upstream 확인 + 공통 규칙 · `partial` | `2026-08-21 / 2026-08-21 / Codex 0.148.0, Hermes 0.20.4 / 공식 release와 로컬 CLI 대조` | 자동 검사·알림은 아직 전 시스템 공통 구현 전. 직전 검증 버전 유지. 새 release·폐기·보안 경고 때 재검증 |
| `PORT-015` | 긴 테스트 출력은 원문을 보존하고 요약한다 | Claude 강제 필터 복제 안 함 · `rejected_pattern` | 동일 · `rejected_pattern` | `2026-08-21 / N/A / N/A / 원본 구현 위험 검토` | 실패 근거를 숨길 위험. 대안은 원문 파일 + 짧은 요약. 공식 구조화 출력이 생기면 재검토 |
| `PORT-016` | 재작업을 신뢰 가능한 단위로 측정한다 | Claude 파일 단위 휴리스틱 복제 안 함 · `rejected_pattern` | 동일 · `rejected_pattern` | `2026-08-21 / N/A / N/A / 대상 native telemetry 검토` | 오탐이 잘못된 모델 라우팅을 만들 수 있음. 공식 telemetry 등장 때 재검토 |

## 공식 기능 근거

- Claude Code: [기능 개요](https://code.claude.com/docs/en/features-overview), [Hooks](https://code.claude.com/docs/en/hooks), [Subagents](https://code.claude.com/docs/en/sub-agents), [Memory](https://code.claude.com/docs/en/memory)
- Codex: [Hooks](https://learn.chatgpt.com/docs/hooks), [Skills](https://learn.chatgpt.com/docs/build-skills), [MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Memories](https://learn.chatgpt.com/docs/customization/memories), [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md), [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- Hermes: [Plugins](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/plugins.md), [다른 에이전트에서 가져오기](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/import-from-other-agents.md)

## 재검증 대기열

1. 신뢰된 Codex SessionStart가 새 세션에 주입한 Vault 지도의 내용 품질을 실제 질문→원문 조회로 확인
2. 다음 일요일 04:00 예약 실행에서 무인 재실행·증분량·비용 추세 확인
3. Codex `0.149.0` 적용 여부를 결정하기 전 현재 통합 테스트를 동일 입력으로 재실행
4. Hermes `0.20.4`에서 과거 `0.18.2` 기준 AGENTS cwd 로딩 설명 재검증
5. Codex·Hermes 단독 시작 시 `claude-config` 원격 최신화 보장 방식 평가
6. 공통 후보 평가기를 만든 뒤 기존 `skill-watch`의 고정 star 기준 교체

## 갱신 규칙

- 구현·버전·테스트 상태가 바뀐 같은 변경에서 이 문서도 함께 고친다.
- 완료 행을 지우지 않는다. 기능이 폐기되면 `retired` 또는 `rejected_pattern`으로 바꾸고 이유를 남긴다.
- 원시 API 응답·시크릿·사용자 데이터는 넣지 않는다. 날짜·버전·공식 URL·판정만 기록한다.
