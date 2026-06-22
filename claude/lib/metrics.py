#!/usr/bin/env python3
# claude-config:metrics.py - aggregation engine for the lifelong-orchestrator growth metrics.
#   Shared by metrics.sh and metrics.ps1 (DRY -> guaranteed cross-platform parity).
#   Reads $MEM/events/*.jsonl (union across machine shards), derives $MEM/metrics.md
#   (plan v9 0-J "metrics.md = mode-A derive" / v10 T1-G4 measurement surface + G5 tuning).
#   PRIVATE only. Deterministic (same events -> same metrics.md modulo generated_at). Fail-open.
# Usage: python3 metrics.py <memdir> <rework_warn_rate> <debug:0|1>
import os, sys, json, glob, time
from collections import Counter

def main():
    if len(sys.argv) < 2:
        return
    mem = sys.argv[1]
    warn = float(sys.argv[2]) if len(sys.argv) > 2 else 0.30
    dbg = len(sys.argv) > 3 and sys.argv[3] == '1'

    evdir = os.path.join(mem, 'events')
    rows = []
    for fp in sorted(glob.glob(os.path.join(evdir, '*.jsonl'))):
        try:
            with open(fp, encoding='utf-8') as f:
                for ln in f:
                    ln = ln.strip()
                    if not ln:
                        continue
                    try:
                        rows.append(json.loads(ln))
                    except Exception:
                        pass
        except Exception:
            pass

    total = len(rows)
    bytype = Counter(r.get('type', '?') for r in rows)
    rew = [r for r in rows if r.get('rework') is True]
    rework_rate = (len(rew) / total) if total else 0.0
    recall_ev = [r for r in rows if r.get('type') == 'recall']
    recall_hit = [r for r in recall_ev if r.get('recall_hit') is True]
    recall_rate = (len(recall_hit) / len(recall_ev)) if recall_ev else 0.0
    snaps = [r for r in rows if r.get('type') == 'snapshot']
    latest = snaps[-1] if snaps else None
    counts = (latest.get('counts') or {}) if latest else {}
    last_snap_ts = latest.get('ts') if latest else None
    label_n = max([(r.get('label_n') or 0) for r in rows], default=0)
    gate_susp = bool(rows[-1].get('gate_suspended', True)) if rows else True
    # cold-start proxies (v9 0-J): re-ask / anchor-reinject totals
    reask = sum((r.get('reask_count') or 0) for r in rows)
    reinject = sum((r.get('anchor_reinject_count') or 0) for r in rows)
    # T4 데이터화 확장: 산출물 품질/결과/소요 (선택 필드, 있을 때만)
    ratings = [r.get('user_rating') for r in rows
               if isinstance(r.get('user_rating'), (int, float)) and not isinstance(r.get('user_rating'), bool)]
    avg_rating = (sum(ratings) / len(ratings)) if ratings else None
    outcomes = Counter(r.get('outcome') for r in rows if r.get('outcome'))
    durs = [r.get('duration_ms') for r in rows
            if isinstance(r.get('duration_ms'), (int, float)) and not isinstance(r.get('duration_ms'), bool)]
    avg_dur = (sum(durs) / len(durs)) if durs else None
    stale = [r for r in rows if (r.get('backup') or {}).get('result') == 'reconcile-stale']
    stale_age = max([(r.get('pending_age_days') or 0) for r in stale], default=0)

    gen = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    L = []
    L.append('# metrics.md - lifelong orchestrator growth health (mode-A derive)')
    L.append('')
    L.append('> Auto-derived from events/*.jsonl union. PRIVATE. Do not hand-edit.')
    L.append('')
    L.append('generated_at: %s' % gen)
    L.append('total_events: %d' % total)
    L.append('by_type: %s' % (', '.join('%s=%d' % (k, v) for k, v in sorted(bytype.items())) or '(none)'))
    L.append('latest_counts: skills=%s wiki=%s profile_keys=%s digest_files=%s' % (
        counts.get('skills', 0), counts.get('wiki', 0), counts.get('profile_keys', 0), counts.get('digest_files', 0)))
    L.append('last_snapshot_ts: %s' % (last_snap_ts or '(none)'))
    L.append('rework_rate: %.3f (n_rework=%d / total=%d)' % (rework_rate, len(rew), total))
    L.append('recall_hit_rate: %.3f (hits=%d / recall_events=%d)' % (recall_rate, len(recall_hit), len(recall_ev)))
    L.append('cold_start_proxies: reask_total=%d anchor_reinject_total=%d' % (reask, reinject))
    if ratings:
        L.append('user_rating_avg: %.2f (n=%d)' % (avg_rating, len(ratings)))
    if outcomes:
        L.append('outcomes: %s' % ', '.join('%s=%d' % (k, v) for k, v in sorted(outcomes.items())))
    if durs:
        L.append('duration_ms_avg: %d (n=%d)' % (int(avg_dur), len(durs)))
    L.append('label_n: %d  gate_suspended: %s' % (label_n, str(gate_susp).lower()))
    L.append('reconcile_stale: %s%s' % ('yes' if stale else 'no', (' (max_age_days=%d)' % stale_age) if stale else ''))
    L.append('')
    L.append('## TUNING (objective: rework DOWN [1] > recall-hit UP [2] > token-cost CONSTRAINT)')
    tuning = []
    if total and rework_rate > warn:
        tuning.append('rework_rate %.3f > %.2f -> review recent rework; consider recall-budget / routing tuning' % (rework_rate, warn))
    if stale:
        tuning.append('reconcile-stale present (age %d d) -> run /reconcile to apply _pending backlog' % stale_age)
    if label_n < 30:
        tuning.append('label_n %d < 30 -> precision/recall gate suspended (cold-start); label more to open M-A2 gate' % label_n)
    if ratings and avg_rating < 3.0:
        tuning.append('user_rating_avg %.2f < 3.0 -> 산출물 품질 점검 (recall-budget / routing 재튜닝 검토)' % avg_rating)
    if tuning:
        for t in tuning:
            L.append('- %s' % t)
    else:
        L.append('- (no tuning signals; within thresholds)')

    content = '\n'.join(L) + '\n'
    out = os.path.join(mem, 'metrics.md')
    try:
        with open(out, 'w', encoding='utf-8', newline='\n') as f:
            f.write(content)
    except Exception as e:
        if dbg:
            sys.stderr.write('metrics.py: write failed: %r\n' % (e,))
        return
    if dbg:
        sys.stderr.write('metrics.py: wrote %s (total=%d rework=%.3f recall=%.3f stale=%s)\n' % (
            out, total, rework_rate, recall_rate, 'yes' if stale else 'no'))

try:
    main()
except Exception:
    pass  # fail-open
