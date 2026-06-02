# dotfiles — Claude Code Harness 자동 적용

이 머신과 **앞으로의 모든 새 머신(Mac · Windows · Linux)**에서 Claude Code(CLI)에
Harness 플러그인이 자동으로 설치·복구되도록 하는 설정 모음.

> **왜 해야 하나?** 이걸 한 번 안 하면 그 머신의 Claude Code에는 Harness가 없습니다.
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

## 구성

```
dotfiles/
├── install.sh                      # Mac/Linux 부트스트랩 (링크 + 즉시 설치)
├── install.ps1                     # Windows 부트스트랩 (복사+머지 + 즉시 설치)
└── claude/
    ├── settings.json               # 훅·플러그인·마켓플레이스 설정
    └── hooks/
        ├── ensure-harness.sh       # SessionStart 훅 (Mac/Linux) — 자동 설치/복구
        └── ensure-harness.ps1      # SessionStart 훅 (Windows)  — 자동 설치/복구
```
