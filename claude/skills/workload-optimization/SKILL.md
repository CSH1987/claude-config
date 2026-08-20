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
| 기획·아키텍처·비평·synthesis (최상위 판단, 결과를 좌우) | `opus` | planner, architect, critic, analyst | **Fable 5** |
| 검증·리뷰·판정 (품질 게이트 — 지시받은 기준으로 판단만 수행) | **mid** | code-reviewer, security-reviewer, verifier | **Opus 5** (`CLAUDE_CONFIG_MID_MODEL`) |
| 구현·디버그·테스트·문서조사·정리(스펙이 정해진 실행) | `sonnet` | executor, designer, debugger, test-engineer, tracer, qa-tester, scientist, git-master, document-specialist, code-simplifier | **Sonnet 5** |
| 탐색·단순 문서화 (기계적·대량) | `haiku` | explore, writer | **Haiku 4.5** |

- **Task 도구로 직접 위임할 때**는 `model` 파라미터가 alias enum(`haiku`/`sonnet`/`opus`)만 받아 mid를 직접 못 가리킨다 — mid 행 에이전트를 Task 도구로 위임할 땐 opus로 대체(품질 우선, 비용 최적은 §5.10의 Workflow 경로에서). Workflow `agent()`로 위임할 땐 §5.10 규약대로 mid를 구체 id로 명시.
- 판단 기준 한 줄: "**무엇을 만들지/어떻게 갈지 스스로 정해야 하면** top, **주어진 기준으로 합격·불합격만 판정하면** mid, **정해진 스펙을 그대로 수행하면** sonnet."
- 메인 세션의 하이브리드 = **적응형 플랜**(설정값은 Claude Code 내장 별칭 `opusplan`): 플랜=Fable 5, 실행=Sonnet 5 자동 전환. 새 프런티어 모델이 나오면 model-watch 가 env 재매핑만 갱신해 자동 적응(직지정 금지). 실행 중 결정 지점은 어드바이저(`advisorModel: fable`)가 자동 보강.
- **2026-08-18 조정**: `code-simplifier`를 opus→sonnet으로 하향. 원인은 [[fable-usage-balancing-routing]] 메모리가 명시한 opus 우선 원칙(2026-07-18, Fable 활용도가 낮다는 이유로 도입)이 실제로는 대형 워크플로의 opus-tier 서브에이전트 위임 건수를 늘려 Fable 사용량 급증으로 이어졌기 때문(ccusage 실측: 14일 Fable 지출의 62%가 세션 3개에 집중, 그중 다수가 Task/Agent 서브에이전트 위임). `code-simplifier`는 판단보다 절차적 성격이 강해 가장 낮은 리스크로 하향. 나머지 판단역할(planner·architect·critic 등)은 opus 유지.
- **2026-08-20 조정 — 3티어 워크포스**: 위 62% 집중분을 역할별로 실측 분해한 결과(세션 트랜스크립트 직접 집계), 지배 역할은 비평·synthesis가 아니라 **code-reviewer/security-reviewer 검증·리뷰 위임**이었다(사회자/synthesis 서브에이전트는 검증 대상 세션에서 0건). "지시받은 기준으로 판단만 하는" 검증·리뷰·판정 역할은 top(Fable)까지 필요치 않다고 보고 mid(Opus 5)로 분리 — 기획·비평·synthesis처럼 스스로 방향을 정하는 역할만 top에 남긴다. Opus 5 정가는 Fable 5의 50%(2026-08 공식 요금표 확인 — 이 환경은 구독 OAuth 전용이라 실제 청구액이 아닌 정가 기준 비교치, 실제 절감 효과는 아래 §5.10의 실측 루프로 확인). 상세 라우팅 방법·fan-out 규약은 아래 §5.10. [[fable-usage-balancing-routing]] 메모리도 이 역할 분해로 갱신.

## 2. 컨텍스트 절약 (지출의 최대 지분)

비용의 지배 요인은 thinking이 아니라 **컨텍스트 크기**(캐시 읽기/쓰기)다.

- 장황한 출력이 예상되는 작업(전체 테스트 실행, 대용량 로그 분석, 문서 대량 조회)은 **서브에이전트에 위임하고 요약만 수신** — 원문을 메인 컨텍스트에 담지 않는다.
- 테스트 실행 출력은 `filter-test-output` 훅이 자동으로 실패·요약 라인만 남긴다 (pytest / npm test / npx vitest run / go test / python -m pytest).
- 작업 전환 시 `/clear` (+`/rename` 후 `/resume`으로 복귀 가능), **같은 작업을 이어가며 압축만 필요하면 `/compact`**. 압축 시 보존 우선순위는 전역 CLAUDE.md의 Compact instructions 참조.
- 컨텍스트 사용률 체감 기준(커뮤니티 컨센서스 휴리스틱 — 공식 수치 아님): `/context`로 점유율 확인, 20~40%부터 정확도 저하 체감 시작, 60% 근접 시 정리 고려, 90%+는 즉시 `/clear` 권장. 관찰 메커니즘은 공식 `statusLine`(`context_window.used_percentage`, 입력 토큰만 계산)로 확인됨 — 매 턴 상태줄에 상시 표시되고(`statusline.sh`/`.ps1`), 색만이 아니라 문구도 함께 뜬다(30%🟡/60%🟠 정리 고려/90%🔴 지금 정리! — 색상 의미를 몰라도 바로 이해되게), 30%/90%를 위로 통과하면 Stop 훅(`context-notify.sh`/`.ps1`)이 1회성으로도 알려준다(2026-08-19 반영, 2026-08-20 첫 임계치를 30%로 보정 — 20~40% 저하 체감 구간의 중간값으로 맞춤).

- MCP 서버는 주기 감사: `/context`로 점유 확인, 미사용 서버는 `/mcp`에서 비활성화. CLI(gh 등)가 있으면 MCP보다 우선.
- Workflow 스크립트는 기본이 `pipeline()` — `parallel()`(barrier)은 ①전체 결과를 모아 종합/중복제거 ②건수 기준 조기 종료 ③상호 비교 판단, 이 중 하나가 실제로 필요할 때만 쓴다.

## 3. Effort — 적응형 이펙트 정책(모델의 적응형 플랜과 대칭)

- 바닥값: **high + adaptive thinking**(요청별 사고량 자동 조절)이 `settings.json`에 영구 적용. 모델의 적응형 플랜(계획=최상위/실행=효율)과 대칭되게, effort도 **판단력이 결과를 좌우하는 작업(기획·설계·아키텍처·비평·근본원인 디버깅)은 `/effort xhigh`로 전환 제안**, 절차 수행형 실행 작업은 바닥값 high 유지.
- **자동 전환 불가(사실 확인됨, [[claude-config/claude/CLAUDE.md]] 참조)**: opusplan과 달리 effortLevel엔 plan-mode phase-aware 메커니즘이 없고 훅으로도 흉내낼 수 없음(엔진 내부 모드 감지 불가 + 훅 프로세스 env가 부모 세션에 전파 안 됨) — 그래서 xhigh 전환은 매번 사용자에게 제안 후 `/effort xhigh`를 사용자가 직접 실행해야 함.
- 근거: Sonnet 5·Fable 5의 기본 effort는 high이며, 공식 마이그레이션 가이드가 최고난도 코딩·에이전트 작업에 xhigh를 권장(강제 규정이 아닌 권장). `max`는 과사고·수익 체감 경향이 공식 문서에 명시돼 비권장.
- 기계적 서브 작업은 low 허용 — Fable 5는 low에서도 이전 세대 xhigh급이므로 하위 티어 위임과 병행하면 품질 손실 없음.

## 4. 측정 — 변경 전후 비교 (측정 없이 조정 없음)

- `npx ccusage daily` — 일별·모델별 토큰/비용. **기준치(실측): 2026-07-08에 `npx ccusage daily --since 20260701` 실행 — 7/3~7/8 합계 $329.73 / 157.4M 토큰(일평균 ~$66, fable-5 위주), 캐시 읽기 144.2M/157.4M ≈ 92%. 2026-08-19 재측정: 일일 $209.15/435.9M 토큰, Sonnet이 비용의 68%($143.47)이고 그중 93%가 cache-read.** 환경·모델 구성이 바뀌면 재측정해 이 수치를 갱신할 것.
- `/usage` — 스킬·서브에이전트·플러그인·MCP별 사용량 귀속 (`d`/`w` 토글)
- 라우팅·설정 변경 후 1주 뒤 비교 항목: ① 모델 믹스(sonnet-5/haiku 비중 증가 여부) ② 일평균 비용 ③ 체감 품질(재작업 빈도)
- 품질 판단이 흔들리면 즉시 상위 티어/밴드로 복귀한다 — 절감은 되돌릴 수 있지만 잘못된 결과물의 재작업 비용이 더 크다.
- **2026-08-19 신규 진단 신호(조치 아님, 관찰만)**: 공식 문서 확인 결과 적응형 플랜의 plan↔exec 모델 전환(opusplan)마다 그 시점까지의 대화 전체가 캐시미스로 재처리된다("each plan-mode toggle is a model switch and starts a fresh cache"). 무효화 비용은 전환 시점 누적 대화 길이에 비례 — 세션 후반부의 잦은 왕복 전환이 특히 비쌀 수 있다. **지금은 낭비라는 증거가 없으므로 전환 빈도를 임의로 줄이라는 지시가 아니다** — ccusage/세션 로그에서 model-switch 이벤트와 `cache_creation_input_tokens` 급증 시점을 상관분석해보고, 실제로 불필요하게 잦은 왕복이 데이터로 확인되면 그때 "같은 판단량을 유지한 채 전환 횟수만 줄이는"(판단을 한 번에 모아 확정) 방향을 검토한다. 조사 근거: `~/Documents/Vault/90_Hermes/보고서/2026-08-19_학습파이프라인-외부사례기반-고도화기획.md` §토큰최적화.
- **모델 라우터·시맨틱 캐시·Batch API는 검토 후 기각됨(2026-08-19)** — 전부 API 키 기반 과금 경로를 전제하는데 우리 시스템은 구독 OAuth 전용(`ANTHROPIC_API_KEY` 사용 금지)이라 구조적으로 적용 불가. 실제 프로덕션 사례(Manifest)가 "캐싱이 라우팅을 이긴다"며 자체 LLM 라우터를 폐기한 근거까지 확보 — 우리 시스템은 이미 그 결론(cache-read 93%)에 도달해 있다. 재검토 조건: 구독 정책이 API 키 병행 허용으로 바뀌거나, 우리 워크로드에 "유사 질의 반복" 패턴이 실제로 생기는 경우.

## 5. 3단 릴레이 (규모 큰 작업)

§1 티어맵을 대체하지 않고 확장한다 — 규모가 큰 작업(코딩·비코딩 공통)에서만 설계(top)→검토(mid)→최종산출(exec) 멀티에이전트 릴레이가 추가로 얹히고, 미달 시 §1의 단일 위임 티어맵을 그대로 쓴다.

### 매핑

| 스테이지 | 티어 | 경로 | 호출 방식 |
|---|---|---|---|
| 설계 | top | `opus` alias | 메인 세션(plan 단계) |
| 검토 | **mid**(신설) | env 슬롯 `CLAUDE_CONFIG_MID_MODEL`(concrete id, 세대별 Opus를 이름으로 자동 감지·유지 — model-watch, 2026-08-20) | **headless 전용**(대규모 릴레이) **+ 세션 내 Workflow `agent()` 경로**(개별 검증·리뷰 스테이지, 2026-08-20 §5.10 확인) |
| 최종산출 | exec | `sonnet` alias | **Agent 도구 세션 내 경로 전용** — headless 대상 아님 |

Haiku는 릴레이 무관(기존 탐색·대량기계적 역할 그대로).

### 트리거 — 규모 판단은 plan 단계 원칙

고정 임계치는 없다. 적응형 플랜 하에서 메인 세션은 **plan 단계에서만 top**이고 실행 단계에선 exec(sonnet-5)로 동작한다 — "메인 세션=항상 top"이 아니다. 따라서 규모 판단은 **plan 단계(top 티어)에서 내리는 것이 원칙**이고, 실행 중 규모가 재발견되는 경우는 이 원칙의 한계로 — 이때 plan 모드 복귀 또는 top 위임 재판단을 권고한다. 미달(규모 작음) 시 §1의 기존 단일 위임 티어맵을 그대로 적용한다.

### mid 호출 — 대규모 릴레이는 headless, 개별 검증·리뷰 스테이지는 세션 내 Workflow 경로

**2026-08-20 정정**: "세션 내 도구로는 mid 호출 경로가 없다"는 서술은 낡았다 — Agent(Task) 도구의 `model` 파라미터는 여전히 alias enum(`sonnet|opus|haiku|fable`)만 받아 mid를 못 가리키지만(이 제약은 유효), **Workflow의 `agent()`는 구체 모델 id 문자열을 받는다**(공식 문서, 이 세션에서 실측 확인: `agent(prompt, {model:"claude-opus-5"})` → 실제 서빙 모델 응답 확인). §5.10에서 이 경로를 검증·리뷰·판정형 개별 스테이지의 mid 라우팅 정본으로 쓴다.

이 절(§5.3)이 다루는 **대규모 설계→검토 릴레이**(전체 산출물을 통째로 재검토, 자기 세션과 분리된 컨텍스트 필요)는 여전히 headless가 주 경로: `claude -p --model "$CLAUDE_CONFIG_MID_MODEL"`. 설계 산출물은 **파일 경로로 전달**, 검토 결과는 **파싱 가능한 verdict**로 회수 — 예: 마지막 줄 JSON `{"verdict":"approve|reject","reasons":[...]}`. exec은 headless 대상이 아니다 — Agent(`model:"sonnet"`) 세션 내 경로만 사용한다.

**구분 기준**: 릴레이 전체(설계 산출물 통짜 재검토, 자기 컨텍스트 오염 방지 필요) = headless. Workflow 파이프라인 내 개별 검증·리뷰·판정 스테이지(코드리뷰 fan-out, verdict 판정 등) = §5.10의 세션 내 Workflow 경로.

### headless mid 호출 규약 (전부 필수)

1. **env**: `RELAY_STAGE=review` + `CLAUDE_EVENTS_OFF=1` + `CLAUDE_AUTOSYNC_OFF=1` — `CLAUDE_EVENTS_OFF`는 model-watch·edit-nudge·edit-track·stop-metrics를 끄지만, work-autosync.sh는 별도 스위치(`CLAUDE_AUTOSYNC_OFF`)를 쓰므로 둘 다 설정해야 한다.
2. **킬스위치 사각지대 명시**: config-sync.sh·ensure-harness.sh·hermes-sync.sh·effort-reminder.sh는 어떤 킬스위치도 받지 않는다(grep 실측 0건) — mid 세션에서도 이 훅들은 그대로 실행되며 그 오버헤드·부수효과는 수용한다. (후속 과제: config-sync.sh에 `CLAUDE_EVENTS_OFF` 지원 추가 검토)
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

### §5.10 워크포스 라우팅 — 검증·리뷰·판정형 Workflow 스테이지 (2026-08-20)

Fable=기획(top)·Opus 5=지시받은 기준으로 판단만 하는 "검증 직원"(mid)·Sonnet=구현(exec)이라는 3티어 워크포스를 Workflow 오케스트레이션(그래프 엔지니어링)에 적용하는 규약. §1 티어맵의 mid 행(code-reviewer/security-reviewer/verifier)과 위 릴레이 mid를 Workflow `agent()` 호출 단위로 구체화한다. **적용 범위는 Workflow `agent()` 경로에 한정** — §1에 명시했듯 Task(Agent) 도구로 같은 역할을 위임할 땐 alias enum 제약 때문에 opus(=top/Fable)로 대체되므로, Task 경로로 위임되는 몫에는 이 절의 mid 라우팅·절감이 적용되지 않는다.

**① mid literal 주입 방법 — 영구 리터럴 0건**: Workflow 스크립트는 `args`로 현재 `CLAUDE_CONFIG_MID_MODEL` 값을 받아 `agent(prompt, {model: midModelId, ...})`에 그대로 넘긴다. 스크립트 코드 자체에 특정 모델명을 하드코딩하지 않으므로(호출 시점 env 값을 읽어 전달) model-watch 동기화 스코프 확장이 필요 없다 — 세대 교체 시에도 다음 실행부터 자동으로 새 mid를 쓴다. 호출자는 `args.midModel`이 비어 있으면 즉시 실패시켜야 한다(learning-pipeline의 `!args.vault10Path` 가드와 같은 fail-fast 패턴) — 누락 시 `{model: undefined}`로 조용히 상속되면 바로 아래 ②가 금지하는 상황이 재현된다.

**② 판단·검증 스테이지 model 미지정 = 버그**: Workflow 파이프라인에서 검증·리뷰·판정(verdict/moderator/code-review 등) 역할의 `agent()` 호출에 `model`을 지정하지 않으면 메인 세션의 현재 모델(대개 exec=Sonnet)을 조용히 상속한다 — 품질 게이트가 알아채지 못한 채 강등되는 것과 같다. §5.9의 "훅 없음, 지침 기반" 트레이드오프와 동일한 계열의 한계이며, 새 워크플로 작성·기존 워크플로 수정 시 검증·리뷰·판정 스테이지는 반드시 `model: midModelId`를 명시한다. (실측 사례: `expert-debate.js`의 moderator/consensus 스테이지가 전부 미지정 상태로 Sonnet 실행 중이었음 — 2026-08-20 확인. 이 파일 자체는 ④에 따라 지금 소급 수정하지 않는다 — 기록만 남긴다.)

**③ 검증 fan-out — 조건부, 측정 후 상향**: Opus 5 가격은 Fable 5의 50%(2026-08 공식 요금표 확인, 구독 OAuth 환경이라 실제 청구가 아닌 정가 기준 비교치)이므로, Workflow `agent()` 경로로 도는 검증 스테이지는 이론상 같은 예산으로 리뷰어를 더 고용할 여지가 있다(예: top 3인 예산 ≈ mid 5인). **다만 이 절감은 아직 실측되지 않았고(§4 "측정 없이 조정 없음"), 위에서 밝힌 대로 Task 경로 위임분에는 적용되지 않는다** — 그래서 fan-out 기본값을 지금 3→5로 올리지 않는다. `lens:routing`(아래) 주간 리포트가 실제 반려율·지출로 확인해준 뒤에만, 사람 승인을 거쳐 이 절의 기본 fan-out을 조정한다. 워크플로 설계 시 세션의 워크플로 크기 가이드라인(기본 15 에이전트 미만)을 넘으면 배치 분할(pipeline 단계별로 나눠 실행)하거나, 사용자에게 `/config`의 "Dynamic workflow size" 상향을 안내한다 — 임의로 가이드라인을 넘기지 않는다.

**④ 기존 파일 면제**: 이 규약 이전에 작성된 워크플로(`expert-debate.js` 등)는 **파일 단위로 일괄** 면제 — 다음에 그 파일을 수정하는 시점에 파일 전체를 이 규약에 맞춰 갱신한다(스테이지 일부만 손대고 나머지를 미지정으로 남기지 않는다). 그 전까지는 ②의 실측 위반 기록처럼 관찰만 하고 소급 수정하지 않는다.

**⑤ 롤백 트리거**: 별도 임계치를 새로 만들지 않고 §5.9의 기존 재검토 임계치(게이트 대상 표본≥5건에서 반려율≥50% 또는 연속 3건 반려)를 그대로 재사용한다 — 해당 역할을 mid→top으로 복귀 제안. 단일 소스 유지(§5.9와 이 절이 서로 다른 임계치를 갖지 않도록).

**⑥ 구현(executor) 위생**: 구현·절차형 서브에이전트는 기존 규약대로 sonnet(상속 또는 명시) — mid/top으로 올리지 않는다. (실측 위반 사례: 2026-08-20 세션 분해에서 executor 구현 위임 12건이 Fable로 실행된 세션 1개 발견, 해당 세션 Fable 지출의 23.9% — 규약 재강조 근거.)

**적용 범위 (단계적, 2026-08-20 결정)**: 이번 단계는 code-reviewer/security-reviewer/verifier류 검증·리뷰·판정 스테이지만, Workflow `agent()` 경로에 한해 mid로 이관한다. critic·synthesis·moderator처럼 스스로 방향을 정하는 역할은 top(Fable) 잔류 — 이관 여부는 `lens:routing`(아래) 주간 리포트의 반려율·지출 데이터를 본 뒤 사람 승인으로 판단한다.

**성장형(자가개선) 루프**: 학습파이프라인(`claude/learning-pipeline/pipeline.workflow.js`)의 `lens:routing` 스테이지가 주 1회 ccusage 지출·`metrics.jsonl` 반려율·역할×실효모델 적합성(②의 미지정 위반 포함)을 집계해 라우팅 개선 **제안 드래프트**를 만든다. 이 드래프트는 다른 렌즈들과 달리 **synthesis 단계(캐노니컬 문서를 Edit하는 유일한 스테이지)에 전달되지 않는다** — Vault `90_Hermes/라우팅제안/` 아래 별도 드래프트 파일로만 남고, `10_컨텍스트` 캐노니컬 문서·이 SKILL.md·CLAUDE.md는 이 루프가 자동으로 건드리지 않는다. 적용은 항상 사람이 그 드래프트를 읽고 직접 승인한 뒤(CLAUDE.md "claude-config 동작 변경은 드래프트+사람승인" 규칙) — 측정·분석·제안은 자동, 라우팅 규약(이 문서) 변경만 게이트.
