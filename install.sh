#!/usr/bin/env bash
# Claude dotfiles 설치 — 이 머신의 모든 폴더·세션에서 Harness 자동.
set -euo pipefail
DOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.claude"
mkdir -p "$DST/hooks"

# 훅 링크
ln -sfn "$DOTDIR/claude/hooks/ensure-harness.sh" "$DST/hooks/ensure-harness.sh"
chmod +x "$DOTDIR/claude/hooks/ensure-harness.sh"
echo "  ✓ hook linked"

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
cmd=s["hooks"]["SessionStart"][0]["hooks"][0]["command"]
ss=d.setdefault("hooks",{}).setdefault("SessionStart",[])
if cmd not in {h.get("command") for g in ss for h in g.get("hooks",[])}:
    ss.append({"hooks":[{"type":"command","command":cmd}]})
json.dump(d,open(dst,"w"),indent=2,ensure_ascii=False); open(dst,"a").write("\n")
PY
  echo "  ✓ settings merged (기존 보존, 백업됨)"
fi

# 즉시 설치
if command -v claude >/dev/null 2>&1; then
  claude plugin marketplace add revfactory/harness  >/dev/null 2>&1 || true
  claude plugin install harness@harness-marketplace >/dev/null 2>&1 || true
  echo "  ✓ harness installed"
  claude plugin list 2>/dev/null | grep -E "harness|Status" || true
else
  echo "  ℹ claude 미설치 — 다음 세션 훅이 설치"
fi
echo "✓ 완료. 이 머신 전체에서 Harness 자동."
