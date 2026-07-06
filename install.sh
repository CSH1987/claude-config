#!/usr/bin/env bash
# claude-config 설치 (Mac/Linux) — 이 머신의 모든 폴더·세션에서:
#   · Harness 플러그인 자동 설치/복구
#   · effortLevel=xhigh 영구 적용 + ultracode/ultraplan 리마인더
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
ln -sfn "$REPO_DIR/claude/hooks/memory-inject.sh"    "$DST/hooks/memory-inject.sh"
ln -sfn "$REPO_DIR/claude/hooks/effort-reminder.txt" "$DST/hooks/effort-reminder.txt"
ln -sfn "$REPO_DIR/claude/hooks/config-sync.sh"      "$DST/hooks/config-sync.sh"
ln -sfn "$REPO_DIR/claude/hooks/work-autosync.sh"    "$DST/hooks/work-autosync.sh"
ln -sfn "$REPO_DIR/claude/hooks/session-events.sh"   "$DST/hooks/session-events.sh"
ln -sfn "$REPO_DIR/claude/hooks/reconcile-check.sh"  "$DST/hooks/reconcile-check.sh"
ln -sfn "$REPO_DIR/claude/hooks/morning-brief.sh"    "$DST/hooks/morning-brief.sh"
ln -sfn "$REPO_DIR/claude/hooks/model-watch.sh"      "$DST/hooks/model-watch.sh"
ln -sfn "$REPO_DIR/claude/hooks/memory-sync.sh"      "$DST/hooks/memory-sync.sh"
ln -sfn "$REPO_DIR/claude/hooks/guardrails.sh"       "$DST/hooks/guardrails.sh"
ln -sfn "$REPO_DIR/claude/hooks/guardrails.py"       "$DST/hooks/guardrails.py"
ln -sfn "$REPO_DIR/claude/hooks/edit-track.sh"       "$DST/hooks/edit-track.sh"
ln -sfn "$REPO_DIR/claude/hooks/stop-metrics.sh"     "$DST/hooks/stop-metrics.sh"
chmod +x "$REPO_DIR/claude/hooks/ensure-harness.sh" "$REPO_DIR/claude/hooks/effort-reminder.sh" "$REPO_DIR/claude/hooks/memory-inject.sh" "$REPO_DIR/claude/hooks/config-sync.sh" "$REPO_DIR/claude/hooks/work-autosync.sh" "$REPO_DIR/claude/hooks/session-events.sh" "$REPO_DIR/claude/hooks/reconcile-check.sh" "$REPO_DIR/claude/hooks/morning-brief.sh" "$REPO_DIR/claude/hooks/model-watch.sh" "$REPO_DIR/claude/hooks/memory-sync.sh" "$REPO_DIR/claude/hooks/guardrails.sh" "$REPO_DIR/claude/hooks/edit-track.sh" "$REPO_DIR/claude/hooks/stop-metrics.sh"
printf '%s' "$REPO_DIR" > "$DST/.config-sync-path"   # config-sync 가 레포 위치를 찾도록
echo "  ✓ hooks linked (ensure-harness, effort-reminder, config-sync, work-autosync, session-events, reconcile-check, model-watch, morning-brief, memory-sync, guardrails, edit-track, stop-metrics)"

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

# 평생 기억저장소 경로 resolver(memdir) — 모든 hook·skill 이 호출하는 단일 진실원(경로만, 데이터 없음).
mkdir -p "$DST/lib"
ln -sfn "$REPO_DIR/claude/lib/memdir.sh"   "$DST/lib/memdir.sh"
ln -sfn "$REPO_DIR/claude/lib/memdir.ps1"  "$DST/lib/memdir.ps1"
ln -sfn "$REPO_DIR/claude/lib/events.sh"   "$DST/lib/events.sh"
ln -sfn "$REPO_DIR/claude/lib/events.ps1"  "$DST/lib/events.ps1"
ln -sfn "$REPO_DIR/claude/lib/pending.sh"  "$DST/lib/pending.sh"
ln -sfn "$REPO_DIR/claude/lib/pending.ps1" "$DST/lib/pending.ps1"
ln -sfn "$REPO_DIR/claude/lib/metrics.sh"  "$DST/lib/metrics.sh"
ln -sfn "$REPO_DIR/claude/lib/metrics.ps1" "$DST/lib/metrics.ps1"
ln -sfn "$REPO_DIR/claude/lib/metrics.py"  "$DST/lib/metrics.py"
ln -sfn "$REPO_DIR/claude/lib/brief.py"     "$DST/lib/brief.py"
ln -sfn "$REPO_DIR/claude/lib/model-watch.py" "$DST/lib/model-watch.py"
ln -sfn "$REPO_DIR/claude/lib/dashboard.py" "$DST/lib/dashboard.py"
ln -sfn "$REPO_DIR/claude/lib/seed-leakwords.py" "$DST/lib/seed-leakwords.py"
ln -sfn "$REPO_DIR/claude/lib/memory-bootstrap.sh"  "$DST/lib/memory-bootstrap.sh"
ln -sfn "$REPO_DIR/claude/lib/memory-bootstrap.ps1" "$DST/lib/memory-bootstrap.ps1"
chmod +x "$REPO_DIR/claude/lib/memory-bootstrap.sh" 2>/dev/null || true

# 워크플로 (Workflow 도구의 named workflow — 모든 머신에서 Workflow({name:'expert-debate'}) 호출 가능)
mkdir -p "$DST/workflows"
ln -sfn "$REPO_DIR/claude/workflows/expert-debate.js" "$DST/workflows/expert-debate.js"
echo "  ✓ workflows linked (expert-debate)"

# 사용자 스킬 (playbooks·retro·reconcile) — CLAUDE.md 가 라우팅하는 스킬을 ~/.claude/skills 에
# 배포해 실제 /retro·/reconcile·playbooks 호출이 가능하게 한다 (미배포 시 참조만 되고 발화 불가).
mkdir -p "$DST/skills"
for s in "$REPO_DIR"/claude/skills/*/; do
  [ -d "$s" ] || continue
  n="$(basename "$s")"
  if [ -e "$DST/skills/$n" ] && [ ! -L "$DST/skills/$n" ]; then rm -rf "$DST/skills/$n"; fi
  ln -sfn "${s%/}" "$DST/skills/$n"
done
echo "  ✓ skills linked (playbooks, retro, reconcile → ~/.claude/skills)"
chmod +x "$REPO_DIR/claude/lib/memdir.sh" "$REPO_DIR/claude/lib/events.sh" "$REPO_DIR/claude/lib/pending.sh" "$REPO_DIR/claude/lib/metrics.sh"
echo "  ✓ lib linked (memdir resolver, events instrument, pending stager, metrics derive, brief + dashboard, leakwords seeder)"

# .leakwords 자동시드 (v9 0-D2): profile 식별토큰 → gate2b(bare 실명) 활성화. profile 빔이면 no-op.
if command -v python3 >/dev/null 2>&1; then
  _md="${CLAUDE_MEMORY_DIR:-}"
  if [ -z "$_md" ] && [ -f "$DST/lib/memdir.sh" ]; then eval "$(bash "$DST/lib/memdir.sh" --no-ensure --export 2>/dev/null || true)"; _md="${CLAUDE_MEMORY_DIR:-}"; fi
  [ -n "$_md" ] && python3 "$REPO_DIR/claude/lib/seed-leakwords.py" "$_md" >/dev/null 2>&1 || true
fi

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
d.setdefault("effortLevel", s.get("effortLevel","xhigh"))  # 없을 때만 — 사용자 선택 보존
d.setdefault("permissions",{}).setdefault("defaultMode", s.get("permissions",{}).get("defaultMode","auto"))  # 소스의 defaultMode(현재 bypassPermissions) — 없을 때만; 기존 사용자 선택 보존
if "skipDangerousModePermissionPrompt" in s:  # bypass 진입 시 위험 경고창 스킵 — 심링크 아닌 머지 경로 머신도 무프롬프트가 되도록(없을 때만; 사용자 선택 보존)
    d.setdefault("skipDangerousModePermissionPrompt", s["skipDangerousModePermissionPrompt"])
# 소스의 모든 hook 이벤트(SessionStart, SessionEnd, ...)를 머지. 자가 치유 dedup(순서 보존).
hk=d.setdefault("hooks",{})
for event, groups in s.get("hooks",{}).items():
    cur=hk.setdefault(event,[])
    seen=set(); dedup=[]
    for g in cur:
        key=tuple(h.get("command") for h in g.get("hooks",[]))
        if key and key in seen: continue
        if key: seen.add(key)
        dedup.append(g)
    cur=dedup
    have={h.get("command") for g in cur for h in g.get("hooks",[])}
    for g in groups:
        for h in g.get("hooks",[]):
            if h.get("command") and h["command"] not in have:
                cur.append({"hooks":[{"type":"command","command":h["command"]}]}); have.add(h["command"])
    hk[event]=cur
# 자동업데이트 항상 ON(1/2): settings 의 비활성 레버 제거 (autoupdates→settings 마이그레이션 대비; "0" 도 truthy 라 끄므로 키째 제거)
if isinstance(d.get("env"), dict): d["env"].pop("DISABLE_AUTOUPDATER", None)
json.dump(d,open(dst,"w"),indent=2,ensure_ascii=False); open(dst,"a").write("\n")
PY
  echo "  ✓ settings merged (기존 보존, 백업됨)"
else
  echo "  ! python3 미설치 — settings 머지 건너뜀 (symlink 사용 권장 또는 python3 설치 후 재실행)"
fi

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

# 평생 기억저장소 env 영구설정 (결정 D1) — 셸 rc 에 export(이미 설정돼 있으면 ${VAR:-default} 로 그 값 보존).
# OMC 는 process.env.OMC_STATE_DIR 를 읽어 성장데이터를 단일 트리로 모은다. admin 불필요(D4).
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
# 자동 부트스트랩: 이 머신에 PRIVATE 기억저장소가 아직 없으면 원격을 자동 클론(무동작 활성화).
# 이미 .git 이면 즉시 skip(불가침), 원격 미해석/실데이터면 skip. 스캐폴드 mkdir 앞에 둬 빈 dir 클론을 돕는다.
[ -f "$REPO_DIR/claude/lib/memory-bootstrap.sh" ] && CLAUDE_MEMORY_DIR="$_md" bash "$REPO_DIR/claude/lib/memory-bootstrap.sh" || true
mkdir -p "$_md/profile" "$_md/decisions" "$_md/omc-state"
# 샤드 동시쓰기 충돌 라인보존: PRIVATE 스토어의 events/_sync-log jsonl 은 merge=union (SCHEMA.md §0/§3, plan v9).
# 부재 시에만 시드(사용자 수정 보존). PUBLIC claude-config 가 아니라 PRIVATE 스토어 루트($_md)에 둔다.
_memga="$_md/.gitattributes"
if [ ! -e "$_memga" ]; then
  printf '%s\n%s\n' 'events/*.jsonl    merge=union' '_sync-log/*.jsonl merge=union' > "$_memga"
  echo "  ✓ claude-memory .gitattributes seeded (events/_sync-log merge=union)"
fi
# profile 시드 — 부재 시에만(빈 스캐폴드, bool 기본값 없음 → A1 hook cold-start 무주입 유지).
_profile="$_md/profile/user-profile.json"
if [ ! -e "$_profile" ]; then
  printf '%s\n' '{"schema_version":1,"updated_at":"","updated_by":"","identity":{"display_name":"","handles":{},"contact_domain":"","locale":"","timezone":""},"preferences":{"response_language":"","tone":"","effort_default":"","code_comment_language":"","units":""},"roles":[],"working_style":{"preferred_stacks":[],"preferred_tools":[]},"constraints":{"do_not":[],"sensitive_topics":[],"no_proactive_mentions":[]},"projects":[],"anchors":[]}' > "$_profile"
  echo "  ✓ profile seed created ($_profile)"
fi

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
echo "✓ 완료. effortLevel=xhigh 영구 + ultracode 자동(claude 오버라이드) + harness 자동 + 런타임(node·python≥3.10) 보장."
echo "  (새 터미널을 열어야 claude 오버라이드·brew PATH 가 적용됩니다.)"
