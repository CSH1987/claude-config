# Hermes Agent 연동 가이드 — claude-config 규칙 자동 적용

대상: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). 이 문서는 hermes 설치 **전에** 준비된 것으로, 설치 즉시 규칙이 자동 적용되도록 하는 체계와 내일 작업 체크리스트를 담는다.

## 자동 적용 체계 (이미 준비 완료)

| 구성요소 | 위치 | 역할 |
|---|---|---|
| `portable-rules.md` | `claude/exports/` (배포: `~/.claude/exports/`) | CLAUDE.md 핵심 규칙의 플랫폼 중립 증류판 |
| `hermes-sync.ps1` / `.sh` | `claude/hooks/` (배포: `~/.claude/hooks/`) | hermes 감지 시 규칙·스킬 자동 주입 (미설치 시 무동작) |
| SessionStart 훅 등록 | `settings.json` | 매 Claude Code 세션 시작 시 hermes-sync 실행 → hermes 설치 후 **추가 조치 없이** 자동 적용 |

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
5. **옵시디언**: hermes에 네이티브 통합은 없음 — 볼트가 로컬 마크다운이므로 hermes 파일 도구로 접근 가능. 볼트 경로를 AGENTS.md의 hermes 자체 영역(마커 블록 밖)에 기재하거나 workspace로 지정
6. **페르소나(SOUL.md)**: portable-rules는 작업 규칙만 담음 — 말투·성격은 SOUL.md에서 별도 관리 (자동 주입 안 함, 의도적)
7. **성장형 운영**: hermes MEMORY.md·skills가 성장 축 — 잘 통하는 패턴은 claude-config 쪽 플레이북과 상호 이식(retro→promote 흐름과 동일 원리)

## 경계·주의

- hermes는 자체 메모리(MEMORY.md·USER.md)를 가짐 — claude-memory와 자동 동기화하지 않음(이중 기록 방지, 필요 시 별도 설계)
- hermes 쪽에서 규칙을 직접 수정하지 말 것 — 마커 블록은 다음 sync에서 덮어써짐. 규칙 변경은 claude-config의 `portable-rules.md`에서
- PII·시크릿은 어느 쪽 설정·프롬프트에도 넣지 않음 (PUBLIC 레포 규칙)
