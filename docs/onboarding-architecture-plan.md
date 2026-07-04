<!--
  PUBLIC 기획 문서 (claude-config 레포). PII/실명/시크릿 없음 — 아키텍처 계획만 담는다.
  멀티에이전트 기획(7개 전문 렌즈 발산 → 후보 수렴 → 적대 비평 → 통합)의 산출.
-->

# 온보딩 아키텍처 기획서 — 어떤 PC·초보 사용자든 첫 세션부터 최대 성능

> **한 줄 결정:** *"Headless-First Core + Deferred Obsidian Lens, over a Verified Gated-Glue reliability plane."*
> 초보는 **한 줄 부트스트랩 + 로그인 2회**만 하고, 그 순간부터 검증된 최신 모델·xhigh·멀티에이전트 오케스트레이션이 **기본값**으로 돌아간다. Obsidian은 **부트스트랩이 절대 설치하지 않고**, 나중에 옵트인하는 **읽기 전용 렌즈**다.

이 문서는 멀티에이전트 기획(전문 렌즈 7 + 수렴 + 적대 비평 3 + 통합 = 에이전트 12개)의 통합 산출물이다. 목적은 **claude-config 기본셋업 + Obsidian 지식뷰 + Hermes 오케스트레이션**을, *이식성 불변식*을 지키면서, **어떤 PC/초보든 첫 세션부터 최대 성능·효율**을 내도록 통합하는 것이다.

---

## 1. 성공기준 (무엇이 "최대 성능·효율 for any PC/beginner"인가)

초보가 아무것도 몰라도, 첫 세션에 무동작으로 다음이 켜져 있어야 한다:

1. **최신 모델 자동** — model-watch가 *검증된* 최신 프론티어 모델로 자동 전환(맹목적 최신이 아니라 KNOWN_GOOD).
2. **최고 강도 자동** — effortLevel=xhigh + ultracode 동적 오케스트레이션이 기본값(설정에서 찾을 필요 없음).
3. **병렬 오케스트레이션 기본** — 평문 요청이 알아서 planner/executor/critic 등으로 라우팅(슬래시 명령 지식 불필요).
4. **기억·백업 자가치유 자동** — 프로필 A1 주입, 결정·메모리 백업, 다른 PC 전파가 알아서.
5. **사소한 작업은 저비용** — 최대 성능이 "한 줄짜리 요청에도 멀티에이전트 폭발"을 의미하면 안 됨.

유일하게 불가피한 수동 단계는 GUI(Obsidian 앱 설치)와 로그인 2회다 — 이를 **최소화·지연**한다.

---

## 2. 이식성 불변식 (설계 전제 — 모든 계층이 지킨다)

중장기 다각화(특정 모델/도구 락인 회피)는 **부품이 아니라 성질**로 확보한다:

- **정본 = 열린 마크다운(git):** 기억·결정·플레이북·**에이전트 정의**. 미래의 어떤 런타임/모델이나 사람이 Claude Code 없이도, Obsidian 없이도 전체 시스템을 읽고 구동할 수 있다.
- **런타임/글루 = Claude Code 전용(훅·settings.json·플러그인 매니페스트):** 교체 저렴, 잠겨도 됨.
- **Obsidian = 정본 위의 선택적 뷰:** 절대 system of record가 아님. 삭제·재생성 가능한 투영일 뿐.
- **Hermes = 이식 가능한 오케스트레이션 *정책*:** 마크다운 정책 + 단 하나의 바인딩 파일로 런타임에 접속. 정책은 런타임 무관, 바인딩만 런타임별.

> **왜 별도 오케스트레이터(헤르메스 앱)를 지금 짓지 않는가:** 아직 Claude 외 두 번째 런타임이 없다. 지금 런타임 무관 오케스트레이터를 만드는 건 조기 추상화(YAGNI)이고, 네이티브(harness/OMC)보다 **느리고 덜 정확**하다. 그날이 오면 기층이 이식 가능하므로 전환 비용이 싸다.

---

## 3. 4계층 아키텍처

### 계층 1 — SUBSTRATE (기층: 정본, 이식 가능한 열린 마크다운)
- **claude-memory (PRIVATE):** `profile/user-profile.json`(A1 주입), `decisions/<machineId>/*.md`(YAML frontmatter + `[[wikilink]]`), `native-memory/<machineId>/`(일방 미러), `events/`(원장), `SCHEMA.md`(스키마 버전화).
- **claude-config/claude/ (PUBLIC):** `playbooks/`, `protocols/`, `skills/`, 그리고 **신설 `hermes/` 정책 트리**.
- 한 줄 부트스트랩은 **HEAD가 아니라 리뷰된 tag/SHA에 핀**되어 이 전부를 수화(hydrate)한다.
- 신뢰 경계 = GitHub 계정 + 2FA + TLS(정직하게 명시 — 지문 게이트는 설치 *이후* 커밋을 보호하지 설치 자체를 보호하진 않는다). PII는 PRIVATE 레포에만. PUBLIC 레포의 hookify pre-push PII 가드는 안전망이지 경계가 아님.

### 계층 2 — POLICY (Hermes: 이식 가능한 마크다운 정책, 런타임 아님)
`claude-config/claude/hermes/`:
- `roster.md` — 능력 역할(planner/executor/critic/researcher/reviewer/browser-op/ui-designer/security/ops-reliability)
- `routing.md` — intent → role → mode → playbook → escalation 표
- `modes.md` — smallest-fit 에스컬레이션 사다리(직접답변 → 단일 에이전트 → 모드 → autopilot/ralph)
- `capabilities.md` — 능력 → 구체 도구(browser-automation→playwright, live-docs→context7, web-fetch→insane-search)
- **`bindings/claude-code.md` — 모든 Claude Code 커플링이 격리된 단 하나의 파일.** 추상 역할/모드를 harness/OMC 에이전트·슬래시모드에 매핑. 미래 런타임은 자기 바인딩 파일만 새로 쓰면 됨.
- **이중 정본 방지:** `roster.md`는 벤더 플러그인 정의에서 **projector로 생성**(DO-NOT-EDIT 배너) + CI drift 체크로 실제와 어긋나면 실패 → 정본이 조용히 거짓말하지 못함.
- **이식성 린트**(leakscan.py 확장): 바인딩 파일 외 `hermes/*.md`에 raw `mcp__plugin_*` 이름 금지 → 정책이 재커플링 불가.

### 계층 3 — RUNTIME (Claude Code 네이티브 글루: 싸고 교체 가능, fail-open)
기존 훅 확장:
- **config-sync 분리** — 정본 DATA는 자유 자동 동기화, 실행 GLUE(훅/설정)는 **지문 검증·브랜치 보호·서명된 'promote' 커밋**(메인테이너 리뷰)으로만 전진. 초보는 핀된 글루를 소비하고 아무것도 서명 안 함.
- **memory-sync 백업 수정** — push를 취약한 SessionEnd에서 떼어 **SessionStart 멱등 backlog-flush + 세션 중 체크포인트 + best-effort end-path**로. 한 번 쓰고 끝난 세션도 반드시 푸시, 종료 경합 없음.
- **memory-inject 단일소스 카드** — Router Card + cold-start Welcome Card를 매 배포마다 hermes 정본에서 **생성**하고, 주입 시점에 announced 역할이 살아있는 바인딩으로 해소되는지 assert(드리프트면 loud 실패).
- **결정적 훅 순서** — memory-sync 클론이 inject 읽기 전에 완료 → cold-start(빈 프로필) 오탐 불가.
- **model-watch = pin + canary + rollback** — git-tracked KNOWN_GOOD 프론티어 모델.
- **crash-safe health probe(신설)** — 하드 타임아웃·fail-open·self-reporting, `events/`에 기록 + 터미널에 평문 한 줄.
- **smallest-fit GATE(UserPromptSubmit)** — 사소한 요청에 멀티에이전트 팬아웃을 결정적으로 차단.

### 계층 4 — VIEW (Obsidian: 선택·지연·옵트인·읽기 전용 렌즈, 부트스트랩 미설치)
- PII 없는 `.obsidian` "스킨"(CORE 플러그인만: Graph/Backlinks/Outline/Search/Tags)을 PUBLIC claude-config에 배포.
- 사용자가 옵트인하면 install helper가 (a) 환경 감지 후 headless/WSL/SSH/컨테이너/no-display 및 OneDrive/iCloud 리다이렉트 홈에서 **거부**, (b) 앱 설치, (c) 이미 클론된 claude-memory에 볼트 루트, (d) `obsidian.json`을 **지연·best-effort**로 설정(스키마 드리프트 관용, 'already running' 체크, 실패 시 마법사로 degrade — 죽은 사설 설정을 PUBLIC 레포에 넣지 않음).
- ~$0 vault-index 훅이 MOC(Home/Decisions/Profile/Activity/Agents + 원장 기반 System Health 노트)를 **별도 gitignore된 view 디렉터리**에 재생성 — 정본 결정 파일엔 절대 안 씀, Obsidian 있을 때만 실행.
- 지식층은 **헤드리스로도** 항상 주입되는 마크다운 포인터 + 라우팅 요약으로 전달 → 앱을 안 깔아도 손해 없음.

---

## 4. 초보 온보딩 플로우 (제로 → 맥스)

| # | 단계 | 주체 |
|---|---|---|
| 1 | 터미널에 부트스트랩 한 줄 붙여넣기 — 초보가 받는 유일한 지시 | **YOU (1회)** |
| 2 | 라이브 진행 표시 + '지금 무엇 중' 한 줄, 멱등(Ctrl-C/실패 시 재실행하면 재개). git/gh/node 설치 → 핀된 PUBLIC claude-config 클론 → ~/.claude 배포 | AUTO |
| 3 | 브라우저 로그인 **2회 정직하게 안내**: (1) GitHub(동기화·신뢰 경계) (2) Anthropic/Claude. gh가 GitHub 계정 없음 감지 시 브라우저에서 계정 생성까지 안내(막다른 길 방지). 경계 한 문장: "당신의 GitHub 계정으로 동기화 — 개인 정보는 개인 레포에만, 공개 안 됨" | **YOU (1회)** |
| 4 | SessionStart 결정적 순서·전부 fail-open: config-sync가 지문검증 글루 pull → memory-sync가 PRIVATE 메모리 부트스트랩/클론(inject 전에 완료) → memory-inject가 A1 프로필(또는 빈 프로필=cold-start 신호면 Welcome Card) + drift-checked Router Card → model-watch가 KNOWN_GOOD 검증-최신 모델 설정 | AUTO |
| 5 | crash-safe health probe가 평문 한 줄. 정상=간결('시스템 정상'), 비정상=시끄럽고 실행가능('run: claude repair') | AUTO |
| 6 | 빈 프롬프트 대신 Welcome Card: "최대 성능으로 셋업됨 — 평문으로 원하는 걸 말하세요. 예: '간단한 웹사이트 만들어줘'" 프로필 생기는 순간 자동 은퇴 | AUTO |
| 7 | 평문 목표 입력(언어 무관, 프로필 따라 기본 한국어). 설정·플래그·슬래시 명령 없음 | **YOU (1회)** |
| 8 | 모델이 Router Card 읽고 intent 분류, smallest-fit GATE 결정: 사소=직접답변(팬아웃 차단), 실제 기능=executor+critic + 평문 한 줄 고지('이 작업은 executor+critic로 진행합니다'), 강한 must-pass 신호면 /ralph·/autopilot로 에스컬레이션. xhigh+ultracode+검증최신모델 이미 가동 | AUTO |
| 9 | 무거운 작업 전 비용/레이트 한 줄 고지 + 기본 상한. 초보가 조용히 최고가 모델+xhigh+팬아웃에 얹히지 않음 | AUTO |
| 10 | 세션 종료 시 메모리 자동 커밋, backlog-flush+end-path가 한 번뿐인 세션도 푸시 보장. 오프라인/인증실패 백로그는 다음 시작 시 평문 고지(안 된 걸 '됐다'고 안 함) | AUTO |
| 11 | **실제 가치가 쌓인 뒤에만**(첫 `[[wikilink]]`/N번째 결정) 코치가 세션당 최대 1회 제안: "지식을 그래프로 볼래요? Obsidian 세팅해줄게요." 거절 무비용·기억됨 | AUTO (나중) |
| 12 | Obsidian 제안 수락: helper가 미지원 환경 건너뛰고 앱 설치 후 **사전구성·채워진 그래프**로 바로 열림 — 유일한 선택적 GUI 단계, 원할 때까지 지연 | **YOU (1회, 선택)** |

---

## 5. 성능·효율 레버 (지식 없이 최대 성능)

- **검증-최신 프론티어 모델(지배적 레버):** model-watch가 KNOWN_GOOD 유지 + 작은 결정적 헤드리스 스모크(툴콜·출력형식·거부 sanity·컨텍스트/가격 sanity) 통과 시에만 승격 → 첫 턴이 *증명된* 최고 모델로. 롤백은 settings 값 `git revert` 한 줄.
- **경계된 staleness:** 새 프론티어 모델이 N일간 미승격이면 health 라인이 알리고 최신으로 원커맨드 opt-in 제공 → '최대 성능' 약속과 안전 양립.
- **effortLevel=xhigh 영구 + ultracode 자동:** 최고 추론·동적 멀티에이전트가 out-of-box.
- **smallest-fit 라우팅을 결정적 게이트로:** UserPromptSubmit 훅이 사소한 요청의 팬아웃 차단 → 한 줄짜리에 토큰/지연/비용 안 태움.
- **바이트-고정 주입 프리픽스(정직한 캐시 = 지연/비용, 품질 아님):** memory-inject가 바이트 동일 CLAUDE.md+프로필+얇은 도구면 방출, 휘발 토큰(날짜·세션id)은 캐시 브레이크포인트 뒤로, 11개 플러그인 스키마는 defer. `cache_read_input_tokens` 로깅으로 온기 상시 증명.
- **올바른 순서의 캐시 프리웜(선택):** 유효한 프리필(max_tokens≥1, no-stream/thinking/forced-tool), 실제 턴과 *정확히 같은* 프리픽스, **pull-후-웜**, TTL 넘을 설치면 스킵. TTFT/비용 절감으로만 판매(품질 주장 아님).
- **팬아웃 캐시 규율:** 병렬 서브에이전트는 부모의 모델+도구+고정 프리픽스 상속(append-only), 오케스트레이터가 첫 요청의 첫 토큰을 기다린 뒤 나머지 발사 → 콜드 쓰기 N회 대신 방금 쓴 캐시 읽기. 독립 서브태스크는 effort:low로 비용 절감(메인은 xhigh 유지).
- **A1 개인화 무비용:** 라우팅 기본값이 주입 프로필(자동화 선호·xhigh·한국어) 읽어 사용자별 튜닝. '자동화 선호'는 다단계를 autopilot/ralph로 기울임.

---

## 6. Hermes 오케스트레이션층 (구체)

Hermes는 **오케스트레이션 정책층**이며, `claude-config/claude/hermes/`의 PUBLIC 이식 가능 마크다운으로 표현되고 이미 설치된 네이티브 오케스트레이터(harness+OMC)가 **실행**한다 — 별도 런타임 아님. 4개 정본 아티팩트(roster/routing/modes/capabilities) + 커플링 격리 바인딩 1개. roster는 벤더 플러그인에서 projector로 생성·drift 체크되어 거짓말 불가. 이식성 린트가 바인딩 밖 raw 플러그인명 금지. 자동 활성은 기존 레일 재사용: config-sync 배포 + ensure-harness가 바인딩 해소 검증(self-heal-or-warn) + Router Card 결정적 주입(정본에서 생성, 역할 해소 assert). 초보는 평문 한 문장 → 모델이 xhigh+ultracode로 카드 읽고 smallest-fit 자기선택 → 한 줄 고지 후 네이티브 실행. 각 라우팅 결정은 `events/`에 로깅되어 기존 `/retro`→`/promote`(사람 리뷰·PII-free) 루프로 자기개선.

---

## 7. Obsidian 연동 (파일시스템 정본 + 옵트인 렌즈)

파일시스템/git이 **항상** system of record. Obsidian은 선택·지연·옵트인·읽기전용 렌즈, 부트스트랩 미설치, 세션 핫패스에 절대 없음. 볼트는 이미 클론된 claude-memory에 직접 루트(임포트·복사 0) — 그래프는 이미 데이터에 존재(frontmatter id/status/supersedes/projects/tags + `[[wikilink]]`)하므로 CORE 플러그인만으로 구조를 *드러냄*(강요 아님), 커뮤니티 플러그인 safe-mode 신뢰 프롬프트 회피. `obsidian.json`은 지연·best-effort(스키마 감지, running 체크, atomic temp-write+rename, 실패 시 마법사 degrade). MOC는 gitignore된 view 디렉터리에 read-only 배너로 재생성, 정본 결정 파일엔 안 씀. 환경 거부(headless/WSL/클라우드 홈). 볼트=PRIVATE(PII), 공개 동기화 절대 없음. 선택적 Local REST API MCP는 핫패스 밖, 키는 어떤 레포에도 안 들어감. 지식층은 헤드리스로도 항상 주입 포인터로 전달.

---

## 8. 전파 (any PC / new user)

기존 레일에 얹되 강화: (1) **부트스트랩** — 핀된(tag/SHA) 한 줄, 라이브 진행·멱등 재개, 로그인 2회 안내 + 계정 생성 폴백. (2) **config-sync** — DATA 자유 pull, GLUE는 지문검증·서명 promote만; 검증 공개키는 **레포 밖(out-of-band)** 공개, 실제 경계는 GitHub 계정+2FA+TLS로 정직히 명시. (3) **memory/vault bootstrap** — memory-sync 자동 클론(자가치유), memory-inject가 A1+Router Card 재구성, Obsidian 옵트인 이력 있으면 스킨+볼트 등록 재현(PII 경계 안 넘김). (4) **self-heal** — SessionStart 훅 멱등 stat-then-heal·fail-open·하드타임아웃. (5) **supply-chain** — 11개 플러그인 SHA 핀 + 주간 헤드리스 bump-and-smoke 자동 PR(글루 영향 bump는 사람 리뷰, 보안 권고 별도 체크). Obsidian 설치 여부와 무관하게 전파.

---

## 9. 마이그레이션 단계 (작고 되돌릴 수 있게)

- **Phase 0 — 신뢰성 바닥:** memory-sync push를 SessionStart backlog-flush + 체크포인트 + end-path로(백업 유실 사건 직접 봉합). crash-safe health probe 추가. 부트스트랩·플러그인 SHA 핀. *각각 훅/설정 1개 revert로 되돌림.*
- **Phase 1 — Hermes 정본 정책층(행동 변화 0):** `hermes/{roster,routing,modes,capabilities}.md + bindings/claude-code.md`. roster projector + drift 체크 + 이식성 린트. ensure-harness 바인딩 검증. *순수 추가 → 디렉터리 삭제로 원복.*
- **Phase 2 — 단일소스 카드 + 결정적 순서:** memory-inject가 Router/Welcome Card 생성·역할 해소 assert. 훅 순서 수정(cold-start 경합 제거). *플래그 게이트 → 끄면 이전 침묵.*
- **Phase 3 — smallest-fit 게이트 + 비용 가드:** 에스컬레이션 사다리를 UserPromptSubmit 훅으로(사소 팬아웃 차단) + 비용 한 줄 고지·기본 상한. *게이트 훅 끄면 원복.*
- **Phase 4 — 검증 모델 + 게이트 글루(신뢰성 평면):** model-watch KNOWN_GOOD 핀+canary+rollback+staleness opt-in. config-sync DATA-auto vs 서명 GLUE-promote 분리. hookify PII 가드 무장. 검증키 out-of-band. *git-tracked 값 revert로 원복.*
- **Phase 5 — 스키마 버전화 + 무손실 보존:** SCHEMA.md 버전화, forward-only·backup-before-migrate·멱등 마이그레이션 + 호환 게이트(로컬 코드가 스키마 못 다루면 거부→뒤처진 머신 브릭 방지), 불변 백업, 스모크. 보존/압축은 정본 무손실(재생성 가능 텔레메트리만 압축, 결정/프로필은 archive-not-delete + 인덱스, 정본 프루닝은 사람 확인).
- **Phase 6 — Obsidian 옵트인 렌즈(마지막, 완전 선택):** PII-free CORE 스킨, 코치 훅 세션당 1회 제안(가치 쌓인 뒤), install helper(환경 거부·지연 obsidian.json·gitignore view 디렉터리·present-only vault-index·클린 언인스톨). *구성상 비-load-bearing → 통째로 드롭해도 코어 성능 영향 0.*

---

## 10. 리스크 (요약)

- 카드/바인딩 생성이 매 배포 실행·역할 해소 assert 안 하면 존재하지 않는 에이전트로 라우팅 → 단일소스 생성 + loud 실패로 완화하나 생성 단계 누락 시 잔존 위험.
- 캐시 온기는 지연 레버로 낮춰도 취약(브레이크포인트 앞 휘발 토큰 누출 시 cache_read 0) → 상시 CI 검증 필요.
- 검증-최신 모델은 canary가 좋은 모델 오탈락(업그레이드 동결) 또는 미묘 회귀 통과 가능 → staleness 알림+opt-in+빠른 롤백+수동 override, 단 스모크 커버리지는 영구 유지보수 부담.
- 메인테이너가 GLUE-promote의 단일 실패점 → 초보 경로는 fail-open·핀 소비로 무의존, 단 메인테이너 이탈 시 글루 개선 정체.
- 계정=궁극 경계 → 지문검증·브랜치보호·2FA·out-of-band 키로 공격 비용 상승, 제거는 불가. 서명키는 자동 동기화 PRIVATE 레포에 절대 안 둠.
- 부트스트랩은 여전히 수분 설치+로그인 2회 → 라이브 진행·멱등 재개·정직한 2로그인·계정 생성 폴백으로 완화, 단 첫 마찰은 '한 번 붙여넣기' 이상.
- 넛지 피로 → 세션당 1회 코치 예산·자동은퇴 Welcome·간결 green health로 완화, 단 순서/예산 중앙 강제 필수.
- Obsidian이 옵트인이어도 정본 트리 오염(.trash/cache)·클라우드 홈 PII 누출 가능 → 환경 거부·오버레이 스코핑·gitignore view·push 가드, 단 obsidian.json은 best-effort.
- 관찰자 역설(health probe 자체 고장) → 매 기록 타임스탬프(staleness가 알람)·하드타임아웃·터미널 self-report, 단 너무 관대한 타임아웃의 침묵 hang은 잔존.
- 평생 메모리 보존/압축의 '재생성 가능' 오분류 시 비가역 손실 → archive-not-delete + 정본 프루닝 사람확인, 단 오분류 버그는 잔존.

---

## 11. 검토한 대안 (멀티에이전트 프로세스)

7개 전문 렌즈(초보UX·플랫폼배포·성능·이식성회의론·지식관리/Obsidian·오케스트레이션·장기운영)가 **독립 제안** → 3개 후보로 **수렴** → 3명 적대 비평가가 **스트레스 테스트** → 통합.

| 후보 | 내용 | 판정 |
|---|---|---|
| **A. Headless-First Core + Deferred Obsidian Lens** | Obsidian이 절대 load-bearing 아님, 모든 Claude Code 커플링을 바인딩 1파일에 격리 | **채택(척추)** — 구성상 이식성 불변식을 참으로 유지 |
| **C. Reliability Plane** | KNOWN_GOOD 모델 핀+canary+롤백, SessionStart backlog-flush, crash-safe health probe, DATA-auto/GLUE-gated 분리 | **이식(graft)** — 몇 년을 버티는 방어성 |
| **B. Silent GUI Install** | 부트스트랩이 조용히 Obsidian 앱 설치 | **기각** — 멀웨어처럼 읽힘, headless/WSL 낭비, 자체 수정안이 결국 A로 붕괴 (단 환경 감지·오버레이 스코핑 위생은 옵트인 시점에 채택) |

**적대 비평이 수렴한 3대 진실:** ① Obsidian은 옵트인·핫패스 밖이어야 한다. ② "첫 턴 최대 성능"은 캐시 주장이 아니라 **모델+추론+오케스트레이션** 주장이다(warm-cache는 정직한 지연/비용 레버로 강등). ③ 공개 레포 코드를 매 머신에서 자동 실행하는데 경계가 계정뿐인 게 진짜 장기 리스크 → DATA-auto/GLUE-gated 분리·핀된 부트스트랩·평문 health probe는 비타협.

---

## 12. 결정 (Decision Record 요약)

우리는 온보딩 아키텍처를 **"Headless-First Core with a Deferred Obsidian Lens, over a Verified Gated-Glue reliability plane"** 으로 구축한다. (1) 핀된 한 줄 부트스트랩이 유일한 초보 관문, 로그인 2회 정직 안내·라이브 진행·멱등 재개. (2) 모든 성능 기본값(검증-최신 모델·xhigh·ultracode·harness/OMC)은 사전 배선되어 '최대 성능'이 out-of-box, 사소 요청엔 결정적 smallest-fit 게이트 + 비용 한 줄. (3) Hermes는 `claude-config/claude/hermes/`의 PUBLIC 이식 마크다운(roster는 벤더에서 생성·drift 체크, 커플링은 바인딩 1파일, 이식성 린트)로 harness/OMC가 실행, 단일소스 Router/Welcome Card가 역할 드리프트에 loud 실패. (4) 신뢰성 일급: SessionStart backlog-flush로 백업 유실 봉합, crash-safe health probe 평문 한 줄, config-sync DATA-auto/서명 GLUE-promote 분리·검증키 out-of-band, 플러그인 SHA 핀, 스키마 마이그레이션 호환 게이트+불변 백업+무손실 보존. (5) Obsidian은 부트스트랩 미설치·비-load-bearing — 옵트인·환경가드·CORE-only 읽기 렌즈, MOC는 gitignore view, 지식층은 헤드리스 주입 포인터로도 전달. **이유:** 첫 턴 최대 성능·거의 0 마찰을 주고, 이식성 불변식을 구성상 참으로 유지하며, 침묵 실패와 계정-경계 리스크에 몇 년을 버틴다 — 모든 추가 메커니즘이 기존 claude-config 훅 패턴을 복제해 새 런타임 없이 YAGNI를 지킨다.

---

*생성: 2026-07-05 · 멀티에이전트 기획(12 에이전트) 통합 · 정본 결정 레코드: `claude-memory decisions/HOME/`*
