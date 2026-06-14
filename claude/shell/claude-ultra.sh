# claude-config:claude-ultra — `claude` 를 항상 ultracode 로 실행 (bash/zsh).
# 실제 바이너리를 호출(command)해 함수 재귀를 방지하고,
# ultracode.json 이 없으면 평범한 claude 로 폴백한다.
claude() {
  local _s="$HOME/.claude/ultracode.json"
  # github MCP 토큰: 명시적으로 설정돼 있지 않으면 로그인된 gh 에서 런타임으로 가져옴 (레포엔 비밀 미포함)
  if [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    local _gt; _gt="$(gh auth token 2>/dev/null)"
    [ -n "$_gt" ] && export GITHUB_PERSONAL_ACCESS_TOKEN="$_gt"
  fi
  if [ -f "$_s" ]; then
    command claude --settings "$_s" "$@"
  else
    command claude "$@"
  fi
}
