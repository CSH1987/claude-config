---
name: workload-optimization
description: 품질을 깎지 않는 작업량(토큰·비용) 최적화 규칙 — 에이전트 위임 시 모델 티어 선택(OMC 실효 티어 맵), 컨텍스트 절약, effort 하한, 효과 측정. Use when delegating to agents or subagents (OMC modes, Task tool), choosing a model tier, planning long multi-step work, or when the user asks about token/cost optimization (토큰 절약, 비용 최적화, 모델 선택, 작업량 최적화).
---

# Workload Optimization — 품질 무손실 작업량 최적화

**원칙: 품질 상한은 지키고, 절감은 구조에서 얻는다.** 지렛대 우선순위: ① 모델 라우팅(가장 큼) → ② 컨텍스트 절약 → ③ effort 밴드(마지막 수단). 모호하면 항상 한 단계 위 티어를 쓴다.

## 1. 위임 시 모델 티어 선택 (OMC 실효 티어 맵)

전역 별칭 재매핑(`ANTHROPIC_DEFAULT_OPUS_MODEL=claude-fable-5` 등, settings.json)이 적용된 상태의 **실효 모델** 기준:

| 작업 성격 | 별칭 | OMC 에이전트 | 실효 모델 |
|---|---|---|---|
| 계획·아키텍처·리뷰·보안·비평 (판단이 결과를 좌우) | `opus` | planner, architect, critic, analyst, code-reviewer, security-reviewer, code-simplifier | **Fable 5** |
| 구현·디버그·테스트·검증·문서조사 (스펙이 정해진 실행) | `sonnet` | executor, designer, debugger, test-engineer, verifier, tracer, qa-tester, scientist, git-master, document-specialist | **Sonnet 5** |
| 탐색·단순 문서화 (기계적·대량) | `haiku` | explore, writer | **Haiku 4.5** |

- **Task 도구로 직접 위임할 때도 동일 기준**으로 `model` 파라미터를 명시한다 (`haiku`/`sonnet`/`opus`).
- 판단 기준 한 줄: "결과 품질이 **판단력**에 좌우되면 상위 티어, **절차 수행**이면 하위 티어."
- 메인 세션의 하이브리드 = **적응형 플랜**(설정값은 Claude Code 내장 별칭 `opusplan`): 플랜=Fable 5, 실행=Sonnet 5 자동 전환. 새 프런티어 모델이 나오면 model-watch 가 env 재매핑만 갱신해 자동 적응(직지정 금지). 실행 중 결정 지점은 어드바이저(`advisorModel: fable`)가 자동 보강.

## 2. 컨텍스트 절약 (지출의 최대 지분)

비용의 지배 요인은 thinking이 아니라 **컨텍스트 크기**(캐시 읽기/쓰기)다.

- 장황한 출력이 예상되는 작업(전체 테스트 실행, 대용량 로그 분석, 문서 대량 조회)은 **서브에이전트에 위임하고 요약만 수신** — 원문을 메인 컨텍스트에 담지 않는다.
- 테스트 실행 출력은 `filter-test-output` 훅이 자동으로 실패·요약 라인만 남긴다 (pytest / npm test / npx vitest run / go test / python -m pytest).
- 작업 전환 시 `/clear` (+`/rename` 후 `/resume`으로 복귀 가능). 압축 시 보존 우선순위는 전역 CLAUDE.md의 Compact instructions 참조.
- MCP 서버는 주기 감사: `/context`로 점유 확인, 미사용 서버는 `/mcp`에서 비활성화. CLI(gh 등)가 있으면 MCP보다 우선.

## 3. Effort — 품질 무손실 하한

- 기본: **xhigh 밴드 + adaptive thinking**(요청별 사고량 자동 조절). 이 조합이 품질 상한 유지의 기준선.
- 권장 하한: 코딩·에이전트 작업은 **high 이상 유지** — 근거: Sonnet 5·Fable 5의 기본 effort는 high이며, 공식 마이그레이션 가이드가 최고난도 코딩·에이전트 작업에 xhigh를 권장(강제 규정이 아닌 권장). `max`는 과사고·수익 체감 경향이 공식 문서에 명시돼 비권장.
- 기계적 서브 작업은 low 허용 — Fable 5는 low에서도 이전 세대 xhigh급이므로 하위 티어 위임과 병행하면 품질 손실 없음.

## 4. 측정 — 변경 전후 비교 (측정 없이 조정 없음)

- `npx ccusage daily` — 일별·모델별 토큰/비용. **기준치(실측): 2026-07-08에 `npx ccusage daily --since 20260701` 실행 — 7/3~7/8 합계 $329.73 / 157.4M 토큰(일평균 ~$66, fable-5 위주), 캐시 읽기 144.2M/157.4M ≈ 92%.** 환경·모델 구성이 바뀌면 재측정해 이 수치를 갱신할 것.
- `/usage` — 스킬·서브에이전트·플러그인·MCP별 사용량 귀속 (`d`/`w` 토글)
- 라우팅·설정 변경 후 1주 뒤 비교 항목: ① 모델 믹스(sonnet-5/haiku 비중 증가 여부) ② 일평균 비용 ③ 체감 품질(재작업 빈도)
- 품질 판단이 흔들리면 즉시 상위 티어/밴드로 복귀한다 — 절감은 되돌릴 수 있지만 잘못된 결과물의 재작업 비용이 더 크다.

## 5. 3단 릴레이 (규모 큰 작업)

§1 티어맵을 대체하지 않고 확장한다 — 규모가 큰 작업(코딩·비코딩 공통)에서만 설계(top)→검토(mid)→최종산출(exec) 멀티에이전트 릴레이가 추가로 얹히고, 미달 시 §1의 단일 위임 티어맵을 그대로 쓴다.

### 매핑

| 스테이지 | 티어 | 경로 | 호출 방식 |
|---|---|---|---|
| 설계 | top | `opus` alias | 메인 세션(plan 단계) |
| 검토 | **mid**(신설) | env 슬롯 `CLAUDE_CONFIG_MID_MODEL`(concrete id) | **headless 전용** |
| 최종산출 | exec | `sonnet` alias | **Agent 도구 세션 내 경로 전용** — headless 대상 아님 |

Haiku는 릴레이 무관(기존 탐색·대량기계적 역할 그대로).

### 트리거 — 규모 판단은 plan 단계 원칙

고정 임계치는 없다. 적응형 플랜 하에서 메인 세션은 **plan 단계에서만 top**이고 실행 단계에선 exec(sonnet-5)로 동작한다 — "메인 세션=항상 top"이 아니다. 따라서 규모 판단은 **plan 단계(top 티어)에서 내리는 것이 원칙**이고, 실행 중 규모가 재발견되는 경우는 이 원칙의 한계로 — 이때 plan 모드 복귀 또는 top 위임 재판단을 권고한다. 미달(규모 작음) 시 §1의 기존 단일 위임 티어맵을 그대로 적용한다.

### mid 호출 — headless가 주 경로

Agent 도구의 `model` 파라미터는 alias enum(`sonnet|opus|haiku|fable`)만 받고 `opus`는 top으로 리졸브되므로, **세션 내 도구로는 mid 호출 경로가 없다.** 주 경로(폴백 아님): `claude -p --model "$CLAUDE_CONFIG_MID_MODEL"`. 설계 산출물은 **파일 경로로 전달**, 검토 결과는 **파싱 가능한 verdict**로 회수 — 예: 마지막 줄 JSON `{"verdict":"approve|reject","reasons":[...]}`. exec은 headless 대상이 아니다 — Agent(`model:"sonnet"`) 세션 내 경로만 사용한다.

### headless mid 호출 규약 (전부 필수)

1. **env**: `RELAY_STAGE=review` + `CLAUDE_EVENTS_OFF=1` + `CLAUDE_AUTOSYNC_OFF=1` — `CLAUDE_EVENTS_OFF`는 model-watch·edit-nudge·edit-track·morning-brief·reconcile-check·session-events·stop-metrics를 끄지만, work-autosync.sh는 별도 스위치(`CLAUDE_AUTOSYNC_OFF`)를 쓰므로 둘 다 설정해야 한다.
2. **킬스위치 사각지대 명시**: config-sync.sh·memory-sync.sh·ensure-harness.sh·hermes-sync.sh·effort-reminder.sh·memory-inject.sh는 어떤 킬스위치도 받지 않는다(grep 실측 0건) — mid 세션에서도 이 훅들은 그대로 실행되며 그 오버헤드·부수효과는 수용한다. (후속 과제: config-sync.sh에 `CLAUDE_EVENTS_OFF` 지원 추가 검토)
3. **timeout 300초(300000ms) 이상 또는 `run_in_background` 필수** — 검토는 추론이 길다.
4. **`--disallowedTools "Write,Edit,NotebookEdit,Bash"` 또는 read-only 지시 필수** — settings의 `defaultMode: bypassPermissions` 때문에 headless 검토 세션이 기본으로 무제한 쓰기 권한을 가진다. `--disallowedTools`(결정론적)를 우선하고 프롬프트에 read-only 지시를 병기한다.
5. **재귀 릴레이 억제 이중화**: env 마커 `RELAY_STAGE` + 프롬프트 본문에 "이 세션은 릴레이 검토 스테이지다 — 릴레이를 트리거하지 말라" 명시. `RELAY_STAGE`가 설정된 세션은 릴레이를 트리거하지 않는다.

### 고위험 분류 기준 — 게이트는 고위험만 strict, 그 외 패스스루

① 프로덕션 배포·라이브 반영 ② 비가역 작업(삭제·마이그레이션·외부 실발송) ③ 보안·시크릿·권한 변경 ④ 전 머신 전파되는 설정 변경(claude-config settings/hooks/lib) ⑤ 실데이터 정합성에 영향 주는 변경.

- **타이브레이크**: 분류가 모호하면 strict (이 문서 서두 원칙 "모호하면 항상 한 단계 위 티어를 쓴다"와 동형)
- **자기적용**: 이 릴레이 구현 자체가 기준 ④에 해당한다 — 파일럿의 코딩 사례로 이 구현 자체를 릴레이+strict 반려 게이트에 태운다.

### 반려 루프

반려 → top 재설계. **최대 2회 초과 시 자동 반복 중단 + 사람 에스컬레이션**(정직 보고).

### `fallbackModel`과의 구분

`fallbackModel: [claude-opus-4-8, claude-sonnet-5]`는 API 에러/과부하 시 장애 폴백이며, 이 릴레이의 의도적 라우팅과는 무관하다.

### mid 수동 설정 절차

settings의 mid 값을 손수 변경 + `~/.claude/model-watch/pin-mid` 생성(또는 state `mid_source:"manual"` 기록) — 이후 자동 캐스케이드·복구가 이 값을 건드리지 않는다(출처 게이트).

### 측정 — `metrics.jsonl` 규약

- 위치: `~/.claude/model-relay/metrics.jsonl` (신규 — 디렉터리 1개 + append-only JSONL 1개, 세션 간 누적). 오케스트레이터가 각 스테이지 호출 직후 Bash `>>`로 1줄 append(훅 아님, 문서 규약).
- 스키마:
  ```json
  {"ts":"...","task":"짧은-슬러그","kind":"coding|non-coding","stage":"design|review|final","tier":"top|mid|exec","model":"<실효 id>","gate":"strict|pass-through","verdict":"approve|reject|n/a","redesign_round":0}
  ```
- 사용량 지표 = tier별 라인 카운트. 품질 지표 = `gate=strict`인 review 라인 중 `verdict=reject` 비율. **단일 파일에서 두 지표 모두 도출** — 신규 인프라 최소.
- **재검토 제안 로직**: 게이트 대상 최근 표본 ≥5건에서 반려율 ≥50% 또는 연속 3건 반려 → 사용자에게 투명하게 재검토 제안 1회. **재무장(re-arm)**: 제안 후 **30일 경과 OR (고위험 기준 개정·프런티어 교체) 이벤트 중 먼저 도달하는 쪽**에서 재발동.
- **로테이션 정책**: 주 1회 jq 점검 시 5,000줄(≈1MB) 초과면 `metrics-YYYYMM.jsonl`로 수동 이관 — 훅 없음 원칙 유지.
- 한계 수용: 훅이 아닌 지침 기반이므로 기록 누락 가능 — 주 1회 jq 점검을 위 §4 측정 루틴에 편입해 누락 발견 시 보정한다. "새 자동화 훅 금지" 제약과의 의도적 트레이드오프.
