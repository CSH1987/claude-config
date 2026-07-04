#!/usr/bin/env bash
# claude-config:vaultdir — Obsidian 볼트 경로 단일 resolver (memdir 와 동형).
#   모든 hook·skill 은 볼트 경로를 하드코딩하지 말고 이 헬퍼만 호출한다(단일 진실원).
#   해석: CLAUDE_OBSIDIAN_VAULT(env) > 폴백 $HOME/obsidian-vault.
#   파생: CLAUDE_OBSIDIAN_CLAUDE_DIR=<vault>/Claude  — Claude 산출물은 이 하위에만 쓴다(사용자 노트 불가침).
# 모드: --strict(미설정 시 폴백 없이 exit 1) · --no-ensure(생성 없이 해석만) · --export(eval 가능 출력).
# 개인정보: 볼트는 PRIVATE(개인 노트) — PUBLIC claude-config 레포엔 볼트 내용을 절대 두지 않는다(경로만 다룸).
set -uo pipefail

strict=0; ensure=1; export_mode=0
for arg in "$@"; do
  case "$arg" in
    --strict)    strict=1 ;;
    --no-ensure) ensure=0 ;;
    --export)    export_mode=1 ;;
    *) ;;
  esac
done

vault="${CLAUDE_OBSIDIAN_VAULT:-}"
if [ -z "$vault" ]; then
  if [ "$strict" = "1" ]; then
    echo "vaultdir: CLAUDE_OBSIDIAN_VAULT 미설정 (strict) — 폴백 금지. 실패." >&2
    exit 1
  fi
  vault="$HOME/obsidian-vault"
fi
claudedir="$vault/Claude"

if [ "$ensure" = "1" ]; then
  mkdir -p "$claudedir" 2>/dev/null || true
fi

if [ "$export_mode" = "1" ]; then
  printf 'export CLAUDE_OBSIDIAN_VAULT=%q\n' "$vault"
  printf 'export CLAUDE_OBSIDIAN_CLAUDE_DIR=%q\n' "$claudedir"
else
  printf '%s\n' "$vault"
fi
exit 0
