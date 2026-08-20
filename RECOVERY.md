<!-- PUBLIC FILE. 실명·이메일·토큰·개인경로 금지(placeholder만). 누구나 읽는 1페이지 안내. -->

# 🆘 이게 다 뭐예요? — 1페이지 안내 (다 잊어버려도 OK)

> 이 한 장만 읽으면 됩니다. 어려운 말은 없습니다. 천천히 위에서 아래로.

---

## 1. 이 PC가 당신을 위해 *자동으로* 하는 일 (외울 필요 없음)

- 🧠 **공통 원칙을 기억해요.** Obsidian Vault의 `10_컨텍스트`가 연결된 AI 시스템의 공통 정본이고,
  private GitHub에 백업됩니다. 각 앱의 세션 기록·로컬 캐시는 여전히 장치 안에만 남을 수 있습니다.
- 🔄 **최신으로 맞춰요.** 새 터미널을 열 때마다 설정을 알아서 최신화합니다.
- ☁️ **설정과 Vault를 분리 백업해요.** 설정·규칙·도구는 공개 `claude-config`, 개인 노트·공통 패턴은
  private Vault 저장소에 저장됩니다. 토큰·API 키는 어느 공개 저장소에도 넣지 않고 장치별로 로그인합니다.

→ 그래서 설정과 공통 패턴은 복구할 수 있습니다. 단 각 앱의 로그인과 장치 전용 플러그인 권한은
  새 장치에서 한 번 다시 승인해야 합니다.

---

## 2. 다 잃어버렸을 때 (새 PC·포맷·"이게 뭐였지?")

**터미널에 아래 한 줄**만 붙여넣으면 전부 되살아납니다. 그게 전부예요.

- 🍎 **Mac / 🐧 Linux — private Vault까지 통합 복구**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/<gh_handle>/claude-config/main/online-bootstrap.sh | bash
  ```
- 🪟 **Windows — Claude 설정 기본 복구** (PowerShell; private Vault 통합은 후속 수동)
  ```powershell
  irm https://raw.githubusercontent.com/<gh_handle>/claude-config/main/bootstrap.ps1 | iex
  ```

> `<gh_handle>` = 당신의 GitHub 사용자명. GitHub/Claude/Codex/Hermes 로그인 화면이 나오면 해당 공식 화면에서 완료하세요. 끝나면 **새 터미널**을 엽니다.

> Obsidian 첫 실행에서는 community plugins를 직접 신뢰/활성화해야 합니다. Local REST API 키와 Claude MCP Authorization 헤더도 장치별 비밀이라 자동 복사하지 않습니다. 현재는 private GitHub가 동기화 transport이며, Obsidian native Sync를 추가할 때는 Git 양방향 동기화를 함께 켜지 않습니다.

---

## 3. 막히면 — Claude에게 *이렇게* 물어보세요 (복붙해도 됨)

말로 물어보면 Claude가 알아서 찾아줍니다. 명령어 외울 필요 없어요.

- 💬 "내 설정·선호가 뭐였는지 알려줘"
- 💬 "지난 결정들 보여줘" (또는 "내가 전에 뭐라고 정했지?")
- 💬 "내 기억(메모리)이 백업되는지, 이 PC를 잃으면 어떻게 되는지 확인해줘"
- 💬 "이 시스템이 어떻게 작동하는지 1분만에 설명해줘"
- 💬 "오늘 내가 뭐부터 하면 좋을지 브리핑해줘"

---

## 4. 어디에 뭐가 있나 (한눈에)

| 무엇 | 어디 | 공개? | 백업? |
|---|---|---|---|
| **설정·규칙·도구** (남에게 줘도 되는 것) | `claude-config` (GitHub 공개 레포) | 🌍 공개 | ☁️ 자동 |
| **공통 패턴·원칙·업무 노트** | Obsidian Vault `10_컨텍스트` 등 + private GitHub | 🔒 비공개 | ☁️ Git 백업 |
| **앱별 세션·로컬 캐시** | 각 장치의 Claude/Codex/Hermes 로컬 데이터 | 🔒 비공개 | ⚠️ 앱별로 다름 |

> 원칙: **개인정보는 절대 공개로 안 나갑니다.** 규칙·도구만 공개됩니다.

---

## 5. 켜고 끄기 (필요할 때만)

- 끄기(잠깐 조용히): 환경변수 `CLAUDE_EVENTS_OFF=1` → 재작업 감지 등 자동 기록 멈춤.
- 다시 켜기: 그 변수를 지우고 새 터미널.
- 전체 갱신: 새 터미널에서 §2의 한 줄을 다시 실행.

---

## 6. 더 알고 싶으면
- 설치·동작 자세히 → [README.md](./README.md)
- 새 머신 셋업 차이 → [SETUP-NOTE.md](./SETUP-NOTE.md)
- 일 잘하는 법(작업 플레이북) → [claude/playbooks/](./claude/playbooks/README.md) — "리서치/검토/결정 플레이북대로 해줘"
- 막히면 → 그냥 Claude에게 한국어로 물어보세요. 그게 가장 빠릅니다.

> 🌱 **기억하세요(이거 하나만): 다 잊어도, §2의 한 줄이면 돌아옵니다.**
