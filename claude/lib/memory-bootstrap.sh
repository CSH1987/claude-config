#!/usr/bin/env bash
# claude-config:memory-bootstrap — PRIVATE 평생 기억저장소를 아직 없는 머신에 자동 연결(클론).
#   목적: 메모리 백업 + native-memory 미러 + 자가치유가 "무동작"으로 켜지게 한다. (claude-memory 가
#   그 머신에 클론돼 있지 않으면 memory-sync 가 .git 부재로 즉시 종료 → 그 머신의 성장데이터가
#   백업되지 않는 갭을 봉합.) install 과 memory-sync SessionStart 자가치유 양쪽에서 호출된다.
# 안전(PRIVATE 레포 — 유출/파괴 절대 금지):
#   · $MEM/.git 가 이미 있으면 즉시 종료 — 기존 스토어를 절대 건드리지 않는다(멱등).
#   · '이미 존재하는' 원격만 클론한다. 자동 생성은 CLAUDE_MEMORY_BOOTSTRAP_CREATE=1 옵트인일 때만
#     (머신이 실수로 잘못된/공개 레포를 만들지 않도록 기본은 clone-only).
#   · $MEM 에 스캐폴드 아닌 실데이터가 있으면 클로버하지 않고 거부(수동 정리 요구).
#   · 세션/install 을 절대 막지 않는다(fail-open, 항상 exit 0). 끄기: CLAUDE_MEMORY_NO_BOOTSTRAP=1.
# 원격 해석: CLAUDE_MEMORY_REMOTE(env 오버라이드, 테스트용) > gh 로그인 유도
#   https://github.com/<gh_login>/claude-memory.git (login = `gh api user`). 하드코딩 없음(PII 회피).
# POSIX-clean(dash/bash3.2 안전) — 바시즘 없음.
set -u
[ "${CLAUDE_MEMORY_NO_BOOTSTRAP:-}" = "1" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0

# --- memdir 해석 (resolver 단일 진실원) + Windows 경로 정규화 ---
mem="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$mem" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  if [ ! -f "$r" ]; then
    d="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
    [ -n "$d" ] && r="$d/memdir.sh"
  fi
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  mem="${CLAUDE_MEMORY_DIR:-$HOME/claude-memory}"
fi
command -v cygpath >/dev/null 2>&1 && mem="$(cygpath -u "$mem" 2>/dev/null || printf '%s' "$mem")"

# 이미 git 레포면 아무것도 안 한다(기존 스토어 불가침)
[ -d "$mem/.git" ] && exit 0

# --- 원격 URL 해석 ---
remote="${CLAUDE_MEMORY_REMOTE:-}"
if [ -z "$remote" ] && command -v gh >/dev/null 2>&1; then
  login="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$login" ] && remote="https://github.com/$login/claude-memory.git"
fi
[ -n "$remote" ] || exit 0   # PRIVATE 원격을 알 방법이 없으면 조용히 skip

export GIT_TERMINAL_PROMPT=0
if ! git ls-remote "$remote" >/dev/null 2>&1; then
  # 원격 부재/미도달: 명시 옵트인일 때만 생성, 아니면 skip(추측 생성 금지)
  if [ "${CLAUDE_MEMORY_BOOTSTRAP_CREATE:-}" = "1" ] && command -v gh >/dev/null 2>&1; then
    gh repo create claude-memory --private >/dev/null 2>&1 || exit 0
  else
    exit 0
  fi
fi

# --- 클로버 가드: $MEM 에 스캐폴드 아닌 최상위 항목이 있으면 거부 ---
if [ -e "$mem" ]; then
  extra="$(find "$mem" -mindepth 1 -maxdepth 1 \
      ! -name profile ! -name decisions ! -name omc-state \
      ! -name .gitattributes ! -name .last-brief ! -name .leakwords 2>/dev/null | head -1)"
  if [ -n "$extra" ]; then
    echo "claude-config memory-bootstrap: $mem 에 기존 데이터가 있어 자동 클론을 건너뜁니다(수동 정리 후 재시도)." >&2
    exit 0
  fi
fi

# --- 클론: 알려진 빈 스캐폴드만 제거해 clone 이 깨끗한 타겟을 갖게 한 뒤 git clone.
# clone 은 origin·upstream 을 자동 설정한다(init+fetch+checkout 의 untracked 덮어쓰기 모호성 회피).
# 클로버 가드를 이미 통과했으므로 지우는 대상은 빈 dir/시드뿐 — 실데이터는 없다.
if [ -e "$mem" ]; then
  rm -rf "$mem/profile" "$mem/decisions" "$mem/omc-state" 2>/dev/null || true
  rm -f "$mem/.gitattributes" "$mem/.last-brief" "$mem/.leakwords" 2>/dev/null || true
  rmdir "$mem" 2>/dev/null || true   # 빈 경우에만 제거 → clone 이 새로 생성. 남아있으면 clone 이 안전하게 실패.
fi
parent="$(dirname "$mem")"
mkdir -p "$parent" 2>/dev/null || true
if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 clone --quiet "$remote" "$mem" 2>/dev/null; then
  echo "claude-config: PRIVATE 기억저장소를 이 머신에 자동 연결했습니다 ($mem <- origin)."
fi
exit 0
