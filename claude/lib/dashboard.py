#!/usr/bin/env python3
# claude-config:dashboard.py - read-only human-facing growth dashboard (v10 T2 휴먼레이어).
#   Shared by `claude-status` in claude-ultra.{sh,ps1} (DRY -> cross-platform parity).
#   Renders a friendly snapshot of the PRIVATE lifelong-memory store: accumulation counts,
#   metrics.md health, recent decisions, unreconciled _pending, and any tuning signals.
#   READ-ONLY (never writes). PRIVATE-read only. Deterministic. Fail-open (prints a hint, exit 0).
# Usage: python3 dashboard.py <memdir>
import os, sys, glob, time

def main():
    if len(sys.argv) < 2:
        print("dashboard: no memory dir resolved.")
        return
    mem = sys.argv[1]
    if not os.path.isdir(mem):
        print("dashboard: memory store not found yet (%s)." % mem)
        print("  -> 첫 세션 후 자동 생성됩니다. 또는 bootstrap 한 줄 실행.")
        return

    def count_md(sub):
        d = os.path.join(mem, sub); n = 0
        if os.path.isdir(d):
            for dp, _, fs in os.walk(d):
                n += sum(1 for f in fs if f.endswith('.md'))
        return n

    # accumulation counts (deterministic)
    decisions = count_md('decisions')
    pend_files = []
    pdir = os.path.join(mem, '_pending')
    if os.path.isdir(pdir):
        for dp, _, fs in os.walk(pdir):
            pend_files += [os.path.join(dp, f) for f in fs if f.endswith('.md')]
    # events total (union of shards)
    ev_total = 0
    for fp in glob.glob(os.path.join(mem, 'events', '*.jsonl')):
        try:
            with open(fp, encoding='utf-8') as f:
                ev_total += sum(1 for ln in f if ln.strip())
        except Exception:
            pass
    # profile keys
    pk = 0
    prof = os.path.join(mem, 'profile', 'user-profile.json')
    if os.path.isfile(prof):
        try:
            import json
            o = json.load(open(prof, encoding='utf-8'))
            META = {"schema_version", "updated_at", "updated_by"}
            pk = sum(1 for k in o if k not in META) if isinstance(o, dict) else 0
        except Exception:
            pk = 0

    print("=" * 56)
    print(" Claude 성장 대시보드 (lifelong memory)")
    print("=" * 56)
    print(" 누적: 프로필키 %d | 결정 %d | 미반영제안 %d | 이벤트 %d" % (pk, decisions, len(pend_files), ev_total))

    # _pending detail
    if pend_files:
        oldest = min((os.path.getmtime(p) for p in pend_files), default=None)
        age = int((time.time() - oldest) // 86400) if oldest else 0
        flag = "  ⚠ /reconcile 권장" if age >= 7 else ""
        print(" 미반영 제안: %d건 (가장 오래된 %d일)%s" % (len(pend_files), age, flag))

    # metrics.md health
    mp = os.path.join(mem, 'metrics.md')
    print("-" * 56)
    if os.path.isfile(mp):
        print(" 성장 헬스 (metrics.md):")
        try:
            keep = ("total_events", "by_type", "rework_rate", "recall_hit_rate",
                    "cold_start_proxies", "label_n", "reconcile_stale")
            tuning = []
            in_tuning = False
            for ln in open(mp, encoding='utf-8'):
                s = ln.rstrip("\n")
                if s.startswith("## TUNING"):
                    in_tuning = True; continue
                if in_tuning and s.startswith("- "):
                    tuning.append(s)
                elif any(s.startswith(k + ":") for k in keep):
                    print("   " + s)
            if tuning:
                print(" 튜닝 신호:")
                for t in tuning:
                    print("   " + t)
        except Exception:
            print("   (metrics.md 읽기 실패)")
    else:
        print(" 성장 헬스: metrics.md 아직 없음 (세션 종료 후 자동 생성).")

    # recent decisions
    ddir = os.path.join(mem, 'decisions')
    decs = []
    if os.path.isdir(ddir):
        for dp, _, fs in os.walk(ddir):
            decs += [os.path.join(dp, f) for f in fs if f.endswith('.md')]
    if decs:
        try:
            decs.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        except Exception:
            pass
        print("-" * 56)
        print(" 최근 결정 %d:" % min(5, len(decs)))
        for p in decs[:5]:
            t = None
            try:
                for ln in open(p, encoding='utf-8'):
                    if ln.strip().startswith('# '):
                        t = ln.strip()[2:].strip(); break
            except Exception:
                pass
            print("   - " + (t or os.path.splitext(os.path.basename(p))[0]))
    print("=" * 56)
    print(" 더: 'claude' 에게 \"성장 대시보드 자세히\"  |  끄기: CLAUDE_EVENTS_OFF=1")

try:
    main()
except Exception:
    print("dashboard: (일시적 오류 — 무시 가능)")
