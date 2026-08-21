#!/usr/bin/env bash
# claude-config 설치 (Mac/Linux) — 이 머신의 모든 폴더·세션에서:
#   · Harness 플러그인 자동 설치/복구
#   · effortLevel=high 영구 적용(바닥값, 판단작업은 xhigh 제안) + ultracode/ultraplan 리마인더
#   · `claude` 명령을 ultracode 로 자동 실행(셸 함수 오버라이드)
#   · 런타임 보장: node(플러그인 훅 필수) + python≥3.10(security-guidance 3계층) + brew PATH 출처 고정
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.claude"
mkdir -p "$DST/hooks"

# `claude` → ultracode 자동: 로그인 셸 rc 에 함수 오버라이드 source (idempotent).
# 레포가 사라져도 셸이 깨지지 않도록 [ -f ] 가드. macOS 기본 셸은 zsh.
install_bash_wrapper() {
  local SRC="$REPO_DIR/claude/shell/claude-ultra.sh"
  local primary
  add_one() {
    local rc="$1"
    [ -e "$rc" ] || : > "$rc"   # 없으면 생성 (zsh 가 읽도록)
    if ! grep -qF "claude-config:claude-ultra" "$rc" 2>/dev/null; then
      printf '\n# claude-config:claude-ultra\n[ -f "%s" ] && source "%s"\n' "$SRC" "$SRC" >> "$rc"
      echo "  ✓ claude override → $(basename "$rc")"
    fi
  }
  # 로그인 셸($SHELL)에 맞는 주 rc 선택 — 없으면 생성. zsh 가 .bashrc 를 안 읽는 문제 해결.
  case "${SHELL:-}" in
    *zsh*)  primary="$HOME/.zshrc" ;;
    *bash*) primary="$HOME/.bashrc" ;;
    *) if [ "$(uname -s)" = "Darwin" ]; then primary="$HOME/.zshrc"; else primary="$HOME/.bashrc"; fi ;;
  esac
  add_one "$primary"
  # 이미 존재하는 다른 셸 rc 에도 심어 둠(셸 전환 대비)
  if [ "$primary" != "$HOME/.zshrc" ]  && [ -e "$HOME/.zshrc" ];  then add_one "$HOME/.zshrc";  fi
  if [ "$primary" != "$HOME/.bashrc" ] && [ -e "$HOME/.bashrc" ]; then add_one "$HOME/.bashrc"; fi
  # macOS bash 로그인 셸은 .bash_profile 을 읽음 → .bashrc 를 끌어오게 연결
  if [ "$(uname -s)" = "Darwin" ] && [ -e "$HOME/.bashrc" ]; then
    if [ ! -e "$HOME/.bash_profile" ] || ! grep -q 'bashrc' "$HOME/.bash_profile" 2>/dev/null; then
      printf '\n# claude-config:claude-ultra (load .bashrc for login shells)\n[ -f ~/.bashrc ] && . ~/.bashrc\n' >> "$HOME/.bash_profile"
    fi
  fi
}

# Homebrew PATH 출처를 로그인 프로필에 고정 (macOS 전용).
# node·python 등 brew 바이너리는 /opt/homebrew/bin(Apple Silicon)·/usr/local/bin(Intel)에 있다. 이 경로가
# 로그인 셸 PATH 에 없으면(신규 머신·GUI 실행) claude 가 스폰하는 훅이 node 를 못 찾아 매번 exit 127 난다.
# macOS 의 path_helper(/etc/paths.d)는 이 레포로 동기화되지 않으므로 출처가 불안정 → 표준 `brew shellenv` 를
# ~/.zprofile·~/.bash_profile 에 심어 PATH 출처를 "동기화되는 프로필" 안으로 가져온다(멱등, 마커 가드).
# 현재 install.sh 실행에도 즉시 eval → 이후 command -v node/python3.13 판정이 정확해진다.
ensure_brew_path() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local brew_bin="" b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && { brew_bin="$b"; break; }
  done
  # if 형(전 bash 버전에서 errexit 완전 면제) — brew 완전 부재 Mac + bash 3.2 조합에서의 abort 여지 제거.
  if [ -z "$brew_bin" ] && command -v brew >/dev/null 2>&1; then brew_bin="$(command -v brew)"; fi
  [ -n "$brew_bin" ] || return 0
  eval "$("$brew_bin" shellenv)" 2>/dev/null || true   # 현재 실행에 즉시 반영
  local marker='claude-config:brew-shellenv' prof
  # zsh 로그인 셸(macOS 기본)은 .zprofile 을 읽으므로 항상 심는다.
  # .bash_profile 은 bash 로그인 사용자용 → 스퍼리어스 파일 생성을 피해 이미 있거나 .bashrc 가 있을 때만.
  # 배열로 담아 $HOME 에 공백이 있어도 안전(언쿼트 분할 회피).
  local -a profs=("$HOME/.zprofile")
  { [ -e "$HOME/.bash_profile" ] || [ -e "$HOME/.bashrc" ]; } && profs+=("$HOME/.bash_profile")
  for prof in "${profs[@]}"; do
    [ -e "$prof" ] || : > "$prof"
    grep -qF "$marker" "$prof" 2>/dev/null && continue
    printf '\n# %s (brew bin on PATH so claude hooks can find node/python)\n%s\n' \
      "$marker" "eval \"\$($brew_bin shellenv)\"" >> "$prof"
    echo "  ✓ brew shellenv → $(basename "$prof")"
  done
}

# 런타임 부트스트랩: 플러그인 훅이 요구하는 node + python≥3.10 을 이 머신에 보장 (미설치/버전부족일 때만; 멱등).
#   · node        : oh-my-claudecode 등 다수 훅이 `node …run.cjs` 로 실행 → 없으면 매 훅 exit 127.
#                   bootstrap.sh 도 node 를 깔지만, install.sh 를 직접 도는 경로(재설치·수동·config-sync)는
#                   부트스트랩을 안 거치므로 여기서도 보장한다.
#   · python≥3.10 : security-guidance 3계층 리뷰어(sg-python.sh)가 요구. macOS 기본 python3 는 3.9.6 라 미달.
#                   sg-python.sh Pass1 은 python3.13~3.10 만 프로브 → brew python@3.13 을 깐다.
#                   3.13 을 고르는 이유: Pass1 이 버전드 python3.13 바이너리를 PATH shadow 여부와 무관하게
#                   확정 선택하기 때문. python@3.14 는 Pass1 이 프로브하지 않아, 시스템 python3 를 shadow 할 때만
#                   Pass2 로 잡혀 덜 견고하다.
# set -e 하에서 패키지 매니저 실패로 스크립트가 죽지 않도록 모든 설치는 fail-soft. deploy-only(아래 가드) 에선 도달 안 함.
ensure_runtimes() {
  local os c v; os="$(uname -s)"
  # --- Node.js ---
  if ! command -v node >/dev/null 2>&1; then
    echo "  … node 미설치 — 설치 시도(플러그인 훅 필수)"
    if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then brew install node >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then sudo -n apt-get install -y nodejs npm >/dev/null 2>&1 || true
    elif command -v dnf     >/dev/null 2>&1; then sudo -n dnf install -y nodejs >/dev/null 2>&1 || true
    elif command -v pacman  >/dev/null 2>&1; then sudo -n pacman -S --noconfirm nodejs >/dev/null 2>&1 || true
    elif command -v apk     >/dev/null 2>&1; then sudo -n apk add nodejs >/dev/null 2>&1 || true
    fi
  fi
  if command -v node >/dev/null 2>&1; then
    echo "  ✓ node $(node --version 2>/dev/null)"
  else
    echo "  ! node 미확보 — 수동 설치 필요(https://nodejs.org 또는 brew install node). 없으면 omc 등 node 훅이 매 세션 실패."
  fi
  # --- Python ≥3.10 (sg-python.sh 호환 버전 판정: is_sdk_compatible 미러) ---
  local py_ok=0
  for c in python3.13 python3.12 python3.11 python3.10; do
    command -v "$c" >/dev/null 2>&1 && { py_ok=1; break; }
  done
  if [ "$py_ok" = 0 ] && command -v python3 >/dev/null 2>&1; then
    v="$(python3 -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo 0.0)"
    case "$v" in 3.1[0-9]|3.[2-9][0-9]|[4-9].*|[1-9][0-9].*) py_ok=1 ;; esac
  fi
  if [ "$py_ok" = 0 ]; then
    echo "  … python≥3.10 미탐지 — 설치 시도(security-guidance 3계층)"
    if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then brew install python@3.13 >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then sudo -n apt-get install -y python3 >/dev/null 2>&1 || true
    elif command -v dnf     >/dev/null 2>&1; then sudo -n dnf install -y python3 >/dev/null 2>&1 || true
    elif command -v pacman  >/dev/null 2>&1; then sudo -n pacman -S --noconfirm python >/dev/null 2>&1 || true
    elif command -v apk     >/dev/null 2>&1; then sudo -n apk add python3 >/dev/null 2>&1 || true
    fi
    for c in python3.13 python3.12 python3.11 python3.10; do
      command -v "$c" >/dev/null 2>&1 && { py_ok=1; break; }
    done
    if [ "$py_ok" = 0 ] && command -v python3 >/dev/null 2>&1; then
      v="$(python3 -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo 0.0)"
      case "$v" in 3.1[0-9]|3.[2-9][0-9]|[4-9].*|[1-9][0-9].*) py_ok=1 ;; esac
    fi
  fi
  if [ "$py_ok" = 1 ]; then
    echo "  ✓ python≥3.10 확보(security-guidance 3계층 활성 가능)"
  else
    echo "  ! python≥3.10 미확보 — security-guidance 3계층만 비활성(패턴체크·단발 LLM 리뷰는 동작). 수동: brew install python@3.13"
  fi
}

# Codex가 홈에서 Hermes용 ~/AGENTS.md를 잘못 상속하지 않도록 홈 범위 override를 배포한다.
# 일반 파일이 이미 있으면 덮어쓰지 않고 1회 백업한 뒤 관리 심링크로 전환한다.
install_codex_home_override() {
  local src="$REPO_DIR/codex/home-AGENTS.override.md"
  local dst="$HOME/AGENTS.override.md"
  local backup
  [ -f "$src" ] || { echo "  ! Codex 홈 override 소스 없음: $src" >&2; return 1; }
  if [ -d "$dst" ] && [ ! -L "$dst" ]; then
    echo "  ! $dst 가 디렉터리라 Codex 홈 override 링크를 설치하지 못함" >&2
    return 1
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    backup="$dst.bak.$(date +%s)"
    mv "$dst" "$backup"
    echo "  i 기존 AGENTS.override.md 보존: $backup"
  fi
  ln -sfn "$src" "$dst"
  [ "$(readlink "$dst" 2>/dev/null || true)" = "$src" ] || {
    echo "  ! Codex 홈 override 링크 검증 실패: $dst" >&2
    return 1
  }
  echo "  ✓ Codex home override linked (~/AGENTS.override.md)"
}

# Codex 전용 훅·스킬·설정을 플랫폼 네이티브 형식으로 배포한다.
# AGENTS.md는 아래 codex-sync가 다시 만드는 캐시이고, config/hooks의 기존 사용자 값은
# configure-codex-integration.py가 보존·병합한다.
install_codex_runtime() {
  local codex_home="$HOME/.codex"
  local configure_script="$REPO_DIR/codex/scripts/configure-codex-integration.py"
  local source_path target_path skill_source
  [ -d "$codex_home" ] || return 0
  [ -f "$configure_script" ] || { echo "  ! Codex 설정 병합기 없음: $configure_script" >&2; return 1; }

  mkdir -p "$codex_home/hooks" "$codex_home/skills" "$codex_home/agents" "$HOME/.claude/vault-state"
  chmod 700 "$codex_home/hooks" "$codex_home/skills" "$codex_home/agents" "$HOME/.claude/vault-state" 2>/dev/null || true
  for source_path in "$REPO_DIR"/codex/hooks/*.sh "$REPO_DIR"/codex/hooks/*.py; do
    [ -f "$source_path" ] || continue
    target_path="$codex_home/hooks/$(basename "$source_path")"
    backup_conflicting_path "$target_path"
    ln -sfn "$source_path" "$target_path"
  done

  for source_path in "$REPO_DIR"/codex/profiles/*.config.toml; do
    [ -f "$source_path" ] || continue
    target_path="$codex_home/$(basename "$source_path")"
    backup_conflicting_path "$target_path"
    ln -sfn "$source_path" "$target_path"
  done

  for source_path in "$REPO_DIR"/codex/agents/*.toml; do
    [ -f "$source_path" ] || continue
    target_path="$codex_home/agents/$(basename "$source_path")"
    backup_conflicting_path "$target_path"
    ln -sfn "$source_path" "$target_path"
  done

  skill_source="$REPO_DIR/codex/skills/workload-optimization"
  if [ -d "$skill_source" ]; then
    target_path="$codex_home/skills/workload-optimization"
    backup_conflicting_path "$target_path"
    ln -sfn "$skill_source" "$target_path"
  fi

  chmod +x "$REPO_DIR"/codex/hooks/*.sh "$configure_script" "$REPO_DIR/claude/hooks/vault-catalog.py" 2>/dev/null || true
  python3 "$configure_script" --codex-home "$codex_home" --repo-dir "$REPO_DIR"
  echo "  ✓ Codex native hooks/config/skill installed"
}

# Vault 절대경로는 공개 레포에 넣지 않고 머신 로컬 scope에만 둔다.
# 우선순위: 명시적 OBSIDIAN_VAULT_PATH → 기존 유효 scope → Hermes .env → ~/Documents/Vault.
# 후보는 00_홈.md와 10_컨텍스트가 실제로 있는 Vault만 허용한다.
ensure_vault_scope() {
  local scope_file="$DST/vault-scope.json"
  local vault_path=""
  local existing_path=""
  local hermes_env_path=""
  local explicit_path="${OBSIDIAN_VAULT_PATH:-}"

  normalize_home_path() {
    case "$1" in
      "~") printf '%s\n' "$HOME" ;;
      "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
      *) printf '%s\n' "$1" ;;
    esac
  }
  valid_vault_path() {
    case "$1" in
      /*) [ -f "$1/00_홈.md" ] && [ -d "$1/10_컨텍스트" ] ;;
      *) return 1 ;;
    esac
  }

  if [ -n "$explicit_path" ]; then
    explicit_path="$(normalize_home_path "$explicit_path")"
    if valid_vault_path "$explicit_path"; then
      vault_path="$explicit_path"
    else
      echo "  ! OBSIDIAN_VAULT_PATH가 유효한 Vault가 아님 — 기존/기본 경로 탐색 계속" >&2
    fi
  fi

  if [ -f "$scope_file" ] && command -v python3 >/dev/null 2>&1; then
    existing_path="$(python3 - "$scope_file" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    value = json.load(open(sys.argv[1], encoding='utf-8')).get('vaultPath', '')
    print(os.path.expanduser(value) if isinstance(value, str) else '')
except Exception:
    pass
PY
)"
    if [ -z "$vault_path" ] && valid_vault_path "$existing_path"; then
      vault_path="$existing_path"
    fi
  elif [ -f "$scope_file" ] && ! command -v python3 >/dev/null 2>&1; then
    # 전체 설치 후 ensure_runtimes가 python을 확보하면 다시 호출해 검증·갱신한다.
    echo "  i python3 미탐지 — 기존 vault-scope.json 보존 후 런타임 설치 뒤 재확인"
    return 0
  fi

  if [ -z "$vault_path" ] && [ -f "$HOME/.hermes/.env" ]; then
    hermes_env_path="$(awk '
      /^[[:space:]]*OBSIDIAN_VAULT_PATH[[:space:]]*=/ {
        sub(/^[[:space:]]*OBSIDIAN_VAULT_PATH[[:space:]]*=[[:space:]]*/, "")
        sub(/[[:space:]]*\r$/, "")
        print
        exit
      }' "$HOME/.hermes/.env" 2>/dev/null || true)"
    case "$hermes_env_path" in
      \"*\") hermes_env_path="${hermes_env_path#\"}"; hermes_env_path="${hermes_env_path%\"}" ;;
      \'*\') hermes_env_path="${hermes_env_path#\'}"; hermes_env_path="${hermes_env_path%\'}" ;;
    esac
    hermes_env_path="$(normalize_home_path "$hermes_env_path")"
    valid_vault_path "$hermes_env_path" && vault_path="$hermes_env_path"
  fi

  if [ -z "$vault_path" ] && valid_vault_path "$HOME/Documents/Vault"; then
    vault_path="$HOME/Documents/Vault"
  fi
  if [ -z "$vault_path" ]; then
    echo "  i Vault 미탐지 — OBSIDIAN_VAULT_PATH=/absolute/path 로 재실행하면 연결됨"
    return 0
  fi

  if [ "$existing_path" = "$vault_path" ]; then
    echo "  ✓ vault-scope preserved (existing valid Vault)"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$scope_file" "$vault_path" <<'PY'
import json, os, sys
scope_file, vault_path = sys.argv[1:]
try:
    with open(scope_file, encoding='utf-8') as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, json.JSONDecodeError, OSError):
    data = {}
data['vaultPath'] = vault_path
data.setdefault('projects', [])
temporary = scope_file + '.tmp-install'
with open(temporary, 'w', encoding='utf-8') as stream:
    json.dump(data, stream, indent=2, ensure_ascii=False)
    stream.write('\n')
os.replace(temporary, scope_file)
PY
  elif [ ! -e "$scope_file" ]; then
    # Python이 없는 최소 환경용 신규 파일 fallback. 기존 파일은 다른 키 보존을 위해 건드리지 않는다.
    local escaped_path
    escaped_path="$(printf '%s' "$vault_path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{\n  "vaultPath": "%s",\n  "projects": []\n}\n' "$escaped_path" > "$scope_file"
  else
    echo "  ! python3가 없어 기존 vault-scope.json을 안전하게 갱신하지 못함" >&2
    return 1
  fi
  echo "  ✓ vault-scope ensured (local-only, portable path discovery)"
}

# 설치 직후 연결된 시스템에 정본 규칙을 적용하고 핵심 마커가 정확히 1개인지 확인한다.
run_connected_system_sync() {
  local count
  verify_managed_block() {
    local target="$1" start="$2" end="$3" source="$4" extracted
    extracted="$(mktemp)" || return 1
    awk -v start="$start" -v end="$end" '
      $0 == start { capture=1; next }
      $0 == end   { capture=0; exit }
      capture == 1 { print }
    ' "$target" > "$extracted"
    if ! cmp -s "$extracted" "$source"; then
      rm -f "$extracted"
      return 1
    fi
    rm -f "$extracted"
  }
  if [ -d "$HOME/.codex" ]; then
    "$DST/hooks/codex-sync.sh"
    for marker in \
      '<!-- claude-config:portable-rules:start -->' \
      '<!-- claude-config:codex-vault-rules:start -->'; do
      count="$(grep -cF "$marker" "$HOME/.codex/AGENTS.md" 2>/dev/null || true)"
      [ "$count" = "1" ] || { echo "  ! Codex 동기화 검증 실패: $marker ($count)" >&2; return 1; }
    done
    verify_managed_block "$HOME/.codex/AGENTS.md" \
      '<!-- claude-config:portable-rules:start -->' \
      '<!-- claude-config:portable-rules:end -->' \
      "$REPO_DIR/claude/exports/portable-rules.md" \
      || { echo "  ! Codex portable-rules 내용 불일치" >&2; return 1; }
    verify_managed_block "$HOME/.codex/AGENTS.md" \
      '<!-- claude-config:codex-vault-rules:start -->' \
      '<!-- claude-config:codex-vault-rules:end -->' \
      "$REPO_DIR/claude/exports/codex-vault-rules.md" \
      || { echo "  ! Codex vault rules 내용 불일치" >&2; return 1; }
    echo "  ✓ Codex rules synced and verified"
  fi
  if [ -d "$HOME/.hermes" ]; then
    "$DST/hooks/hermes-sync.sh"
    for marker in \
      '<!-- claude-config:portable-rules:start -->' \
      '<!-- claude-config:hermes-vault-rules:start -->'; do
      count="$(grep -cF "$marker" "$HOME/.hermes/AGENTS.md" 2>/dev/null || true)"
      [ "$count" = "1" ] || { echo "  ! Hermes 동기화 검증 실패: $marker ($count)" >&2; return 1; }
    done
    verify_managed_block "$HOME/.hermes/AGENTS.md" \
      '<!-- claude-config:portable-rules:start -->' \
      '<!-- claude-config:portable-rules:end -->' \
      "$REPO_DIR/claude/exports/portable-rules.md" \
      || { echo "  ! Hermes portable-rules 내용 불일치" >&2; return 1; }
    verify_managed_block "$HOME/.hermes/AGENTS.md" \
      '<!-- claude-config:hermes-vault-rules:start -->' \
      '<!-- claude-config:hermes-vault-rules:end -->' \
      "$REPO_DIR/claude/exports/hermes-vault-rules.md" \
      || { echo "  ! Hermes vault rules 내용 불일치" >&2; return 1; }
    echo "  ✓ Hermes rules synced and verified"
  fi
}

# 관리 링크와 이름이 겹치는 사용자 파일/디렉터리는 삭제하지 않고 옆에 보존한다.
# 온라인 복구는 새 장치에서도 실행되므로, 기존 사용자 자료가 있으면 복구 가능한 이동이 기본이다.
backup_conflicting_path() {
  local target="$1"
  local backup
  local suffix=0
  [ -e "$target" ] || return 0
  [ ! -L "$target" ] || return 0
  backup="$target.pre-claude-config.$(date +%Y%m%d-%H%M%S)"
  while [ -e "$backup" ]; do
    suffix=$((suffix + 1))
    backup="$target.pre-claude-config.$(date +%Y%m%d-%H%M%S).$suffix"
  done
  mv "$target" "$backup"
  echo "  i 기존 사용자 항목 보존: $backup"
}

# Windows(Git Bash/MSYS/Cygwin) 감지 — 핵심 분기.
# Claude Code 는 훅을 "사용자가 claude 를 켠 셸"이 아니라 자기가 직접 스폰한다. 그래서 bash-form
# 훅(`bash "$HOME/...".sh`)을 settings.json 에 박으면 PowerShell 로 켠 세션에서도 그 명령이
# Windows 셸로 스폰돼 ① 'bash' 미발견 ② '$HOME' 미확장 → 매 세션 훅 에러가 난다.
# → Windows 에선 훅/설정 payload 를 powershell-form 으로 쓰는 install.ps1 에 위임하고,
#   여기선 Git Bash 사용자용 claude 래퍼만 심는다. (uname 으로만 분기; Mac/Linux 는 영향 없음)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    ps=""
    command -v powershell.exe >/dev/null 2>&1 && ps=powershell.exe
    [ -z "$ps" ] && command -v powershell >/dev/null 2>&1 && ps=powershell
    if [ -z "$ps" ]; then
      echo "  ! Windows 인데 powershell 미발견 — PowerShell 에서 install.ps1 을 직접 실행하세요." >&2
      exit 1
    fi
    if ! command -v cygpath >/dev/null 2>&1; then
      echo "  ! cygpath 미발견 — Git Bash 권장. PowerShell 에서 install.ps1 을 직접 실행하세요." >&2
      exit 1
    fi
    win_ps1="$(cygpath -w "$REPO_DIR/install.ps1")"
    echo "  i Windows(Git Bash) 감지 — 훅/설정 payload 는 install.ps1 에 위임 (powershell-form 훅)"
    if "$ps" -NoProfile -ExecutionPolicy Bypass -File "$win_ps1"; then
      install_bash_wrapper
      echo "✓ 완료(Windows) — payload=install.ps1(powershell-form 훅), Git Bash 래퍼 심음. 새 터미널에서 claude."
      exit 0
    fi
    echo "  ! install.ps1 위임 실패 — PowerShell 에서 직접 실행: powershell -ExecutionPolicy Bypass -File \"$win_ps1\"" >&2
    exit 1
    ;;
esac

# 훅 링크 (harness 자동 + effort 리마인더 + 설정 자동 동기화)
ln -sfn "$REPO_DIR/claude/hooks/ensure-harness.sh"   "$DST/hooks/ensure-harness.sh"
ln -sfn "$REPO_DIR/claude/hooks/effort-reminder.sh"  "$DST/hooks/effort-reminder.sh"
ln -sfn "$REPO_DIR/claude/hooks/effort-reminder.txt" "$DST/hooks/effort-reminder.txt"
ln -sfn "$REPO_DIR/claude/hooks/config-sync.sh"      "$DST/hooks/config-sync.sh"
ln -sfn "$REPO_DIR/claude/hooks/work-autosync.sh"    "$DST/hooks/work-autosync.sh"
ln -sfn "$REPO_DIR/claude/hooks/model-watch.sh"      "$DST/hooks/model-watch.sh"
ln -sfn "$REPO_DIR/claude/hooks/auto-update.sh"      "$DST/hooks/auto-update.sh"
ln -sfn "$REPO_DIR/claude/hooks/guardrails.sh"       "$DST/hooks/guardrails.sh"
ln -sfn "$REPO_DIR/claude/hooks/guardrails.py"       "$DST/hooks/guardrails.py"
ln -sfn "$REPO_DIR/claude/hooks/edit-track.sh"       "$DST/hooks/edit-track.sh"
ln -sfn "$REPO_DIR/claude/hooks/edit-nudge.sh"       "$DST/hooks/edit-nudge.sh"
ln -sfn "$REPO_DIR/claude/hooks/stop-metrics.sh"     "$DST/hooks/stop-metrics.sh"
ln -sfn "$REPO_DIR/claude/hooks/filter-test-output.sh" "$DST/hooks/filter-test-output.sh"
ln -sfn "$REPO_DIR/claude/hooks/hermes-sync.sh"      "$DST/hooks/hermes-sync.sh"
# codex-sync.sh: hermes-sync.sh와 동일 컨벤션(코덱스 미설치 머신은 훅 내부에서 조용히 스킵) —
# 바로 위 vault-context.sh 주석의 교훈(settings.json 등록 + 이 링크 둘 다 있어야 함)을 따름.
ln -sfn "$REPO_DIR/claude/hooks/codex-sync.sh"       "$DST/hooks/codex-sync.sh"
ln -sfn "$REPO_DIR/claude/hooks/skill-watch.sh"      "$DST/hooks/skill-watch.sh"
# vault-context.sh(맥미니 전용 게이팅은 훅 내부에서 처리 — 다른 머신은 조용히 스킵이라 전
# 머신 배포가 맞다): settings.json엔 SessionStart 등록이 있었는데 이 링크 블록에 없어서 배포된
#적이 한 번도 없었고, 그 결과 매 세션 exit 127로 조용히 실패해왔다(코드리뷰로 재확인된 기존 버그
# — 2026-08-01 세션 초반에 발견만 하고 못 고쳤던 것을 이번 정리 김에 반영).
ln -sfn "$REPO_DIR/claude/hooks/vault-context.sh" "$DST/hooks/vault-context.sh"
ln -sfn "$REPO_DIR/claude/hooks/vault-index.py" "$DST/hooks/vault-index.py"
ln -sfn "$REPO_DIR/claude/hooks/vault-catalog.py" "$DST/hooks/vault-catalog.py"
ln -sfn "$REPO_DIR/claude/hooks/vault-staleness-scan.py" "$DST/hooks/vault-staleness-scan.py"
ln -sfn "$REPO_DIR/claude/hooks/vault-session-log.sh" "$DST/hooks/vault-session-log.sh"
# learning-pipeline-setup.sh: vault-context.sh와 동일 컨벤션(맥미니+볼트 게이팅은 훅 내부, 다른
# 머신은 조용히 스킵) — 바로 위 주석의 교훈(settings.json 등록 + 이 링크 둘 다 있어야 함)을 따름.
ln -sfn "$REPO_DIR/claude/hooks/learning-pipeline-setup.sh" "$DST/hooks/learning-pipeline-setup.sh"
ln -sfn "$REPO_DIR/claude/hooks/statusline.sh"       "$DST/hooks/statusline.sh"
ln -sfn "$REPO_DIR/claude/hooks/context-notify.sh"   "$DST/hooks/context-notify.sh"
chmod +x "$REPO_DIR/claude/hooks/ensure-harness.sh" "$REPO_DIR/claude/hooks/effort-reminder.sh" "$REPO_DIR/claude/hooks/config-sync.sh" "$REPO_DIR/claude/hooks/work-autosync.sh" "$REPO_DIR/claude/hooks/model-watch.sh" "$REPO_DIR/claude/hooks/auto-update.sh" "$REPO_DIR/claude/hooks/guardrails.sh" "$REPO_DIR/claude/hooks/edit-track.sh" "$REPO_DIR/claude/hooks/edit-nudge.sh" "$REPO_DIR/claude/hooks/stop-metrics.sh" "$REPO_DIR/claude/hooks/filter-test-output.sh" "$REPO_DIR/claude/hooks/hermes-sync.sh" "$REPO_DIR/claude/hooks/codex-sync.sh" "$REPO_DIR/claude/hooks/skill-watch.sh" "$REPO_DIR/claude/hooks/vault-context.sh" "$REPO_DIR/claude/hooks/vault-catalog.py" "$REPO_DIR/claude/hooks/learning-pipeline-setup.sh" "$REPO_DIR/claude/hooks/statusline.sh" "$REPO_DIR/claude/hooks/context-notify.sh" "$REPO_DIR/claude/hooks/vault-session-log.sh"
printf '%s' "$REPO_DIR" > "$DST/.config-sync-path"   # config-sync 가 레포 위치를 찾도록
echo "  ✓ hooks linked (ensure-harness, effort-reminder, config-sync, work-autosync, model-watch, auto-update, guardrails, edit-track, edit-nudge, stop-metrics, filter-test-output, hermes-sync, codex-sync, skill-watch, learning-pipeline-setup, statusline, context-notify, vault-session-log)"

# 은퇴된 훅(2026-08-02: v9/v10 lifelong-memory 시스템 완전 은퇴 — 네이티브 auto-memory로 단일화)의
# dangling 심볼릭링크 정리. 예전 install.sh 가 만든 링크가 남아있으면 대상이 없는 채로 settings.json
# 등록만 사라지지 않고 잔존해 매 세션 exit 127 소음을 낸다.
for _retired in memory-inject.sh memory-inject.ps1 memory-sync.sh memory-sync.ps1 \
                reconcile-check.sh reconcile-check.ps1 morning-brief.sh morning-brief.ps1 \
                session-events.sh session-events.ps1; do
  [ -L "$DST/hooks/$_retired" ] && rm -f "$DST/hooks/$_retired"
done

# leak-guard (M1): route this repo's git hooks to the versioned claude/githooks (pre-commit/pre-push).
# Repo-local config; blocks PII/secrets in config-sync's auto-commit/push to the PUBLIC repo. config-sync 본문 무수정.
if [ -d "$REPO_DIR/claude/githooks" ]; then
  chmod +x "$REPO_DIR/claude/githooks/pre-commit" "$REPO_DIR/claude/githooks/pre-push" "$REPO_DIR/claude/githooks/leakscan.sh" 2>/dev/null || true
  if git -C "$REPO_DIR" config core.hooksPath claude/githooks 2>/dev/null; then
    echo "  ✓ leak-guard active (core.hooksPath=claude/githooks; off: CLAUDE_LEAKGUARD_OFF=1)"
  fi
fi

# ultracode 설정 파일(--settings 로 넘길 용도) — 항상 최신본 링크
ln -sfn "$REPO_DIR/claude/ultracode.json" "$DST/ultracode.json"
echo "  ✓ ultracode.json linked"

# 로컬 상태 디렉터리 경로 resolver(memdir) — OMC 세션상태·leak-guard·플레이북초안이 공유하는
# 단일 진실원(경로만, 데이터 없음). (2026-08-02: 여기 있던 "평생 기억저장소" profile/decisions
# 승급사다리는 완전 은퇴 — 네이티브 auto-memory로 단일화.)
mkdir -p "$DST/lib"
ln -sfn "$REPO_DIR/claude/lib/memdir.sh"   "$DST/lib/memdir.sh"
ln -sfn "$REPO_DIR/claude/lib/memdir.ps1"  "$DST/lib/memdir.ps1"
ln -sfn "$REPO_DIR/claude/lib/events.sh"   "$DST/lib/events.sh"
ln -sfn "$REPO_DIR/claude/lib/events.ps1"  "$DST/lib/events.ps1"
ln -sfn "$REPO_DIR/claude/lib/model-watch.py" "$DST/lib/model-watch.py"
ln -sfn "$REPO_DIR/claude/lib/skill-watch.py" "$DST/lib/skill-watch.py"
ln -sfn "$REPO_DIR/claude/lib/auto-update.py" "$DST/lib/auto-update.py"
ln -sfn "$REPO_DIR/claude/lib/vaultdir.sh"          "$DST/lib/vaultdir.sh"
chmod +x "$REPO_DIR/claude/lib/vaultdir.sh" 2>/dev/null || true

# 은퇴된 lib(2026-08-02)의 dangling 심볼릭링크 정리.
for _retired in pending.sh pending.ps1 metrics.sh metrics.ps1 metrics.py brief.py dashboard.py \
                seed-leakwords.py memory-bootstrap.sh memory-bootstrap.ps1; do
  [ -L "$DST/lib/$_retired" ] && rm -f "$DST/lib/$_retired"
done

# 워크플로 (Workflow 도구의 named workflow — 모든 머신에서 Workflow({name:'expert-debate'}) 호출 가능)
mkdir -p "$DST/workflows"
ln -sfn "$REPO_DIR/claude/workflows/expert-debate.js" "$DST/workflows/expert-debate.js"
echo "  ✓ workflows linked (expert-debate)"

# 사용자 스킬 (playbooks·retro·promote 등) — CLAUDE.md 가 라우팅하는 스킬을 ~/.claude/skills 에
# 배포해 실제 /retro·/promote·playbooks 호출이 가능하게 한다 (미배포 시 참조만 되고 발화 불가).
# 제네릭 루프라 신규 스킬(예: promote)은 자동 배포되지만, 레포에서 삭제된 스킬(예: reconcile,
# 2026-08-02 은퇴)의 예전 심링크는 이 루프가 안 건드리므로 별도 정리한다.
mkdir -p "$DST/skills"
for s in "$REPO_DIR"/claude/skills/*/; do
  [ -d "$s" ] || continue
  n="$(basename "$s")"
  backup_conflicting_path "$DST/skills/$n"
  ln -sfn "${s%/}" "$DST/skills/$n"
done
[ -L "$DST/skills/reconcile" ] && rm -f "$DST/skills/reconcile"
echo "  ✓ skills linked (playbooks, retro, promote, hermes-bridge, workload-optimization → ~/.claude/skills)"

# 사용자 에이전트 (hermes-liaison 등) — CLAUDE.md 가 라우팅하는 에이전트를 ~/.claude/agents 에
# 배포해 실제 발화가 가능하게 한다 (미배포 시 참조만 되고 발화 불가; skills 루프와 동일 패턴).
mkdir -p "$DST/agents"
for a in "$REPO_DIR"/claude/agents/*; do
  [ -e "$a" ] || continue
  n="$(basename "$a")"
  backup_conflicting_path "$DST/agents/$n"
  ln -sfn "$a" "$DST/agents/$n"
done
echo "  ✓ agents linked (hermes-liaison → ~/.claude/agents)"

# exports (portable-rules 등) — hermes-sync 훅이 ~/.claude/exports/portable-rules.md 를 읽으므로
# 디렉터리째 링크해 항상 최신본이 보이게 한다.
backup_conflicting_path "$DST/exports"
ln -sfn "$REPO_DIR/claude/exports" "$DST/exports"
echo "  ✓ exports linked (portable-rules → ~/.claude/exports)"
chmod +x "$REPO_DIR/claude/lib/memdir.sh" "$REPO_DIR/claude/lib/events.sh"
echo "  ✓ lib linked (memdir resolver, events instrument, model-watch + skill-watch + auto-update engines)"

# 새 환경에서도 홈 범위 Codex 라우팅과 Vault 경로가 즉시 복구되도록 설치 payload에 포함한다.
install_codex_home_override
ensure_vault_scope
install_codex_runtime
run_connected_system_sync

# .leakwords 는 더 이상 자동시드하지 않는다(2026-08-02: 시드 입력원이던 profile 은퇴).
# gate2b(bare 실명 스캔) 활성화는 이제 사용자가 promote 스킬 최초 실행 시 1회 수동으로 한다
# (claude/skills/promote/SKILL.md 사전조건 참고) — 자동시드는 사용자 실명을 매 설치마다
# 파일시스템에 쓰는 부작용이 있어, 수동 옵트인이 더 안전한 기본값이라 판단.

# CLAUDE.md (전역 세션 기본값): 없으면/심링크면 링크(업데이트 자동 반영),
# 실제 파일이면 claude-config 관리 블록을 마커 사이에 삽입/갱신(마커 밖 사용자 내용 보존).
if [ -L "$DST/CLAUDE.md" ] || [ ! -e "$DST/CLAUDE.md" ]; then
  ln -sfn "$REPO_DIR/claude/CLAUDE.md" "$DST/CLAUDE.md"
  echo "  ✓ CLAUDE.md linked"
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$DST/CLAUDE.md" "$REPO_DIR/claude/CLAUDE.md" <<'PY'
import sys
dst,src=sys.argv[1],sys.argv[2]
body=open(src,encoding='utf-8').read().rstrip('\n')
START='<!-- claude-config:claude-md:start (auto-generated; updated on reinstall) -->'
END='<!-- claude-config:claude-md:end -->'
# 블록 검색 토큰
START_TOKS=['<!-- claude-config:claude-md:start','<!-- dotfiles:claude-md:start']
END_TOKS=['<!-- claude-config:claude-md:end -->','<!-- dotfiles:claude-md:end -->']
block=START+'\n'+body+'\n'+END
try: cur=open(dst,encoding='utf-8').read()
except FileNotFoundError: cur=None
i=-1; j=-1; elen=0
if cur is not None:
    for t in START_TOKS:
        k=cur.find(t)
        if k>=0: i=k; break
    for t in END_TOKS:
        k=cur.find(t)
        if k>=0: j=k; elen=len(t); break
if cur is None:
    out=block+'\n'
elif i>=0 and j>=i:
    out=cur[:i]+block+cur[j+elen:]
else:
    out=cur.rstrip('\n')+'\n\n'+block+'\n'
open(dst,'w',encoding='utf-8').write(out)
PY
  echo "  ✓ CLAUDE.md claude-config 블록 삽입/갱신 (마커 밖 사용자 내용 보존)"
else
  echo "  ! python3 미설치 — CLAUDE.md 머지 건너뜀 (python3 설치 후 재실행)"
fi

# settings: 없으면 링크, 있으면 머지(기존 보존)
if [ -L "$DST/settings.json" ] || [ ! -e "$DST/settings.json" ]; then
  ln -sfn "$REPO_DIR/claude/settings.json" "$DST/settings.json"
  echo "  ✓ settings linked"
elif command -v python3 >/dev/null 2>&1; then
  cp -p "$DST/settings.json" "$DST/settings.json.bak.$(date +%s)"
  # 백업 누적 방지(config-sync 가 매 변경마다 deploy 하므로): 최근 5개만 유지
  ls -1t "$DST"/settings.json.bak.* 2>/dev/null | tail -n +6 | while IFS= read -r _bak; do rm -f "$_bak"; done
  python3 - "$DST/settings.json" "$REPO_DIR/claude/settings.json" <<'PY'
import json,sys
dst,src=sys.argv[1],sys.argv[2]
d=json.load(open(dst)); s=json.load(open(src))
d.setdefault("extraKnownMarketplaces",{}).update(s["extraKnownMarketplaces"])
d.setdefault("enabledPlugins",{}).update(s["enabledPlugins"])
if d.get("effortLevel") == "xhigh":
    d["effortLevel"] = "high"  # 1회성 마이그레이션: 구 관리 기본값(xhigh) 정리 — 사용자가 다른 값을 골랐다면(else 분기) 무관
else:
    d.setdefault("effortLevel", s.get("effortLevel","high"))  # 없을 때만 — 사용자 선택 보존
d.setdefault("permissions",{}).setdefault("defaultMode", s.get("permissions",{}).get("defaultMode","auto"))  # 소스의 defaultMode(현재 bypassPermissions) — 없을 때만; 기존 사용자 선택 보존
if "skipDangerousModePermissionPrompt" in s:  # bypass 진입 시 위험 경고창 스킵 — 심링크 아닌 머지 경로 머신도 무프롬프트가 되도록(없을 때만; 사용자 선택 보존)
    d.setdefault("skipDangerousModePermissionPrompt", s["skipDangerousModePermissionPrompt"])
# 모델 전략(적응형 플랜) — 레포가 정본(항상 소스값으로 갱신): model 별칭(opusplan)과
# env 재매핑(ANTHROPIC_DEFAULT_*)·fallbackModel·advisorModel 은 전 머신 동기화 대상.
# 직지정(concrete id) 잔재는 이 덮어쓰기로 자연 치유되고, model-watch 의 새 프런티어
# 재매핑도 레포 settings 를 거쳐 여기서 전파된다. env 는 키 단위 갱신 — 머신 로컬 env
# 키(토큰 등)는 보존.
if "model" in s: d["model"]=s["model"]
else: d.pop("model", None)  # 레포가 model 무지정이면 직지정 잔재 제거(계정 기본값 사용)
if isinstance(s.get("env"), dict): d.setdefault("env",{}).update(s["env"])
for k in ("fallbackModel","advisorModel"):
    if k in s: d[k]=s[k]
for k in ("theme","autoUpdatesChannel","skipWorkflowUsageWarning","statusLine"):  # 개인 취향 키 — 없을 때만(사용자 선택 보존)
    if k in s: d.setdefault(k, s[k])
# 소스의 모든 hook 이벤트(SessionStart, SessionEnd, ...)를 머지. 자가 치유 dedup(순서 보존).
# 그룹의 matcher(예: filter-test-output 의 "Bash")를 보존·동기화한다 — 유실 시 PreToolUse 훅이
# 모든 도구 호출마다 발화하는 회귀가 있었음(install.ps1 의 matcher 사양과 대칭).
# 은퇴된 훅 이름(2026-08-02: v9/v10 lifelong-memory 시스템 완전 은퇴) — 이 머지는 기본적으로
# add-only 라, 레포에서 훅을 빼도 이미 실파일로 배포된 settings.json 에는 등록이 영구 잔존한다.
# 그래서 이름으로 능동 pruning 한다(실측 발견 — settings.json 이 심링크가 아닌 머신에서 재현됨).
# 호출 위치(-File "..." / bash "...")에 앵커된 정규식만 매칭(install.ps1 의 $managedRe 와 대칭 —
# 코드리뷰 LOW 대응: 순수 부분문자열 매칭이면 "echo memory-sync.sh 관련 메모" 처럼 은퇴 이름을
# 텍스트로 언급만 하는 사용자 훅까지 그룹째 잘못 지워질 수 있었다).
import re as _re
RETIRED_RE = _re.compile(r'(?:-File\s*"?|bash\s+"?)[^"]*\.claude[\\/]hooks[\\/]'
                          r'(?:memory-inject|memory-sync|reconcile-check|morning-brief|session-events)\.(?:ps1|sh)\b')
hk=d.setdefault("hooks",{})
for event, groups in s.get("hooks",{}).items():
    cur=hk.setdefault(event,[])
    cur=[g for g in cur if not any(
        RETIRED_RE.search(h.get("command") or "")
        for h in g.get("hooks",[])
    )]
    seen=set(); dedup=[]
    for g in cur:
        key=tuple(h.get("command") for h in g.get("hooks",[]))
        if key and key in seen: continue
        if key: seen.add(key)
        dedup.append(g)
    cur=dedup
    src_matcher={h["command"]: g.get("matcher") for g in groups for h in g.get("hooks",[]) if h.get("command")}
    for g in cur:  # 자가치유: 관리 명령만 담긴 기존 그룹의 matcher 를 소스 사양에 맞춤(사용자 훅 그룹 불변)
        cmds=[h.get("command") for h in g.get("hooks",[])]
        if cmds and all(c in src_matcher for c in cmds):
            m=src_matcher[cmds[0]]
            if m is None: g.pop("matcher", None)
            else: g["matcher"]=m
    have={h.get("command") for g in cur for h in g.get("hooks",[])}
    for g in groups:
        for h in g.get("hooks",[]):
            if h.get("command") and h["command"] not in have:
                ng={"hooks":[{"type":"command","command":h["command"]}]}
                if g.get("matcher"): ng["matcher"]=g["matcher"]
                cur.append(ng); have.add(h["command"])
    hk[event]=cur
# 자동업데이트 항상 ON(1/2): settings 의 비활성 레버 제거 (autoupdates→settings 마이그레이션 대비; "0" 도 truthy 라 끄므로 키째 제거)
if isinstance(d.get("env"), dict): d["env"].pop("DISABLE_AUTOUPDATER", None)
# CLAUDE_MEMORY_NO_SYNC(2026-08-02 은퇴): 대상이던 memory-sync.sh 자체가 삭제됐으므로 무의미한 잔재 제거.
if isinstance(d.get("env"), dict): d["env"].pop("CLAUDE_MEMORY_NO_SYNC", None)
# 원자적 쓰기(tmp+rename): detached model-watch probe 등 동시 읽기가 잘린 파일을 보지 않도록.
import os
tmp=dst+".tmp-install-merge"
with open(tmp,"w") as f:
    json.dump(d,f,indent=2,ensure_ascii=False); f.write("\n")
os.replace(tmp,dst)
PY
  echo "  ✓ settings merged (기존 보존, 백업됨)"
else
  echo "  ! python3 미설치 — settings 머지 건너뜀 (symlink 사용 권장 또는 python3 설치 후 재실행)"
fi

# 배포 스탬프: payload 가 어느 HEAD 기준으로 배치됐는지 기록. config-sync 는 이 스탬프와
# 현재 HEAD 를 비교해 deploy 필요 여부를 판정한다("자기 pull 로 변경됐을 때만" 방식은 세션의
# 수동 git pull 이 선점하면 배포가 무기한 표류하는 갭이 있었음 — 2026-07-08 사건).
git -C "$REPO_DIR" rev-parse HEAD > "$DST/.last-deployed-head" 2>/dev/null || true

# 테스트/CI·자동동기화용 deploy-only: payload(훅·settings·CLAUDE.md·ultracode.json)만 배치하고
# 머신상태(셸 래퍼·플러그인·PATH 등)는 건너뜀 — 멱등·부작용 없음(config-sync 가 매 변경마다 호출).
# ↓ 래퍼 설치는 셸 rc 를 건드리므로 반드시 이 가드 '뒤'에 둔다(install.ps1 과 대칭; deploy-only 계약 준수).
if [ "${CLAUDE_INSTALL_DEPLOY_ONLY:-}" = "1" ]; then
  echo "  i deploy-only — shell wrapper/plugin install skipped"
  exit 0
fi

# `claude` → ultracode 자동: 위에서 정의한 래퍼 설치 (Unix 경로; Windows 는 위 분기에서 처리됨).
install_bash_wrapper

# Homebrew PATH 출처를 동기화되는 로그인 프로필에 고정 (macOS). node/python 을 깔기 전에 실행해
# 현재 실행의 command -v 판정을 정확히 하고, 새 머신/GUI 실행에서도 훅이 brew 바이너리를 찾게 한다.
ensure_brew_path

# 로컬 상태 디렉터리 env 영구설정 — 셸 rc 에 export(이미 설정돼 있으면 ${VAR:-default} 로 그 값 보존).
# OMC 는 process.env.OMC_STATE_DIR 를 읽어 세션상태를 단일 트리로 모은다. admin 불필요.
# (2026-08-02: "평생 기억저장소" profile/decisions 승급사다리는 완전 은퇴 — 아래 스캐폴드는
# omc-state/playbook-drafts 만 만든다. memory-bootstrap 자동클론·.gitattributes·profile 시드는
# 전부 그 은퇴된 개념 전용이었으므로 제거됨.)
memdir_marker='claude-config:memdir-env'
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -e "$rc" ] || continue
  grep -qF "$memdir_marker" "$rc" 2>/dev/null && continue
  printf '\n# %s\n%s\n%s\n' "$memdir_marker" \
    'export CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR:-$HOME/claude-memory}"' \
    'export OMC_STATE_DIR="${OMC_STATE_DIR:-$CLAUDE_MEMORY_DIR/omc-state}"' >> "$rc"
  echo "  ✓ memdir env → $(basename "$rc")"
done
_md="${CLAUDE_MEMORY_DIR:-$HOME/claude-memory}"
mkdir -p "$_md/omc-state" "$_md/playbook-drafts"

# 자동업데이트 항상 ON 보장(2/2): 전역 config(~/.claude.json)의 레거시 비활성(autoUpdates:false)을 치유.
# 이 버전은 자동업데이트 on/off 를 전역 config 의 autoUpdates 에서 읽음(settings.json 아님).
# native 설치는 보호 차원에서 건드리지 않음. perl 로 해당 불리언만 표면 치환(앱 토큰 등 나머지는 그대로 보존).
cj="$HOME/.claude.json"
if [ -f "$cj" ] && command -v perl >/dev/null 2>&1 \
   && ! grep -q '"installMethod"[[:space:]]*:[[:space:]]*"native"' "$cj" \
   && grep -q '"autoUpdates"[[:space:]]*:[[:space:]]*false' "$cj"; then
  cp -p "$cj" "$cj.bak.$(date +%s)" 2>/dev/null || true
  if perl -i -pe 's/("autoUpdates"\s*:\s*)false/${1}true/' "$cj"; then
    echo "  ✓ ~/.claude.json autoUpdates:false → true (auto-update 항상 ON)"
  fi
fi

# 전역 git 안전 기본값: ~/.gitignore_global(모든 레포가 시크릿 무시) + sane 기본값(미설정 시에만).
if command -v git >/dev/null 2>&1; then
  gi_src="$REPO_DIR/claude/git/gitignore_global"
  if [ -f "$gi_src" ]; then
    # 사용자가 이미 전역 gitignore 를 쓰면 그 파일에 시크릿 패턴만 보강(설정을 덮어쓰지 않음).
    # `|| true`: 키 미설정 시 git 이 exit 1 → set -e 가 스크립트를 죽이는 것을 방지(2>/dev/null 은 stderr 만 막음)
    existing="$(git config --global --get core.excludesfile 2>/dev/null || true)"
    target=""
    if [ -n "$existing" ]; then
      res="${existing/#\~/$HOME}"
      [ -f "$res" ] && target="$res"
    fi
    if [ -z "$target" ]; then
      target="$HOME/.gitignore_global"
      [ -f "$target" ] || cp "$gi_src" "$target"
      git config --global core.excludesfile "$target"
    fi
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      grep -qxF "$line" "$target" 2>/dev/null || printf '%s\n' "$line" >> "$target"
    done < "$gi_src"
    echo "  ✓ global gitignore secrets ensured ($target)"
  fi
  # sane git 기본값 — 미설정일 때만 (사용자 선택 보존)
  git config --global --get init.defaultBranch   >/dev/null 2>&1 || git config --global init.defaultBranch main
  git config --global --get push.autoSetupRemote >/dev/null 2>&1 || git config --global push.autoSetupRemote true
  git config --global --get fetch.prune          >/dev/null 2>&1 || git config --global fetch.prune true
  git config --global --get rebase.autoStash     >/dev/null 2>&1 || git config --global rebase.autoStash true
  echo "  ✓ git defaults (init.defaultBranch, push.autoSetupRemote, fetch.prune, rebase.autoStash) — only if unset"
fi

# 런타임 부트스트랩(node + python≥3.10). 플러그인 설치보다 먼저, CLAUDECODE 세션 가드 밖에서 실행한다:
# brew 설치는 중첩 claude 를 띄우지 않아 세션 안에서도 안전하고, 플러그인 훅이 node 를 필요로 하기 때문.
ensure_runtimes

# 전체 설치에서 방금 확보한 python으로 로컬 scope를 재검증하고 Vault 인덱스까지 재생성한다(멱등).
ensure_vault_scope
install_codex_runtime
run_connected_system_sync

# 즉시 설치
# claude 세션 내부에서 install.sh 를 돌리면, 플러그인 설치가 띄우는 중첩 claude 프로세스의
# SessionEnd 훅(config-sync push)이 "Hook cancelled" 로 죽어 install 이 exit 1 + stale lock 을 남긴다.
# 세션 안에서는 '플러그인 설치 단계만' 건너뛴다(플러그인 enable 은 위 settings 머지로 이미 반영됨).
# 실제 설치는 새 터미널(비-claude)에서 재실행 시 수행. 강제 실행: CLAUDE_INSTALL_FORCE_PLUGINS=1.
if { [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; } && [ "${CLAUDE_INSTALL_FORCE_PLUGINS:-}" != "1" ]; then
  echo "  i claude 세션 내부 감지 — 플러그인 설치 단계 건너뜀 (새 터미널에서 install.sh 재실행 시 설치; 강제: CLAUDE_INSTALL_FORCE_PLUGINS=1)"
elif command -v claude >/dev/null 2>&1; then
  claude plugin marketplace add revfactory/harness  >/dev/null 2>&1 || true
  claude plugin install harness@harness-marketplace >/dev/null 2>&1 || true
  echo "  ✓ harness installed"
  claude plugin marketplace add Yeachan-Heo/oh-my-claudecode >/dev/null 2>&1 || true
  claude plugin install oh-my-claudecode@omc               >/dev/null 2>&1 || true
  echo "  ✓ oh-my-claudecode installed (/deep-interview, /ralph)"
  for p in hookify security-guidance skill-creator plugin-dev mcp-server-dev frontend-design playwright context7 github; do
    claude plugin install "$p@claude-plugins-official" >/dev/null 2>&1 || true
  done
  echo "  ✓ official plugins installed (hookify, security-guidance, skill-creator, plugin-dev, mcp-server-dev, frontend-design, playwright, context7, github)"
  claude plugin marketplace add fivetaku/gptaku_plugins >/dev/null 2>&1 || true
  claude plugin install insane-search@gptaku-plugins    >/dev/null 2>&1 || true
  echo "  ✓ insane-search installed (차단된 공개 사이트 자동 우회 리더)"
  echo "  i  github MCP needs env GITHUB_PERSONAL_ACCESS_TOKEN (set per machine; never commit)"
  claude plugin list 2>/dev/null | grep -E "harness|oh-my-claudecode|hookify|security-guidance|skill-creator|plugin-dev|mcp-server-dev|frontend-design|playwright|context7|github|insane-search|Status" || true
else
  echo "  ℹ claude 미설치 — 다음 세션 훅이 설치"
fi
echo "✓ 완료. effortLevel=high 영구(바닥값) + ultracode 자동(claude 오버라이드) + harness 자동 + 런타임(node·python≥3.10) 보장."
echo "  (새 터미널을 열어야 claude 오버라이드·brew PATH 가 적용됩니다.)"
