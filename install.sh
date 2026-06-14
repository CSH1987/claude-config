#!/usr/bin/env bash
# Claude dotfiles 설치 (Mac/Linux) — 이 머신의 모든 폴더·세션에서:
#   · Harness 플러그인 자동 설치/복구
#   · effortLevel=xhigh 영구 적용 + ultracode/ultraplan 리마인더
#   · `claude` 명령을 ultracode 로 자동 실행(셸 함수 오버라이드)
set -euo pipefail
DOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.claude"
mkdir -p "$DST/hooks"

# 훅 링크 (harness 자동 + effort 리마인더)
ln -sfn "$DOTDIR/claude/hooks/ensure-harness.sh"   "$DST/hooks/ensure-harness.sh"
ln -sfn "$DOTDIR/claude/hooks/effort-reminder.sh"  "$DST/hooks/effort-reminder.sh"
ln -sfn "$DOTDIR/claude/hooks/effort-reminder.txt" "$DST/hooks/effort-reminder.txt"
chmod +x "$DOTDIR/claude/hooks/ensure-harness.sh" "$DOTDIR/claude/hooks/effort-reminder.sh"
echo "  ✓ hooks linked (ensure-harness, effort-reminder)"

# ultracode 설정 파일(--settings 로 넘길 용도) — 항상 최신본 링크
ln -sfn "$DOTDIR/claude/ultracode.json" "$DST/ultracode.json"
echo "  ✓ ultracode.json linked"

# CLAUDE.md (전역 세션 기본값): 없으면/심링크면 링크(업데이트 자동 반영),
# 실제 파일이면 dotfiles 관리 블록을 마커 사이에 삽입/갱신(마커 밖 사용자 내용 보존).
if [ -L "$DST/CLAUDE.md" ] || [ ! -e "$DST/CLAUDE.md" ]; then
  ln -sfn "$DOTDIR/claude/CLAUDE.md" "$DST/CLAUDE.md"
  echo "  ✓ CLAUDE.md linked"
else
  python3 - "$DST/CLAUDE.md" "$DOTDIR/claude/CLAUDE.md" <<'PY'
import sys
dst,src=sys.argv[1],sys.argv[2]
body=open(src,encoding='utf-8').read().rstrip('\n')
START='<!-- dotfiles:claude-md:start (auto-generated; updated on reinstall) -->'
START_TOK='<!-- dotfiles:claude-md:start'
END='<!-- dotfiles:claude-md:end -->'
block=START+'\n'+body+'\n'+END
try: cur=open(dst,encoding='utf-8').read()
except FileNotFoundError: cur=None
i=cur.find(START_TOK) if cur is not None else -1
j=cur.find(END) if cur is not None else -1
if cur is None:
    out=block+'\n'
elif i>=0 and j>=i:
    out=cur[:i]+block+cur[j+len(END):]
else:
    out=cur.rstrip('\n')+'\n\n'+block+'\n'
open(dst,'w',encoding='utf-8').write(out)
PY
  echo "  ✓ CLAUDE.md dotfiles 블록 삽입/갱신 (마커 밖 사용자 내용 보존)"
fi

# settings: 없으면 링크, 있으면 머지(기존 보존)
if [ -L "$DST/settings.json" ] || [ ! -e "$DST/settings.json" ]; then
  ln -sfn "$DOTDIR/claude/settings.json" "$DST/settings.json"
  echo "  ✓ settings linked"
else
  cp -p "$DST/settings.json" "$DST/settings.json.bak.$(date +%s)"
  python3 - "$DST/settings.json" "$DOTDIR/claude/settings.json" <<'PY'
import json,sys
dst,src=sys.argv[1],sys.argv[2]
d=json.load(open(dst)); s=json.load(open(src))
d.setdefault("extraKnownMarketplaces",{}).update(s["extraKnownMarketplaces"])
d.setdefault("enabledPlugins",{}).update(s["enabledPlugins"])
d.setdefault("effortLevel", s.get("effortLevel","xhigh"))  # 없을 때만 — 사용자 선택 보존
ss=d.setdefault("hooks",{}).setdefault("SessionStart",[])
# 자가 치유 dedup: 명령 집합이 완전히 동일한 중복 그룹 제거(순서 보존)
seen=set(); dedup=[]
for g in ss:
    key=tuple(h.get("command") for h in g.get("hooks",[]))
    if key and key in seen: continue
    if key: seen.add(key)
    dedup.append(g)
ss=dedup
have={h.get("command") for g in ss for h in g.get("hooks",[])}
for g in s["hooks"]["SessionStart"]:
    for h in g["hooks"]:
        if h["command"] not in have:
            ss.append({"hooks":[{"type":"command","command":h["command"]}]}); have.add(h["command"])
d["hooks"]["SessionStart"]=ss
json.dump(d,open(dst,"w"),indent=2,ensure_ascii=False); open(dst,"a").write("\n")
PY
  echo "  ✓ settings merged (기존 보존, 백업됨)"
fi

# `claude` → ultracode 자동: 셸 rc 에 함수 오버라이드 source (idempotent)
add_func() {
  local rc="$1"
  [ -e "$rc" ] || return 0
  if ! grep -q "dotfiles:claude-ultra" "$rc" 2>/dev/null; then
    printf '\n# dotfiles:claude-ultra\nsource "%s/claude/shell/claude-ultra.sh"\n' "$DOTDIR" >> "$rc"
    echo "  ✓ claude override → $(basename "$rc")"
  fi
}
add_func "$HOME/.bashrc"
add_func "$HOME/.zshrc"
if [ ! -e "$HOME/.bashrc" ] && [ ! -e "$HOME/.zshrc" ]; then
  printf '# dotfiles:claude-ultra\nsource "%s/claude/shell/claude-ultra.sh"\n' "$DOTDIR" > "$HOME/.bashrc"
  echo "  ✓ claude override → new .bashrc"
fi

# 즉시 설치
if command -v claude >/dev/null 2>&1; then
  claude plugin marketplace add revfactory/harness  >/dev/null 2>&1 || true
  claude plugin install harness@harness-marketplace >/dev/null 2>&1 || true
  echo "  ✓ harness installed"
  claude plugin marketplace add Yeachan-Heo/oh-my-claudecode >/dev/null 2>&1 || true
  claude plugin install oh-my-claudecode@omc               >/dev/null 2>&1 || true
  echo "  ✓ oh-my-claudecode installed (/deep-interview, /ralph)"
  for p in vercel hookify security-guidance skill-creator plugin-dev mcp-server-dev frontend-design playwright context7 github; do
    claude plugin install "$p@claude-plugins-official" >/dev/null 2>&1 || true
  done
  echo "  ✓ official plugins installed (vercel, hookify, security-guidance, skill-creator, plugin-dev, mcp-server-dev, frontend-design, playwright, context7, github)"
  echo "  i  github MCP needs env GITHUB_PERSONAL_ACCESS_TOKEN (set per machine; never commit)"
  claude plugin list 2>/dev/null | grep -E "harness|oh-my-claudecode|hookify|security-guidance|skill-creator|plugin-dev|mcp-server-dev|frontend-design|playwright|context7|github|vercel|Status" || true
else
  echo "  ℹ claude 미설치 — 다음 세션 훅이 설치"
fi
echo "✓ 완료. effortLevel=xhigh 영구 + ultracode 자동(claude 오버라이드) + harness 자동."
echo "  (새 터미널을 열어야 claude 오버라이드가 적용됩니다.)"
