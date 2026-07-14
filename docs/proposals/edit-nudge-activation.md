# 활성화 절차 (US-004) — 실행 전 사용자 확인 대기

**이 파일은 제안일 뿐입니다. 아래 4곳은 아직 하나도 반영되지 않았습니다** — 지금 상태로는
`edit-nudge.sh`/`.ps1`가 파일로만 존재하고 어떤 세션에서도 실행되지 않습니다(안전).
사용자가 검토 후 승인하면 이 문서대로 4곳을 수정 + 배포(`config-sync`/재설치)하면 됩니다.

## 왜 4곳인가
CLAUDE.md 자체에 이미 기록된 규칙: "훅 1개 추가 시 4곳(claude/settings.json, install.sh ln+chmod,
install.ps1 복사목록, install.ps1 managedHooks+managedRe) 동시 수정 필요".

## ① `claude/settings.json` — hooks.PostToolUse 배열에 추가

**현재:**
```json
"PostToolUse": [
  {
    "hooks": [
      { "type": "command", "command": "bash \"$HOME/.claude/hooks/edit-track.sh\"" }
    ]
  }
]
```

**추가 후:**
```json
"PostToolUse": [
  {
    "hooks": [
      { "type": "command", "command": "bash \"$HOME/.claude/hooks/edit-track.sh\"" }
    ]
  },
  {
    "hooks": [
      { "type": "command", "command": "bash \"$HOME/.claude/hooks/edit-nudge.sh\"" }
    ]
  }
]
```

## ② `install.sh` — 심링크 + 실행권한 (맥)

179번째 줄 근처(`ln -sfn ... edit-track.sh` 다음 줄에 추가):
```bash
ln -sfn "$REPO_DIR/claude/hooks/edit-nudge.sh" "$DST/hooks/edit-nudge.sh"
```

183번째 줄(`chmod +x` 목록)에 `edit-nudge.sh` 추가:
```bash
chmod +x "$REPO_DIR/claude/hooks/... edit-track.sh" "$REPO_DIR/claude/hooks/edit-nudge.sh" "..."
```

185번째 줄 안내 문구에도 `edit-nudge` 추가.

## ③ `install.ps1` — 복사 목록 (윈도우)

26번째 줄 근처(`Copy-Item ... edit-track.ps1 ...` 다음 줄에 추가):
```powershell
Copy-Item (Join-Path $repoDir 'claude\hooks\edit-nudge.ps1') (Join-Path $hooks 'edit-nudge.ps1') -Force
```

32번째 줄 안내 문구에도 `edit-nudge` 추가.

## ④ `install.ps1` — managedHooks + managedRe (윈도우 훅 등록/자가치유)

307번째 줄 근처(`PostToolUse = @(...)` 배열에 추가):
```powershell
PostToolUse = @(
    (New-PsHook 'edit-track.ps1'      ''),
    (New-PsHook 'edit-nudge.ps1'      '')
)
```

326번째 줄(`$managedRe` 정규식) — 훅 파일명 목록에 `edit-nudge` 추가:
```
...guardrails|edit-track|edit-nudge|stop-metrics|filter-test-output|hermes-sync)\.(ps1|sh)\b
```

## 반영 후 필요한 것
- 맥: `config-sync.sh` 가 다음 세션 시작 시 자동 배포(심링크라 즉시 반영도 가능)
- 윈도우: 다음 `config-sync.ps1`/재설치 실행 시 반영

## 되돌리는 법(비활성화/롤백)
- **즉시 끄기(재배포 없이)**: 어느 머신에서든 환경변수 `EDIT_NUDGE_OFF=1` 설정 — 이 훅만 즉시 무력화(다른 훅엔 영향 없음)
- **완전 롤백**: 위 4곳 diff를 되돌리고(git revert 또는 수동 원복) 재배포. 훅 자체 파일(`edit-nudge.sh`/`.ps1`)은 안 지워도 무해함(설정에서 안 불리면 그냥 존재만 함)
- **상태 파일 정리**(선택): `$OMC_STATE_DIR/edit-nudge/` 디렉터리 삭제 — 커밋 안 되는 gitignore 라이브 상태라 지워도 다음 실행에서 자동 재생성됨
