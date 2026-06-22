#!/usr/bin/env python3
# claude-config:seed-leakwords.py — profile 의 식별토큰을 $CLAUDE_MEMORY_DIR/.leakwords 로 추출 (v9 0-D2).
#   gate2b(bare 실명/도메인 누출 차단)를 활성화한다. UTF-8(한글 실명 포함). PRIVATE·gitignored 파일.
#   콜드스타트(profile 비었거나 placeholder): .leakwords 미생성 → gate2b 정직히 비활성 유지(R7).
#   Usage: python3 seed-leakwords.py [memdir]   (없으면 $CLAUDE_MEMORY_DIR)
import sys, os, json, re, unicodedata


def main():
    mem = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('CLAUDE_MEMORY_DIR', '')
    if not mem:
        return
    prof = os.path.join(mem, 'profile', 'user-profile.json')
    toks = set()
    if os.path.isfile(prof):
        try:
            o = json.load(open(prof, encoding='utf-8'))
            idy = (o.get('identity') or {}) if isinstance(o, dict) else {}

            def add(v):
                if isinstance(v, str):
                    v = unicodedata.normalize('NFC', v.strip())
                    if v and not v.startswith('<') and '@' not in v:
                        toks.add(v)

            add(idy.get('display_name'))
            add(idy.get('contact_domain'))
            for v in (idy.get('handles') or {}).values():
                add(v)
            # split a multi-part display name into parts (first/last) for separate matching
            dn = idy.get('display_name')
            if isinstance(dn, str) and not dn.strip().startswith('<'):
                for part in re.split(r'\s+', unicodedata.normalize('NFC', dn.strip())):
                    if len(part) >= 3:
                        toks.add(part)
        except Exception:
            pass

    # filter: >=3 chars, drop placeholders / schema tokens
    drop = {'full_name', 'gh_handle', 'example.com', 'user', 'name'}
    toks = {t for t in toks if len(t) >= 3 and '<' not in t and t.lower() not in drop}

    lw = os.path.join(mem, '.leakwords')
    if not toks:
        sys.stderr.write('seed-leakwords: profile 식별토큰 없음(콜드스타트) → .leakwords 미생성(gate2b 비활성 유지).\n')
        return
    try:
        with open(lw, 'w', encoding='utf-8', newline='\n') as f:
            f.write('# auto-seeded from profile identity (v9 0-D2). PRIVATE·gitignored. gate2b 식별토큰.\n')
            for t in sorted(toks):
                f.write(t + '\n')
        sys.stderr.write('seed-leakwords: %d 토큰 시드 → .leakwords (gate2b 활성).\n' % len(toks))
    except Exception:
        pass


try:
    main()
except Exception:
    pass
