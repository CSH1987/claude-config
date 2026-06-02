# dotfiles — Claude Code Harness 자동 적용

이 머신과 **앞으로의 모든 새 머신**에서 Claude Code(CLI)에 Harness 플러그인이
자동으로 설치·복구되도록 하는 설정 모음.

---

## 🚀 새 머신 셋업 — 이 한 줄만 (복붙, 지식 불필요)

> 이 명령은 자체완결입니다. 무엇을 하는지 몰라도 그대로 붙여넣으면 됩니다.

**GitHub CLI(`gh`)가 있고 로그인돼 있을 때 (권장):**

```bash
gh repo clone CSH1987/dotfiles ~/dotfiles && bash ~/dotfiles/install.sh
```

**`gh`가 없을 때 (git만 있을 때):**

```bash
git clone https://github.com/CSH1987/dotfiles.git ~/dotfiles && bash ~/dotfiles/install.sh
```

> 비공개 저장소라 git 방식은 GitHub 로그인(자격증명)이 필요합니다.
> 새 머신이면 먼저 `gh auth login` 한 번 하면 위 두 방식 모두 동작합니다.

이미 받아둔 머신에서 최신 설정으로 갱신:

```bash
git -C ~/dotfiles pull && bash ~/dotfiles/install.sh
```

---

## 작동 방식 (왜 한 번만 하면 끝인가)

1. `install.sh`가 `claude/settings.json`과 `claude/hooks/ensure-harness.sh`를
   `~/.claude/`에 **심볼릭 링크**로 걸고, 즉시 Harness를 설치합니다.
2. 이후 그 머신에서 **새 세션이 시작될 때마다** `ensure-harness.sh` 훅이 돌면서:
   - Harness가 있으면 → 그냥 통과
   - 없으면(삭제·업데이트로 사라졌으면) → **자동 재설치**

→ 머신당 위 한 줄을 **딱 한 번** 실행하면, 그 뒤로는 아무것도 안 해도 영구 유지됩니다.

## "완전 무동작"에 가장 가까운 경로 (Mac)

- **Migration Assistant / 백업 복원**으로 새 Mac을 셋업하면 `~/dotfiles`와
  `~/.claude`(링크 + 훅)가 그대로 복사돼 → **추가 동작 0**으로 즉시 동작합니다.
- 새로 깨끗이 설치하는 경우에만 위 부트스트랩 한 줄이 필요합니다.

## 구성

```
dotfiles/
├── install.sh                      # 부트스트랩 — 링크 + 즉시 설치
└── claude/
    ├── settings.json               # 훅·플러그인·마켓플레이스 설정
    └── hooks/
        └── ensure-harness.sh       # SessionStart 훅 — 자동 설치/복구
```
