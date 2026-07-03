#!/usr/bin/env sh
# claude-config:memory-sync — PRIVATE claude-memory 저장소의 클라우드 이중백업 (컴포넌트②·기둥7).
#   SessionStart=pull / SessionEnd=push. 성장데이터(events/decisions/profile/metrics)를 매 세션
#   GitHub PRIVATE 원격에 백업해 PC 고장 시 유실 방지. resolver 로 $CLAUDE_MEMORY_DIR 해석 후
#   config-sync.sh 에 위임(검증된 fail-open pull/push/lock 재사용 — 신규 sync 로직 안 만듦).
#   세션 절대 안 막음. 끄기: CLAUDE_MEMORY_NO_SYNC=1 (config-sync 의 CLAUDE_CONFIG_NO_SYNC 도 적용).
#   주의: claude-memory 는 PRIVATE 전용 — leak-guard(githooks) 없음(PII 허용). config-sync 는
#   claude-memory 에 claude/githooks 가 없으므로 self-heal 을 자동 스킵.
set -u
[ "${CLAUDE_MEMORY_NO_SYNC:-}" = "1" ] && exit 0
mode="${1:-}"

# resolve memdir (resolver = single source of truth) + Windows normalize
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || exit 0
command -v cygpath >/dev/null 2>&1 && memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"
[ -d "$memdir/.git" ] || exit 0   # not a git repo yet (A1 미실행) -> nothing to sync

# 네이티브 오토메모리 병합(미러): ~/.claude/projects/<proj>/memory/*.md
#   -> $MEM/native-memory/<machineId>/<proj>/  (SCHEMA.md §0 티어)
# 복사-덮어쓰기만, 삭제 없음(백업이지 정본 아님). fail-open: 실패해도 sync 계속.
# machineId: _resolver-manifest.json machine_id > hostname > 'unknown' (lib/events 와 동일 규칙).
if [ "$mode" = "end" ] && [ -d "$HOME/.claude/projects" ]; then
  machine_id="$(hostname 2>/dev/null || echo unknown)"
  [ -n "$machine_id" ] || machine_id="unknown"
  if [ -f "$memdir/_resolver-manifest.json" ]; then
    m="$(sed -n 's/.*"machine_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$memdir/_resolver-manifest.json" 2>/dev/null | head -1)"
    [ -n "$m" ] && machine_id="$m"
  fi
  machine_id="$(printf '%s' "$machine_id" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$machine_id" ] || machine_id="unknown"
  for d in "$HOME/.claude/projects"/*/memory; do
    [ -d "$d" ] || continue
    proj="$(basename "$(dirname "$d")")"
    dst="$memdir/native-memory/$machine_id/$proj"
    mkdir -p "$dst" 2>/dev/null || continue
    cp -f "$d"/*.md "$dst"/ 2>/dev/null || true
  done
fi

# delegate to config-sync.sh with claude-memory as the repo (deployed > repo-relative)
cs="$HOME/.claude/hooks/config-sync.sh"
if [ ! -f "$cs" ]; then
  d="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
  [ -n "$d" ] && cs="$d/config-sync.sh"
fi
[ -f "$cs" ] || exit 0
exec sh "$cs" "$mode" "$memdir"
