---
schema_version: 1
updated: 2026-08-21
status: active
---

# 소프트웨어·AI 기능 후보 평가 규격

## 목적

공식 기능·오픈소스·플러그인·Skill·Hook·MCP·도구 후보를 “유명하다”는 이유만으로 선택하지 않고, 현재도 관리되는지와 내 환경에서 안전하게 작동하는지를 같은 형식으로 판단한다.

## 항상 최신의 의미

- 평가 시작과 적용 직전에 공식 문서·공식 저장소·공식 배포처를 다시 확인한다.
- `upstream_version` 또는 `upstream_ref`, `local_version`, `checked_at`, `evidence_urls` 중 필요한 값 하나라도 없으면 최신 상태로 판정하지 않는다.
- 새 release·폐기 공지·보안 권고·라이선스 변경·로컬 런타임 변경이 생기면 기존 승인은 `stale`로 바꾼다.
- 실행 코드나 시크릿에 접근하는 후보는 7일, 일반 참고 자료는 30일을 기본 증거 유효기간으로 둔다. 설치 직전에는 기간과 관계없이 다시 확인한다.
- 주기 검사는 새 후보와 바뀐 상태를 **제안**할 수 있지만 자동 설치·자동 업데이트·자동 설정 변경은 하지 않는다.
- rolling release는 버전 대신 commit SHA 또는 digest를 기록한다.

## 조사 순서

1. 해결하려는 기능 계약과 합격 테스트를 먼저 작성한다.
2. 대상 AI의 공식 내장 기능을 확인한다.
3. 공식 가져오기·플러그인·마이그레이션 경로를 확인한다.
4. 공식 기능으로 부족할 때만 유지되는 외부 후보를 찾는다.
5. 비슷한 종류·규모·성숙도의 후보끼리 비교한다. 가능한 경우 3개 이상을 비교하고, 표본이 부족하면 신뢰도를 낮춘다.
6. 공식 기능 → 얇은 어댑터 → 최소 직접 구현 순으로 선택한다. 외부 시스템 전체를 복제하지 않는다.

## 필수 기록 필드

| 묶음 | 필드 |
|---|---|
| 식별 | `candidate_id`, `name`, `category`, `candidate_type`, `publisher_owner`, `upstream_url` |
| 최신성 | `checked_at`, `upstream_version`, `upstream_ref`, `local_version`, `freshness_status`, `evidence_urls`, `recheck_trigger` |
| 필요성 | `purpose_gap`, `functional_contract`, `existing_base_comparison`, `peer_cohort` |
| 신뢰 | `official_status`, `maintenance_evidence`, `adoption_evidence`, `security_evidence`, `license` |
| 환경 | `supported_os`, `permission_and_data_scope`, `secret_handling`, `dependency_conflicts` |
| 검증 | `poc_result`, `acceptance_tests`, `quality`, `latency`, `token_or_cost`, `failure_test` |
| 결정 | `hard_gates`, `score_breakdown`, `confidence`, `decision_status`, `decision_reason`, `risk`, `rollback`, `decision_owner` |

## 증거 우선순위

1. 공식 제품 문서·공식 release·공식 changelog
2. 공식 저장소 코드·보안 권고·지원 OS/버전·라이선스
3. 공식 패키지 레지스트리·마켓플레이스 설치량·공개 dependents
4. 최근 사람의 issue/PR 응답, 릴리스 빈도, 활동 중인 리뷰어·릴리서, 기여 집중도
5. stars·forks·watchers와 커뮤니티 글

stars는 관심 신호이지 설치·운영 사용 증거가 아니다. 공식 기능이라는 사실도 로컬 호환성·권한·복구 시험을 면제하지 않는다.

## 하드 게이트

다음 중 하나라도 실패하면 총점과 관계없이 설치·추천하지 않는다.

- 공식 소유자와 배포 경로를 확인함
- 라이선스·이용약관과 전이 의존성을 확인함
- 해결되지 않은 치명적 보안 문제 없음
- 현재 macOS·CPU·런타임·AI 버전과 호환됨
- 필요한 권한·시크릿·외부 데이터 전송 범위를 허용할 수 있음
- 기존 기능과 충돌하거나 같은 작업을 중복 실행하지 않음
- 격리 PoC와 합격 테스트를 실행할 수 있음
- 설치 전 상태로 실제 복구할 방법과 백업이 있음

인증·고객 데이터·인프라에 닿는 후보는 보안·호환·라이선스 중 하나라도 5점 만점에 4점 미만이면 보류한다.

## 100점 평가표

각 항목을 0~5점으로 평가하고 `가중치 × 점수 ÷ 5`로 합산한다.

| 항목 | 가중치 | 확인 내용 |
|---|---:|---|
| 유지보수·릴리스 건강성 | 20 | 최근 release·commit, 사람 응답시간, PR 종료율, 패치 속도 |
| 보안·공급망 | 20 | advisories, 코드리뷰, 권한, 서명·provenance, OpenSSF 세부 검사 |
| 실환경 호환성 | 15 | OS·런타임·설정·의존성, 실제 PoC와 장애 복구 |
| 같은 종류 안의 채택 | 15 | 다운로드·dependents·실사용처·성장 추세; stars는 일부만 반영 |
| 거버넌스·버스팩터 | 10 | 독립 리뷰어·릴리서, 조직 다양성, 핵심 기여 집중도 |
| 릴리스 품질 | 10 | changelog, 버전 규칙, 보안 수정 배포 지연, downgrade 가능성 |
| 문서·지원 | 5 | 설치·운영·장애·삭제 문서와 지원 채널 |
| 기존 기능 대비 가치 | 5 | 중복이 아닌 실제 기능·품질·비용 개선 |

판정:

- 80점 이상: 도입 후보. 하드 게이트와 PoC·복구 시험은 별도 필수
- 65~79점: 제한된 파일럿만 가능
- 65점 미만: 보류 또는 대안 선택
- 증거가 부족하면 점수를 추정하지 않고 `confidence: low`, `decision_status: recheck_required`로 남김

## PoC와 적용 절차

1. 임시 HOME·worktree·컨테이너처럼 실제 환경과 분리된 곳에서 정확한 버전·SHA·digest를 고정한다.
2. 현재 방식과 후보를 같은 입력으로 비교한다.
3. 기능 결과, 오류·재시작, 데이터 보존, p95 지연, 메모리, 토큰·비용, 권한·시크릿을 측정한다.
4. 두 번 실행해도 결과가 망가지지 않는지와 여러 AI가 동시에 같은 부작용을 만들지 않는지 확인한다.
5. 설치 시험뿐 아니라 이전 상태로 실제 돌아가는 rollback drill을 실행한다.
6. 적용 직전 공식 최신 상태와 로컬 버전을 다시 확인한다.
7. 동작·권한·외부 전송이 바뀌면 사람 승인 뒤 가장 작은 범위에서 적용한다.
8. 적용 뒤 동일 회귀 테스트와 실제 환경 확인을 다시 수행하고 이식 대장을 갱신한다.

## 공통 증거원

- [GitHub Repository API](https://docs.github.com/en/rest/repos)
- [GitHub Releases API](https://docs.github.com/en/rest/releases)
- [GitHub Security Advisories](https://docs.github.com/en/rest/security-advisories)
- [OpenSSF Scorecard](https://scorecard.dev/): 총점보다 개별 검사와 근거를 사용
- [CHAOSS Starter Project Health](https://www.chaoss.community/starter-project-health-metrics-model/): 응답시간·변경 종료율·버스팩터·릴리스 빈도
- [SPDX License List](https://spdx.org/licenses/)

## 현재 자동화와의 경계

현재 `claude/lib/skill-watch.py`는 stars·최근 push·archived 같은 제한된 신호로 후보를 찾는다. 이것은 **발견기**일 뿐 최종 평가기가 아니다. 위 하드 게이트·상대평가·PoC·복구 기록을 읽는 평가기가 생기기 전까지 `skill-watch` 결과만으로 설치나 교체를 승인하지 않는다.

향후 평가기는 다음 원칙을 지킨다.

- 읽기 전용으로 증거를 모으고 `stale`·`recheck_required`를 표시한다.
- 시크릿과 원시 사용자 데이터를 저장소에 기록하지 않는다.
- 외부 API 실패를 “후보 없음”이나 “안전함”으로 바꾸지 않는다.
- 자동 설치하지 않고 근거·위험·복구안을 한 번에 제안한다.

## 후보 기록 템플릿

```yaml
candidate_id: CANDIDATE-000
name: example
category: skill
candidate_type: official
publisher_owner: example-owner
upstream_url: https://example.invalid
checked_at: 2026-08-21T00:00:00+09:00
upstream_version: unverified
upstream_ref: unverified
local_version: not_installed
freshness_status: unverified
evidence_urls: []
purpose_gap: ""
functional_contract: ""
existing_base_comparison: ""
peer_cohort: []
official_status: unverified
maintenance_evidence: []
adoption_evidence: []
security_evidence: []
supported_os: []
permission_and_data_scope: ""
secret_handling: ""
dependency_conflicts: []
license: unverified
hard_gates: pending
score_breakdown: {}
confidence: low
poc_result: not_run
acceptance_tests: []
quality: unmeasured
latency: unmeasured
token_or_cost: unmeasured
failure_test: not_run
decision_status: recheck_required
decision_reason: ""
risk: ""
rollback: ""
recheck_trigger: ""
decision_owner: unassigned
```
