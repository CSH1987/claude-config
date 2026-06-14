# SETUP-NOTE — 셸별 적용 / Git Bash 보충 메모 (Windows)

> README의 "한 줄" 보충판. **셸(PowerShell vs Git Bash)에 따라 무엇이 달라지는지**와
> 새 PC에서 자주 겪는 실패 케이스를 정리한 메모. 복붙해서 그대로 쓰면 됨.

리포: <https://github.com/CSH1987/claude-config> (public)

---

## 왜 `git -C ~/claude-config pull && install` 이 새 PC에서 실패하나

- 그 명령은 **리포가 이미 clone된 PC를 "갱신"** 하는 명령이다.
- 새 PC엔 `~/claude-config` 폴더 자체가 없어서 `git pull` 이 바로 실패한다.
- 또 `install` 은 단독 명령이 아니라 리포 안의 스크립트(`install.ps1`/`install.sh`)다.
- → 새 PC에선 **clone부터 하는 부트스트랩**을 써야 한다 (아래).

---

## 핵심: 설치 내용은 2부분 (하나만 셸을 탄다)

| 부분 | 위치 | 셸 의존성 |
|---|---|---|
| payload — xhigh · 플러그인 12종 · 훅 · CLAUDE.md · ultracode.json | `~/.claude/` (모든 셸 공용) | **없음** — 한 번 깔면 어느 셸에서 `claude` 켜든 적용 |
| `claude` → ultracode **자동 실행 래퍼** | PowerShell 프로필 **또는** `.bashrc` | **있음** — 셸별로 따로 심긴다 |

즉 무거운 건 전부 공용이고, **셸을 타는 건 "자동 ultracode 래퍼" 하나뿐**이다.
"공용 한 줄"은 셸 문법이 달라(`irm|iex` = PS 전용, `curl|bash` = bash 전용) 존재하지 않는다.
대신 아래 중 **어디서 `claude` 를 켤지**에 맞춰 고르면 된다.

---

## 방법 1 — Git Bash에서 계속 작업할 때 (bash 네이티브) ✅ 추천

```bash
curl -fsSL https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.sh | bash
```

- `.bashrc` 에 래퍼를 심어 **Git Bash 안에서 `claude` → ultracode 자동** + `gh` 토큰 자동 주입.
- **전제**: Windows의 Git Bash엔 apt/brew가 없어 **git/gh/node 가 이미 깔려 있어야** 한다.
  없으면 PowerShell에서 한 번:
  ```powershell
  winget install OpenJS.NodeJS.LTS GitHub.cli
  ```
- `install.sh` 의 `ln -sfn` 은 Git Bash에선 **복사로 폴백**된다(동작 OK, pull 자동반영만 안 됨).

## 방법 2 — 어느 셸에서든 되는 "진짜 공용" (PowerShell에 위임)

Git Bash·cmd·PowerShell 어디서 쳐도 동작 (PowerShell이 무거운 일을 다 한다):

```bash
powershell -NoProfile -Command "irm https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.ps1 | iex"
```

- winget로 git/gh/node **자동 설치** + 복사 기반 install → 제일 견고.
- 단, 래퍼는 **PowerShell 창**에 심긴다 → 끝나면 `claude` 는 PowerShell에서 켜기.
- 혹시 URL이 깨지면 맨 앞에 `MSYS_NO_PATHCONV=1 ` 를 붙인다.

PowerShell 창에서 직접 칠 거면 이 한 줄 (README의 기본):
```powershell
irm https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.ps1 | iex
```

## 방법 3 — 양쪽 셸 다 자동 ultracode를 원할 때 (clone 후 둘 다 실행)

```bash
bash ~/claude-config/install.sh
powershell -NoProfile -ExecutionPolicy Bypass -File ~/claude-config/install.ps1
```
payload는 멱등·공용이라 둘 다 돌려도 충돌 없음. 래퍼만 각 셸에 1개씩 심긴다.

---

## 공통 주의

- **Claude Code CLI 자체**는 부트스트랩이 설치 안 함. 없으면 먼저:
  ```
  npm i -g @anthropic-ai/claude-code
  ```
- 설치 후 **새 창**을 열어야 래퍼(자동 ultracode)가 먹는다.
- github MCP 토큰: `gh auth login` 해두면 자동 사용(방법 1은 런타임 자동 주입). 토큰을 리포에 저장하지 않는다.

## 고르는 기준

- 앞으로 **Git Bash**에서 `claude` 켤 거다 → **방법 1**
- **설치 안정성** 최우선 / node 깔렸는지 모름 → **방법 2** (winget가 다 깔아줌)
- **양쪽 셸 다** → **방법 3**
