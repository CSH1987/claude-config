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
- 메인 세션의 하이브리드: `opusplan` 선택 시 플랜=Fable 5, 실행=Sonnet 5 자동 전환. 실행 중 결정 지점은 어드바이저(`advisorModel: fable`)가 자동 보강.

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
