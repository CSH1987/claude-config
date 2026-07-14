# 기획안: 대형 코드 작업 도구 라우팅 넛지 훅

**작성**: Ralph 모드(2026-07-14 새벽, 무인 실행) · **상태**: 구현·테스트 완료, **라이브 활성화만 승인 대기**

## 지금 당장 결정할 것 (여기만 읽어도 됨)

이 훅을 켤지 말지 하나만 결정하시면 됩니다. 켜기로 하면 `docs/proposals/edit-nudge-activation.md`의 4곳 diff를 반영 + 배포하면 끝입니다. 안 켜도 지금 상태(파일만 존재, 미실행)로 아무 문제 없습니다.

---

## 1. 문제
2026-07-13~14 세션 감사에서, **89~132회 액션(Bash/Edit/Write)짜리 대형 코드 작업**(근본원인 디버깅·신규 기능 빌드)일수록 오히려 Skill/Agent/MCP 확장도구 사용률이 **0%**로 떨어지는 역설을 발견. CLAUDE.md에 "규모가 클수록 code-review/전문 에이전트 경유" 프롬프트 지침을 추가했지만, 프롬프트 지침 자체가 큰 작업 도중 컨텍스트에 묻혀 잊힐 위험이 원래 문제와 동일하게 남음.

## 2. 발견한 제약
hookify의 `.local.md` 규칙 형식은 **세션에 걸친 카운터/상태를 지원하지 않는다**(순수 per-event 패턴매칭). 즉 "최근 Skill/Agent 호출 이후 Edit N회 누적" 같은 조건은 hookify로 직접 구현 불가 — 커스텀 훅이 필요함(자세한 옵션 비교는 `edit-nudge-hook-design.md` 참고, 최종 선택: 커스텀 PostToolUse 상태훅).

## 3. 구현
- `claude/hooks/edit-nudge.sh` / `.ps1` — PostToolUse 훅. Edit/Write가 임계치(기본 6회) 누적되면 1회만 리마인더(`additionalContext`)를 주입, Skill/Agent/Task/mcp__* 호출 시 카운트 리셋. 세션ID별 상태 파일(`$OMC_STATE_DIR/edit-nudge/<session>.json`)로 격리.
- `claude/hooks/test-edit-nudge.sh` — 격리 테스트 하네스(임시 OMC_STATE_DIR 사용, 실제 라이브 상태 안 건드림).

### ⚠️ 구현 중 발견한 중요 버그 (수정 완료)
최초 구현이 `printf ... | python3 - <<'PY'`(파이프+heredoc을 동시에 stdin에 씀) 패턴을 썼는데, 이게 **stdin 충돌로 완전히 동작 안 함**을 테스트로 발견했습니다 — python이 파이프 데이터와 heredoc 본문을 이어붙여 소스코드로 읽으려다 실패하고, 상위 fail-open 설계가 이 실패를 조용히 삼켜버려서 "에러도 없이 그냥 아무 일도 안 일어나는" 상태가 됩니다. 임시파일로 python 소스를 먼저 떠내고 payload는 별도 stdin으로 분리하는 방식으로 수정 후 재검증했습니다.

**파급 발견(이번 작업 범위 밖, 보고만)**: 기존에 이미 배포돼 있던 `claude/hooks/edit-track.sh`가 **완전히 동일한 버그**를 갖고 있어서, 실측 테스트 결과 **정상 payload를 줘도 아무 파일도 안 씀**을 확인했습니다. `edit-track.sh`가 쌓아야 할 데이터를 `stop-metrics.sh`(rework 감지 기능)가 소비하는 구조라, 이 기능이 배포 이후 계속 무동작이었을 가능성이 높습니다. **별도 확인·수정이 필요합니다** — 지금은 손대지 않았습니다.

## 4. 테스트 증거
`sh claude/hooks/test-edit-nudge.sh` 실행 결과: **PASS=13 FAIL=0**
- 5회 Edit(미도달) → 무발화
- 8회 Edit(미경유) → 6번째에서 정확히 1회만 발화, 7·8번째 재발화 없음(스팸 금지 확인)
- Skill 호출로 리셋 → 리셋 후 6번째에서만 재발화
- 세션 경계 → 새 세션이 이전 세션 카운트 상속 안 함
- Read/Grep/Bash 3회 호출 후에도 카운트 불변(조사성 도구 비카운트 확인)
- FAIL-OPEN 3종(손상된 JSON·빈 payload·python3 미탐지 가능 환경) 전부 exit 0 확인
- Agent/mcp__* 리셋 경로도 수동 확인 완료(아키텍트 검증 시 추가 재현)

(아키텍트 리뷰 단계에서 architect 에이전트가 독립적으로 재실행해 PASS=9 FAIL=0 재현 확인 → deslop 패스에서 테스트 스위트를 리팩터링(중복 루프 헬퍼화) + 아키텍트가 수동으로만 검증했던 FAIL-OPEN·비카운트 케이스를 영구 회귀테스트로 추가해 PASS=13으로 보강.)

## 5. 활성화 절차
`docs/proposals/edit-nudge-activation.md` 참고 — settings.json·install.sh·install.ps1 4곳의 정확한 diff, 그리고 롤백/즉시끄기(`EDIT_NUDGE_OFF=1`) 방법 포함.

## 6. 지금 상태 (변경 안 됨 확인됨)
`git status` 확인 결과 `settings.json`/`install.sh`/`install.ps1`은 **전혀 수정 안 됨** — 이 훅은 지금 어떤 세션에서도 실행되지 않습니다. 아래 파일들만 새로 생겼습니다:
```
claude/hooks/edit-nudge.sh
claude/hooks/edit-nudge.ps1
claude/hooks/test-edit-nudge.sh
docs/proposals/edit-nudge-hook-design.md
docs/proposals/edit-nudge-activation.md
docs/proposals/edit-nudge-README.md (이 문서)
```
(참고: `claude/CLAUDE.md`는 어제 대화 중 별도로 수정된 상태로, 이 세션의 커밋 여부 확인 질문이 아직 답변 대기 중이었습니다 — 함께 검토해주세요.)

## 7. 남은 액션 아이템
1. **[결정 필요]** 이 훅을 활성화할지 — 활성화하면 `edit-nudge-activation.md`의 4곳 반영 + 배포
2. **[별도 확인 권장]** `edit-track.sh`/`stop-metrics.sh`의 동일 버그 — rework 감지 기능이 계속 무동작이었을 가능성, 확인 후 같은 방식(임시파일 분리)으로 수정 필요
3. **[커밋 여부]** `claude/CLAUDE.md`의 어제 정책 변경 2건(대형작업 도구경유 강화, 투명성 노트) + 오늘 밤 이 훅 관련 파일들을 함께 커밋·푸시할지
