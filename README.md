# claude-config — Claude Code 기본값 자동 적용 (Harness + 최고 강도)

이 머신과 **앞으로의 모든 새 머신(Mac · Windows · Linux)**에서 Claude Code(CLI)에:
- **플러그인** 자동 설치·복구: `harness` + `oh-my-claudecode`(`/deep-interview`, `/ralph` 등)
- **effortLevel=xhigh** 영구 적용 (최고 강도 추론)
- **`claude` 명령을 ultracode 로 자동 실행** (셸 함수 오버라이드) + ultracode/ultraplan 리마인더

가 자동으로 적용되도록 하는 설정 모음.

> **왜 해야 하나?** 이걸 한 번 안 하면 그 머신의 Claude Code에는 위 기본값이 없습니다.
> 아래 명령을 **`claude`를 본격적으로 쓰기 전에 먼저** 한 번 실행하면, 그 뒤로는
> 새 세션마다 자동으로 유지됩니다.

---

## 0. 사전 준비 (새 머신, 한 번만)

- **Claude Code CLI** 설치 + 로그인 (예: `npm i -g @anthropic-ai/claude-code`)
- (선택) github MCP 토큰용으로 한 번 `gh auth login` — 아래 한 줄이 `gh` 를 자동 설치하니 그 뒤 로그인만 하면 됩니다. 안 해도 나머지 설정은 그대로 적용됩니다.

> 레포는 **공개**라 clone 에 인증이 필요 없고, 아래 **한 줄**이 git·gh·node 설치까지 알아서 합니다.

---

## 1. 새 머신 셋업 — 진짜 "한 줄" (복붙, 이거 하나만 저장해 다니면 됨)

### 🍎 macOS / 🐧 Linux  (터미널)
```bash
curl -fsSL https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.sh | bash
```

### 🪟 Windows 11  (PowerShell)
```powershell
irm https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.ps1 | iex
```

→ 이 한 줄이: 누락된 **git·gh·node 설치** → 레포 **clone** → **install** 까지 전부. 끝나면 **새 터미널**을 열고 `claude`.

> 🪟 **Windows에서 Git Bash를 쓰거나 셸별 차이가 궁금하면** → [SETUP-NOTE.md](./SETUP-NOTE.md)
> (PowerShell vs Git Bash, "공용 한 줄"이 없는 이유, 새 PC 실패 케이스 정리).

<details><summary>수동(저수준) 방식 — 도구가 이미 다 깔려 있을 때</summary>

```bash
# macOS / Linux
git clone https://github.com/CSH1987/claude-config.git ~/claude-config && bash ~/claude-config/install.sh
```
```powershell
# Windows
git clone https://github.com/CSH1987/claude-config.git "$env:USERPROFILE\claude-config"; powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\claude-config\install.ps1"
```
</details>

### 이미 받아둔 머신 — 최신 설정으로 갱신
```bash
# Mac/Linux
git -C ~/claude-config pull && bash ~/claude-config/install.sh
```
```powershell
# Windows
git -C "$env:USERPROFILE\claude-config" pull; powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\claude-config\install.ps1"
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

- **Migration Assistant / 백업 복원**으로 새 Mac을 셋업하면 `~/claude-config`와
  `~/.claude`(링크 + 훅)가 그대로 복사돼 → **추가 동작 0**으로 즉시 동작합니다.
- 새로 깨끗이 설치하거나 Windows인 경우에만 위 부트스트랩 한 줄이 필요합니다.

## 4. 작업 강도(effort) 기본값 — 정직한 한계

- **영구 적용**: `effortLevel: "xhigh"` 가 settings.json 으로 설정돼 매 세션 자동 xhigh 추론. (Opus 4.7/4.8·Fable 5 필요; 미지원 모델에선 클램프)
- **영구화 불가(Claude Code 설계)**: ultracode 의 *동적 워크플로 오케스트레이션* 과 ultraplan 은 **세션 전용**. settings.json·환경변수·훅으로 영구화할 수 없음. (`/effort` 또는 실행 시 `--settings`로만 세션 단위 적용)
- **그래서 자동화 방식**:
  1. 설치 시 셸 프로파일에 `claude` 함수를 심어 `claude --settings ~/.claude/ultracode.json` 으로 실행 → **새 터미널의 모든 `claude` 세션이 ultracode 로 시작**.
  2. `~/.claude/CLAUDE.md` + `effort-reminder` 훅이 매 세션 Claude 에게 상태를 주입 → 혹시 ultracode 가 아니면 능동적으로 `/effort ultracode` 를 제안(사용자가 잊어도 챙김).
- 끄고 싶은 세션: `claude` 대신 `command claude`(bash) / `& (Get-Command claude.cmd).Source`(PS) 로 직접 실행하거나 세션 중 `/effort high`.

## 5. 설정 자동 동기화 (클라우드 백업) — "깜빡해도 항상 최신"

로컬에만 쌓여 드리프트되는 문제를 없애기 위해, `config-sync` 훅이 이 레포를 GitHub 와 자동 동기화합니다(설정-전용).

- **SessionStart → `git pull` + (변경 시) 자동 반영**: 매 세션 시작 시 다른 머신의 변경을 자동 수신하고, **새 커밋이 당겨졌으면 `deploy-only` install 을 자동 실행해 `~/.claude` 에 반영**(settings·CLAUDE.md·hooks·ultracode.json). 적용은 **다음 세션부터**(settings·CLAUDE.md 는 세션 시작 시 로드). 느린 네트워크엔 `git lowSpeed`(20초)+ (Unix)`timeout` 으로 세션시작 행 방지. → **다른 머신·새 사용자도 한 번 부트스트랩만 하면 이후 세션마다 알아서 최신.**
- **SessionEnd → commit + push**: 변경분이 있으면 `auto-sync: <host> <시각>` 으로 커밋·푸시.
- **세션을 절대 막지 않음**: git 미설치·오프라인·충돌 시 조용히 스킵(충돌은 rebase abort). 끄려면 `CLAUDE_CONFIG_NO_SYNC=1`.
- **안전**: 비밀은 레포에 없고(`gh auth token` 런타임 주입) `.omc/` 는 gitignore 라 `git add -A` 가 안전.
- 훅으로 구현해 `claude` 래퍼가 안 걸리는 셸(pwsh·zsh 미설정 등)에서도 **항상 동작**합니다.

> **플랫폼 차이**: Mac/Linux 는 `~/.claude/*` 가 레포로 **심링크**라 `/config` 등 실시간 편집까지 자동 동기화됩니다.
> Windows 는 **복사본**이라 레포 자체 편집은 동기화되지만, `~/.claude` 실시간 편집은 `install.ps1` 재실행으로 반영하세요
> (머신별 절대경로가 박힌 `settings.json` 은 의도적으로 올리지 않습니다).

> **⚠️ 보안 모델 (자동 실행 — 꼭 이해하세요)**: 위 "변경 시 자동 반영"은 **공개 레포(`CSH1987/claude-config`)의 코드를 매 세션 자동으로 pull·실행**한다는 뜻입니다. 즉 **보안 경계 = 당신의 GitHub 계정**입니다. `main` 에 악성 커밋이 들어가면(계정 탈취·토큰 유출 등) 동기화된 **모든 머신**에서 다음 세션에 그 코드가 실행됩니다. 완화: **① GitHub 계정 2FA 필수, ② 레포에 토큰·비밀 절대 커밋 금지(이미 `gh auth token` 런타임 주입), ③ `main` 브랜치 보호 권장.** dotfiles 류의 일반적·수용 가능한 패턴이지만 **의식적으로 수용한 위험**이어야 합니다. 더 엄격히 하려면 `CLAUDE_CONFIG_VERIFY_COMMIT=1` 같은 서명 검증 게이팅(옵트인 — 모든 커밋 GPG 서명 필요)을 추가할 수 있습니다.

### install 이 머신에 바꾸는 것
- **Windows**: `~/.pyshim` 생성 후 USER PATH 앞에 추가(hookify 의 python3), ExecutionPolicy(CurrentUser)를 필요시 `RemoteSigned` 로, `claude` 오버라이드를 Windows PowerShell 5.1 + (있으면) pwsh 7 프로필 양쪽에 기록.
- **공통**: `claude` 실행 시 `gh auth token` 으로 `GITHUB_PERSONAL_ACCESS_TOKEN` 을 런타임 주입(github MCP). 레포에 토큰 저장 안 함.

## 6. 작업물(프로젝트) 클라우드 백업 — `claude-newproj` + 자동 동기화

config 레포(설정)는 config-sync 가 늘 동기화하지만, **실제 작업 프로젝트**는 포맷·PC 고장 시 날아갈 수 있습니다. 그래서:

- **`claude-newproj [이름]`** (bash/PowerShell 함수 — 새 터미널에서 사용): 현재 폴더를 한 번에 **비공개 GitHub 레포**로 만들어 처음부터 클라우드 백업.
  - `git init` + **시크릿-안전 `.gitignore` 자동 보강**(`.env`·키·토큰류; `.env.example` 등 템플릿은 보존) + `gh repo create --private --push` + `.claude-autosync` 마커 생성.
- **`.claude-autosync` 마커가 있는 프로젝트**는 이후 **세션 종료마다 자동 커밋·푸시**(work-autosync 훅; SessionStart=pull / SessionEnd=push). **옵트인**이라 마커 없는 폴더는 절대 안 건드립니다.
- **시크릿 보호(fail-closed)**: 커밋 직전 `.env`·`id_rsa`·`*.pem`·`*credentials*.json` 등 시크릿 패턴을 **스캔해 푸시에서 제외**(경고 표시). 단 **denylist 방식의 한계**상 알려지지 않은 형식이나 이미 커밋된 비밀은 못 막으니 **무엇을 올리는지 직접 확인**하세요(절대 안전 보장 아님 — 비공개 레포 전제).
- 끄기: 마커 파일 삭제(프로젝트별) 또는 `CLAUDE_AUTOSYNC_OFF=1`(전역).

> 또한 전역 `CLAUDE.md` 에 **OMC 모드 안내(제안 후 승인)** 규칙이 있어, 모호한 요구사항엔 `/deep-interview`, 끝까지 완성·검증이 필요하면 `/ralph` 사용을 Claude 가 먼저 제안합니다(모르는 사용자도 쓰도록).

## 7. PR 자동 코드 리뷰 — `claude-review` (구독으로, 추가 과금 없음)

올린 **모든 PR**에 Claude 가 자동으로 코드 리뷰 코멘트를 남깁니다. **GitHub Action** 방식이라 한 번 설치하면 세션·로컬·내 PC 와 무관하게 **서버에서 항상 동작**합니다(greptile 같은 봇과 동일한 always-on 모델, 단 같은 Claude 생태계).

- **레포당 한 번**: 리뷰할 레포 폴더에서 **`claude-review`** 실행 →
  1. 워크플로 `.github/workflows/claude-auto-review.yml` 생성·커밋·푸시,
  2. `CLAUDE_CODE_OAUTH_TOKEN` 시크릿 설정(없으면 hidden 입력으로 받아 `gh secret set`),
  3. 마지막 1회 브라우저 단계 안내(Claude GitHub App 설치: <https://github.com/apps/claude> 또는 `claude /install-github-app`).
- **토큰**: `claude setup-token`(1년) 으로 발급. **그 레포의 시크릿에만** 저장되고 **config 레포·워크플로 파일엔 절대 안 들어갑니다**(공개 레포라 필수 원칙). 다른 사용자는 각자 자기 구독 토큰을 씁니다.
- **비용**: 리뷰 호출은 **당신의 Claude 구독 사용량**에서 차감 — 별도 API 종량 과금 없음.
- **상태 확인**: `claude-review --status`(bash) / `claude-review -Status`(PowerShell).
- **끄기**: 그 레포의 워크플로 파일 삭제. 시크릿까지 지우려면 `gh secret delete CLAUDE_CODE_OAUTH_TOKEN`.

정직한 한계:
- 리뷰는 **구독 사용량 한도**를 함께 소모(PR 이 아주 많으면 영향). 토큰은 **개인 계정 묶임 + 1년 만료**(만료 시 재발급).
- **포크에서 온 PR**은 GitHub 가 보안상 시크릿을 안 넘겨 자동 리뷰가 안 됩니다(자기 브랜치 PR 은 정상).
- 리뷰는 **코멘트까지만** — 머지 결정은 사람이.
- 모델 기본값은 `claude-sonnet-4-6`(구독 절약). 더 강하게 보려면 워크플로의 `--model` 을 Opus 로 변경.
- 인증은 **`claude_code_oauth_token`** 입력 사용(구독 OAuth 전용). `anthropic_api_key` 와 혼용하면 인증 흐름이 달라 실패합니다.

> 새 머신·다른 사용자: 이 레포가 배포되면 `claude-review` 가 자동으로 포함되므로, 각자 자기 레포에서 한 번 실행하면 끝입니다(각자 자기 구독 토큰 사용).

### 자동 수정 (옵트인) — `claude-autofix` 라벨

`claude-review` 는 리뷰 워크플로와 함께 **옵트인 자동수정 워크플로**(`claude-autofix.yml`)와 `claude-autofix` 라벨도 설치합니다.

- **켜는 법**: PR 에 **`claude-autofix` 라벨**을 달면 → Claude 가 그 PR 의 "명백하고 확신하는" 결함을 **직접 고쳐 커밋**하고, 무엇을 왜 고쳤는지 요약 코멘트를 남깁니다. 확신 없는 부분은 코멘트로만 제안.
- **리뷰와 독립**: 라벨이 없으면 아무 일도 안 합니다 — 기존 자동리뷰(코멘트-only)엔 **영향 없음**.
- **무한루프 방지(2중)**: 자동수정 커밋엔 `[skip ci]` 가 붙어 리뷰를 재트리거하지 않고, 설령 트리거돼도 claude-code-action 이 "봇이 시작한 실행"을 거부합니다.
- **권한 차이**: 자동수정만 `contents: write`(코드를 직접 커밋). 리뷰는 그대로 `contents: read`.
- 끄려면 `.github/workflows/claude-autofix.yml` 삭제 또는 그냥 라벨을 달지 않기.

## 구성

```
claude-config/
├── bootstrap.sh / bootstrap.ps1    # 한 줄 진입점 (git·gh·node 설치 → clone → install)
├── install.sh                      # Mac/Linux 설치 (링크 + 머지 + 즉시 설치)
├── install.ps1                     # Windows 설치 (복사+머지 + 즉시 설치)
├── test/fresh-install.ps1          # 설치 회귀 하네스 (Windows; 80+ 체크, Git Bash 로 bash 경로도 검증)
└── claude/
    ├── settings.json               # 훅·플러그인·마켓플레이스 + effortLevel:xhigh
    ├── CLAUDE.md                    # 전역 세션 기본값(ultracode 넛지 + OMC 모드 안내) → ~/.claude/CLAUDE.md
    ├── ultracode.json              # {"ultracode":true} — claude --settings 로 주입
    ├── github/
    │   ├── claude-auto-review.yml   # PR 자동 리뷰 워크플로 템플릿 (claude-review 가 각 레포에 복사)
    │   └── claude-autofix.yml       # 옵트인 자동수정 워크플로 템플릿 (claude-autofix 라벨로 트리거)
    ├── shell/
    │   ├── claude-ultra.sh          # `claude` 오버라이드 + claude-newproj/claude-review/update/doctor (bash/zsh)
    │   └── claude-ultra.ps1         # `claude` 오버라이드 + claude-newproj/claude-review/update/doctor (PowerShell)
    └── hooks/
        ├── ensure-harness.sh/.ps1   # SessionStart — harness 자동 설치/복구
        ├── effort-reminder.sh/.ps1  # SessionStart — 매 세션 ultracode/ultraplan 리마인더 주입
        ├── effort-reminder.txt      # 위 리마인더 본문(.sh/.ps1 이 읽음)
        ├── config-sync.sh/.ps1      # SessionStart=pull / SessionEnd=push — 설정 레포 자동 동기화
        └── work-autosync.sh/.ps1    # 옵트인(.claude-autosync) 작업 프로젝트 자동 백업 (시크릿 fail-closed)
```
