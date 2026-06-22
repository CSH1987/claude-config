#!/usr/bin/env python3
# claude-config:brief.py - shared engine for the SessionStart "morning brief" (v10 T2 휴먼레이어).
#   Shared by morning-brief.sh and morning-brief.ps1 (DRY -> guaranteed cross-platform parity).
#   System->human reminding channel: surfaces what the user may have forgotten (unreconciled
#   _pending, reconcile-stale age, recent decisions, growth health from metrics.md).
#   - Throttled to once per UTC day via $MEM/.last-brief.
#   - Prints a SessionStart additionalContext JSON to stdout (Claude relays to the user), or
#     nothing when already briefed today / nothing noteworthy / cold-start.
#   PRIVATE-read only (writes only the throttle marker). Deterministic. Fail-open.
# Usage: python3 brief.py <memdir> <todayYYYYMMDD> [debug:0|1]
import os, sys, glob, json, time

def main():
    if len(sys.argv) < 3:
        return
    mem, today = sys.argv[1], sys.argv[2]
    dbg = len(sys.argv) > 3 and sys.argv[3] == '1'
    marker = os.path.join(mem, '.last-brief')

    # throttle: already briefed today -> stay silent
    try:
        if today and os.path.isfile(marker):
            with open(marker, encoding='utf-8') as f:
                if f.read().strip() == today:
                    if dbg: sys.stderr.write('brief.py: already briefed %s, skip\n' % today)
                    return
    except Exception:
        pass

    lines = []

    # 1) unreconciled _pending (+ oldest age)
    pdir = os.path.join(mem, '_pending')
    pend = []; oldest = None
    if os.path.isdir(pdir):
        for dp, _, fs in os.walk(pdir):
            for f in fs:
                if f.endswith('.md'):
                    p = os.path.join(dp, f); pend.append(p)
                    try:
                        m = os.path.getmtime(p)
                        if oldest is None or m < oldest: oldest = m
                    except Exception:
                        pass
    if pend:
        age = int((time.time() - oldest) // 86400) if oldest else 0
        tail = " (가장 오래된 %d일 -> /reconcile 권장)" % age if age >= 7 else ""
        lines.append("- 미반영 제안(_pending): %d건%s" % (len(pend), tail))

    # 2) recent decisions (newest 3, title from first '# ' heading else filename)
    ddir = os.path.join(mem, 'decisions')
    decs = []
    if os.path.isdir(ddir):
        for dp, _, fs in os.walk(ddir):
            for f in fs:
                if f.endswith('.md'):
                    decs.append(os.path.join(dp, f))
    try:
        decs.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    except Exception:
        pass

    def title(p):
        try:
            with open(p, encoding='utf-8') as f:
                for ln in f:
                    s = ln.strip()
                    if s.startswith('# '):
                        return s[2:].strip()
        except Exception:
            pass
        return os.path.splitext(os.path.basename(p))[0]

    if decs:
        lines.append("- 최근 결정: " + " / ".join(title(p) for p in decs[:3]))

    # 3) growth health from metrics.md
    mp = os.path.join(mem, 'metrics.md')
    if os.path.isfile(mp):
        try:
            g = {}
            with open(mp, encoding='utf-8') as f:
                for ln in f:
                    for k in ("total_events", "rework_rate", "recall_hit_rate", "reconcile_stale"):
                        if ln.startswith(k + ":"):
                            g[k] = ln.split(":", 1)[1].strip()
            parts = []
            if "total_events" in g: parts.append("이벤트 " + g["total_events"])
            if "rework_rate" in g: parts.append("재작업율 " + g["rework_rate"].split()[0])
            if "recall_hit_rate" in g: parts.append("회상적중 " + g["recall_hit_rate"].split()[0])
            if g.get("reconcile_stale", "").startswith("yes"): parts.append("정체 있음")
            if parts:
                lines.append("- 성장 현황: " + " · ".join(parts))
        except Exception:
            pass

    # write throttle marker (we ran the check today) regardless of content
    try:
        with open(marker, 'w', encoding='utf-8', newline='\n') as f:
            f.write(today or '')
    except Exception:
        pass

    if not lines:
        if dbg: sys.stderr.write('brief.py: nothing to brief (silent)\n')
        return

    header = ("[모닝 브리핑 - 시스템이 당신 대신 기억한 것 (오늘 첫 세션)]\n"
              "아래는 사용자가 잊었을 수 있는 항목입니다. 필요하면 자연스럽게 상기시켜 주세요.")
    ctx = header + "\n" + "\n".join(lines)
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    if dbg: sys.stderr.write('brief.py: emitted %d lines\n' % len(lines))

try:
    main()
except Exception:
    pass  # fail-open
