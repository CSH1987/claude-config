# dotfiles — Claude Code 기본값 자동 적용 (Harness + 최고 강도)

이 머신과 **앞으로의 모든 새 머신(Mac · Windows · Linux)**에서 Claude Code(CLI)에:
- **Harness 플러그인** 자동 설치·복구
- **effortLevel=xhigh** 영구 적용 (최고 강도 추론)
- **`claude` 명령을 ultracode 로 자동 실행** (셸 함수 오버라이드) + ultracode/ultraplan 리마인더

가 자동으로 적용되도록 하는 설정 모음.

> **왜 해야 하나?** 이걸 한 번 안 하면 그 머신의 Claude Code에는 위 기본값이 없습니다.
> 아래 명령을 **`claude`를 본격적으로 쓰기 전에 먼저** 한 번 실행하면, 그 뒤로는
> 새 세션마다 자동으로 유지됩니다.

---

## 0. 사전 준비 (새 머신 공통, 한 번만)

- **Claude Code CLI** 설치되어 있어야 함
- 저장소가 **비공개**라 GitHub 로그인 필요 → 새 머신이면 먼저:
  ```bash
  gh auth login
  ```
  (`gh`가 없으면 git 자격증명으로 로그인해도 됩니다.)

---

## 1. 새 머신 셋업 — OS별 한 줄 (복붙, 지식 불필요)

### 🍎 macOS / 🐧 Linux  (터미널)
```bash
gh repo clone CSH1987/dotfiles ~/dotfiles && bash ~/dotfiles/install.sh
```
`gh` 없이 git만:
```bash
git clone https://github.com/CSH1987/dotfiles.git ~/dotfiles && bash ~/dotfiles/install.sh
```

### 🪟 Windows 11  (PowerShell)
```powershell
gh repo clone CSH1987/dotfiles "$env:USERPROFILE\dotfiles"; powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\dotfiles\install.ps1"
```
`gh` 없이 git만:
```powershell
git clone https://github.com/CSH1987/dotfiles.git "$env:USERPROFILE\dotfiles"; powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\dotfiles\install.ps1"
```

### 이미 받아둔 머신 — 최신 설정으로 갱신
```bash
# Mac/Linux
git -C ~/dotfiles pull && bash ~/dotfiles/install.sh
```
```powershell
# Windows
git -C "$env:USERPROFILE\dotfiles" pull; powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\dotfiles\install.ps1"
```

---

## 2. 작동 방식 (왜 한 번만 하면 끝인가)

1. 설치 스크립트가 `claude/settings.json`의 설정과 훅을 `~/.claude/`에 적용하고
   즉시 Harness를 설치합니다. (Mac/Linux는 심볼릭 링크, Windows는 복사+머지)
2. 이후 그 머신에서 **새 세션이 시작될 때마다** `ensure-harness` 훅이 돌면서:
   - Harness가 있으면 → 그냥 통과
   - 없으면(삭제·업데이트로 사라졌으면) → **자동 재설치**

→ 머신당 위 한 줄을 **딱 한 번** 실행하면, 그 뒤로는 아무것도 안 해도 영구 유지됩니다.

## 3. "완전 무동작"에 가장 가까운 경로 (Mac)

- **Migration Assistant / 백업 복원**으로 새 Mac을 셋업하면 `~/dotfiles`와
  `~/.claude`(링크 + 훅)가 그대로 복사돼 → **추가 동작 0**으로 즉시 동작합니다.
- 새로 깨끗이 설치하거나 Windows인 경우에만 위 부트스트랩 한 줄이 필요합니다.

## 4. 작업 강도(effort) 기본값 — 정직한 한계

- **영구 적용**: `effortLevel: "xhigh"` 가 settings.json 으로 설정돼 매 세션 자동 xhigh 추론. (Opus 4.7/4.8·Fable 5 필요; 미지원 모델에선 클램프)
- **영구화 불가(Claude Code 설계)**: ultracode 의 *동적 워크플로 오케스트레이션* 과 ultraplan 은 **세션 전용**. settings.json·환경변수·훅으로 영구화할 수 없음. (`/effort` 또는 실행 시 `--settings`로만 세션 단위 적용)
- **그래서 자동화 방식**:
  1. 설치 시 셸 프로파일에 `claude` 함수를 심어 `claude --settings ~/.claude/ultracode.json` 으로 실행 → **새 터미널의 모든 `claude` 세션이 ultracode 로 시작**.
  2. `~/.claude/CLAUDE.md` + `effort-reminder` 훅이 매 세션 Claude 에게 상태를 주입 → 혹시 ultracode 가 아니면 능동적으로 `/effort ultracode` 를 제안(사용자가 잊어도 챙김).
- 끄고 싶은 세션: `claude` 대신 `command claude`(bash) / `& (Get-Command claude.cmd).Source`(PS) 로 직접 실행하거나 세션 중 `/effort high`.

## 구성

```
dotfiles/
├── install.sh                      # Mac/Linux 부트스트랩 (링크 + 즉시 설치)
├── install.ps1                     # Windows 부트스트랩 (복사+머지 + 즉시 설치)
└── claude/
    ├── settings.json               # 훅·플러그인·마켓플레이스 + effortLevel:xhigh
    ├── CLAUDE.md                    # 전역 세션 기본값(ultracode/ultraplan 넛지) → ~/.claude/CLAUDE.md
    ├── ultracode.json              # {"ultracode":true} — claude --settings 로 주입
    ├── shell/
    │   ├── claude-ultra.sh          # `claude` 오버라이드 함수 (bash/zsh)
    │   └── claude-ultra.ps1         # `claude` 오버라이드 함수 (PowerShell)
    └── hooks/
        ├── ensure-harness.sh/.ps1   # SessionStart — harness 자동 설치/복구
        └── effort-reminder.sh/.ps1  # SessionStart — 매 세션 ultracode/ultraplan 리마인더 주입
```
