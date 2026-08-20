# Hermes Agent 연동 가이드 — claude-config 규칙 자동 적용

대상: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). 이 문서는 hermes 설치 **전에** 준비된 것으로, 설치 즉시 규칙이 자동 적용되도록 하는 체계와 내일 작업 체크리스트를 담는다.

> **설치 대상 머신 = 맥미니** (오케스트레이터·게이트웨이 상시 가동 머신). Windows 업무 PC에는 설치하지 않는다 — Windows 쪽 할 일은 claude-config 엣지 배포(installer + deploy 스탬프)뿐. (2026-07-08 Windows 착오 설치→제거 후 명시)

## 자동 적용 체계 (이미 준비 완료)

| 구성요소 | 위치 | 역할 |
|---|---|---|
| `portable-rules.md` | `claude/exports/` (배포: `~/.claude/exports/`) | CLAUDE.md 핵심 규칙의 플랫폼 중립 증류판 (2026-08-19: "공통 지침 착지점 — Vault 10_컨텍스트=정본" 절 추가) |
| `hermes-vault-rules.md` | `claude/exports/` (배포: `~/.claude/exports/`) | Vault(옵시디언) 연동 안내 정본 — 2026-08-19 정본화(종전 `~/.hermes/AGENTS.md` 블록 밖에만 있어 실효 로드 파일에 전달 안 되던 결함 수정) |
| `hermes-sync.ps1` / `.sh` | `claude/hooks/` (배포: `~/.claude/hooks/`) | hermes 감지 시 규칙·스킬 자동 주입 (미설치 시 무동작). `.sh`는 2026-08-19부터 마커 블록 3종 주입(아래), `.ps1`은 블록 1종만(Windows에 hermes 없음 — 패리티 후속) |
| SessionStart 훅 등록 | `settings.json` | 매 Claude Code 세션 시작 시 hermes-sync 실행 → hermes 설치 후 **추가 조치 없이** 자동 적용 |

마커 블록 3종 (2026-08-19부터, `.sh` 기준):
- `claude-config:portable-rules` — 규칙 정본 주입
- `claude-config:hermes-vault-rules` — Vault 연동 안내 주입
- `claude-config:vault-context` — Vault `10_컨텍스트` 인덱스 캐시(정본=Vault, `vault-index.py` 재사용, 인덱스 생성 실패 시 기존 블록 유지=스테일 캐시가 삭제보다 안전, 타임스탬프 없음=멱등·프롬프트 캐시 보호)

동작 방식 (2026-07-08 실측 반영 — hermes v0.18.2):
1. `hermes-sync`가 `~/.hermes`(또는 Windows `%LOCALAPPDATA%\hermes` — **Windows 설치 시 실제 설정 디렉터리**)를 감지
2. hermes는 AGENTS.md를 **세션 작업 디렉터리(cwd)에서만** 로드한다(`agent/prompt_builder.py`, cwd only). 게이트웨이 기본 cwd = config.yaml `terminal.cwd`(플레이스홀더 `.`/`auto`/`cwd`면 홈 디렉터리 폴백). 따라서 마커 블록(`<!-- claude-config:portable-rules:start/end -->`)을 **두 곳에** 삽입: ① `HERMES_HOME/AGENTS.md`(공식 프로필 아티팩트) ② 실효 게이트웨이 cwd(`terminal.cwd` 절대경로 또는 홈)의 `AGENTS.md` — **hermes가 스스로 관리하는 내용은 보존**, 재실행 시 블록만 갱신(멱등)
3. AGENTS.md는 **반드시 BOM 없는 UTF-8**로 기록 — hermes 스캐너가 U+FEFF 포함 파일을 `invisible_unicode`로 차단함
4. 이식 가능한 스킬(`workload-optimization`)을 hermes `skills/`로 복사 (hermes 사용자 스킬 규약 `skills/<maybe-category>/<name>/SKILL.md` 호환)

수동 실행: `powershell -File ~/.claude/hooks/hermes-sync.ps1` (테스트: `-HermesDir <경로>` 오버라이드)

## 내일 작업 체크리스트 (텔레그램 연동 + 성장형 오케스트라)

1. **설치**: hermes-agent 설치 (공식 README의 install 절차) → `hermes setup` 마법사
2. **Claude 연결**: hermes는 "own endpoint" 방식 지원 — 모델 설정에서 Anthropic 엔드포인트/키 지정 (`hermes model`). 주의: hermes는 Claude Code가 아니므로 settings.json·훅은 적용되지 않음 — 규칙은 위 자동 주입이 담당
3. **규칙 적용 확인**: 새 Claude Code 세션 1회 시작(또는 hermes-sync 수동 실행) → `~/.hermes/AGENTS.md`에 마커 블록 생겼는지 확인
4. **텔레그램**: `hermes gateway setup` → 봇 토큰 입력 → `hermes gateway start` → 봇에게 메시지로 확인. **봇 토큰은 절대 레포·프롬프트에 넣지 않기**
5. **옵시디언**: hermes에 네이티브 통합은 없음 — 볼트가 로컬 마크다운이므로 hermes 파일 도구로 접근 가능. ~~볼트 경로를 AGENTS.md의 hermes 자체 영역(마커 블록 밖)에 기재~~ → 2026-08-19부터 `exports/hermes-vault-rules.md`가 정본이고 sync가 `claude-config:hermes-vault-rules` 블록으로 자동 주입(수동 기재 불필요·금지 — 블록 밖 수동 기재는 실효 게이트웨이 cwd 쪽 AGENTS.md에 전달되지 않던 결함의 원인이었음)
6. **페르소나(SOUL.md)**: portable-rules는 작업 규칙만 담음 — 말투·성격은 SOUL.md에서 별도 관리 (자동 주입 안 함, 의도적)
7. **성장형 운영**: hermes MEMORY.md·skills가 성장 축 — 잘 통하는 패턴은 claude-config 쪽 플레이북과 상호 이식(retro→promote 흐름과 동일 원리)

## 코덱스(codex CLI) 연동 — 연동 시스템 전체 동기화 대상에 포함 (2026-08-20)

대상: OpenAI Codex CLI(`/opt/homebrew/bin/codex`, 맥미니에 2026-08-20 설치·GPT 구독 연동). 현재 연동된 모든 시스템을 동기화한다는 계약에 따라, hermes-sync와 같은 마커 블록 upsert 패턴을 `codex-sync.sh`로 재사용한다. 새 시스템이 연동되면 같은 정본·동기화 구조에 포함한다.

| 구성요소 | 위치 | 역할 |
|---|---|---|
| `codex-vault-rules.md` | `claude/exports/` (배포: `~/.claude/exports/`) | 코덱스용 Vault 연동 안내(hermes-vault-rules.md는 obsidian 스킬 등 hermes 전용 내용 포함이라 별도 파일) |
| `codex-sync.sh` | `claude/hooks/` (배포: `~/.claude/hooks/`) | 코덱스 감지 시(`~/.codex` 존재) 규칙 자동 주입, 미설치 시 무동작 |
| SessionStart 훅 등록 | `settings.json` | hermes-sync 다음 순번으로 실행 |

동작 방식 (2026-08-20 실측 검증):
1. 코덱스는 `$CODEX_HOME/AGENTS.md`(기본 `~/.codex/AGENTS.md`)를 **cwd 무관 전역 지침**으로 로드한다 — hermes와 달리 게이트웨이 cwd 종속이 아니라 대상 파일 1곳(`$CODEX_DIR/AGENTS.md`)이면 충분. 검증 방법: 테스트 마커 문장을 `~/.codex/AGENTS.md`에 심고 다른 cwd(`~/claude-config`)에서 `codex exec --sandbox read-only "..."` 실행 → 마커 그대로 인용됨 확인.
2. 마커 블록 3종: `claude-config:portable-rules` / `claude-config:codex-vault-rules` / `claude-config:vault-context` (hermes와 동일 3종, 대상 파일만 다름).
3. **install.sh에 훅 파일 링크 추가를 잊으면 매 세션 exit 127로 조용히 실패한다** — vault-context.sh 때 실측된 것과 같은 함정(기록: `install.sh:183-186` 주석). settings.json SessionStart 등록 + install.sh `ln -sfn`/chmod 목록 둘 다 반드시 갱신할 것.

재설치·재등록 시:
- 규칙 재주입: `bash ~/.claude/hooks/codex-sync.sh` 수동 실행(멱등 — 몇 번 실행해도 마커 블록 각 1개 유지).
- 로드 확인: `codex exec --sandbox read-only --skip-git-repo-check "로드된 지침에서 응답 언어 규칙 한 줄만 인용하라"`.

## 헤르메스 라우팅 자가점검 크론 (2026-08-20)

헤르메스가 자기 `config.yaml`의 provider/model 매핑을 `workload-optimization` SKILL.md(3티어 원칙)와 대조해 불일치를 찾고, **제안만** Vault `90_Hermes/라우팅제안/`에 드래프트로 남기는 주간 크론.

- 프롬프트 원문(정본): `claude/exports/hermes-cron-prompts/routing-self-review.txt`
- 등록 명령: `hermes cron create --name routing-self-review --deliver "telegram:<chat_id>" '0 10 * * 1' "$(cat claude/exports/hermes-cron-prompts/routing-self-review.txt)"` — `<chat_id>`는 로컬 `~/.hermes/config.yaml`(또는 기존 vegas 잡)에서 확인, PUBLIC 레포에 실제 chat ID를 적지 않는다.
- 잡 ID: `b5ce6f889daa` (등록일 2026-08-20, 첫 실행 2026-08-24 10:00).
- **거버넌스**: config.yaml 직접 수정 금지 — 검색·분석·제안까지만 자동, 적용은 사람 승인(claude-config `lens:routing` 루프와 같은 원칙, CLAUDE.md 2026-08-19 "동작·라우팅을 바꾸는 규칙은 드래프트+사람승인" 규정을 헤르메스 쪽에도 동일 적용).
- 확인: `hermes cron list`로 등록 여부, `hermes cron run routing-self-review`(또는 다음 정기 실행)로 Vault 드래프트 생성 + config.yaml 해시 불변 확인.

## 경계·주의

- hermes는 자체 메모리(MEMORY.md·USER.md)를 가짐 — claude-memory와 자동 동기화하지 않음(이중 기록 방지). 2026-08-19 부분 해소: 지속 지침의 공통 착지점은 Vault `10_컨텍스트`(portable-rules "공통 지침 착지점" 절), 로컬 메모리는 캐시/보조. Vault→hermes 전달은 `claude-config:vault-context` 인덱스 블록이 담당
- hermes 쪽에서 규칙을 직접 수정하지 말 것 — 마커 블록은 다음 sync에서 덮어써짐. 규칙 변경은 claude-config의 `portable-rules.md`에서
- 코덱스도 동일 — `~/.codex/AGENTS.md` 마커 블록 안을 직접 고치지 말 것. 규칙 변경은 `portable-rules.md`/`codex-vault-rules.md`에서
- PII·시크릿은 어느 쪽 설정·프롬프트에도 넣지 않음 (PUBLIC 레포 규칙)
