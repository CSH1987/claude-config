#!/usr/bin/env bash
# claude-config:memdir — 평생 성장형 기억저장소(canonical memory store)의 단일 경로 resolver.
#   모든 hook·skill 은 경로를 하드코딩하지 말고 이 헬퍼만 호출한다(단일 진실원 = single source of truth).
#   해석: CLAUDE_MEMORY_DIR(env) > 폴백 $HOME/claude-memory.   파생: OMC_STATE_DIR=<memdir>/omc-state.
#   기본은 정본 디렉터리(profile/ decisions/ omc-state/)를 멱등 생성한다.
# 사용:
#   eval "$(bash ~/.claude/lib/memdir.sh --export)"   # CLAUDE_MEMORY_DIR·OMC_STATE_DIR 를 환경에 주입
#   bash ~/.claude/lib/memdir.sh                       # 해석된 memdir 경로 한 줄 출력
# 모드(결정 D1):
#   --strict     : CLAUDE_MEMORY_DIR 미설정이면 폴백하지 않고 즉시 실패(exit 1).
#                  헤드리스/스케줄러/클라우드 등 무인 컨텍스트에서 머신 간 정본 발산($HOME 상이)을 막는다.
#   --no-ensure  : 디렉터리 생성 없이 해석만(읽기전용 호출자용).
#   --export     : eval 가능한 'export K=V' 두 줄 출력.
# 개인정보: memdir 는 PRIVATE(로컬 비공개) — profile·decisions 는 개인 학습데이터다.
#            절대 PUBLIC claude-config 레포에 두지 않는다(이 리졸버는 경로만 다루며 데이터를 담지 않음).
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

memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  if [ "$strict" = "1" ]; then
    echo "memdir: CLAUDE_MEMORY_DIR 미설정 (strict) — 무인 컨텍스트 폴백 금지. 실패." >&2
    exit 1
  fi
  memdir="$HOME/claude-memory"
  echo "memdir: CLAUDE_MEMORY_DIR 미설정 → 폴백 $memdir (영구설정 권장)." >&2
fi

omc_state="$memdir/omc-state"

if [ "$ensure" = "1" ]; then
  mkdir -p "$memdir/profile" "$memdir/decisions" "$omc_state" 2>/dev/null || true
fi

if [ "$export_mode" = "1" ]; then
  printf 'export CLAUDE_MEMORY_DIR=%q\n' "$memdir"
  printf 'export OMC_STATE_DIR=%q\n' "$omc_state"
else
  printf '%s\n' "$memdir"
fi
exit 0
