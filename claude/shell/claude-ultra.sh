# dotfiles:claude-ultra — `claude` 를 항상 ultracode 로 실행 (bash/zsh).
# 실제 바이너리를 호출(command)해 함수 재귀를 방지하고,
# ultracode.json 이 없으면 평범한 claude 로 폴백한다.
claude() {
  local _s="$HOME/.claude/ultracode.json"
  if [ -f "$_s" ]; then
    command claude --settings "$_s" "$@"
  else
    command claude "$@"
  fi
}
