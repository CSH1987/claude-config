#!/usr/bin/env python3
# Vault 노트 인덱스 생성기 — vault-context.sh(SessionStart 훅)가 호출.
# 10_컨텍스트: 실제 frontmatter에 title/설명 필드가 없음(type/created/updated/review/source/tags뿐) —
#   H1 헤딩=title 폴백, 그 직후 첫 문단=설명 폴백.
# 20_업무위키(--recursive): 카테고리 하위폴더별 순회, ~1500토큰(문자수 근사) 초과시 카테고리별 집계로 롤업.
# 실패해도 예외를 던지지 않는다 — 상위 bash 스크립트가 빈 출력을 "0건"으로 감싸 처리.
import sys, os, re, glob
from datetime import date

# 10_컨텍스트 frontmatter의 review(검토주기) 필드 — 지금까지 어디에서도 파싱/알림되지 않는 죽은
# 필드였다(종합테스트 워크플로 발견). 카테고리형 값(quarterly/on-change 등)이라 날짜가 아니라
# 주기를 뜻함 — 시간 기반 주기만 이 맵에 등록하고, 'on-change'처럼 이벤트 트리거형은 알림 대상
# 밖(None 취급, 항상 최신이라 가정할 수 없어 조용히 넘어간다 — 오탐보다 미탐이 안전한 방향).
_REVIEW_CADENCE_DAYS = {'weekly': 7, 'monthly': 30, 'quarterly': 90, 'yearly': 365, 'annual': 365}

# 1500토큰 상한을 넘지 않는 게 목적이므로, 최악의 경우(가장 조밀한 1.5자/토큰)를 기준으로
# char 예산을 잡아야 진짜 "보수적"이다 — 중간값(2자/토큰=3000자)을 쓰면 실제 텍스트가 조밀할 때
# 목표를 최대 33% 초과할 수 있었다(종합테스트 워크플로 실측 발견, 코드리뷰 대응).
TOKEN_CHAR_BUDGET = int(1500 * 1.5)  # = 2250, 한글 ~1.5~2.5자/토큰 범위의 하한(최다토큰) 기준


def split_frontmatter(text):
    """(frontmatter dict, body) 반환. 라인 단위로 처음 200줄만 스캔 — lazy DOTALL 정규식의
    quadratic 백트래킹(닫는 '---' 없는 파일에서 훅/인덱서 정지) 방지."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != '---':
        return {}, text
    fm = {}
    end_idx = None
    for i, line in enumerate(lines[1:201], start=1):
        if line.strip() == '---':
            end_idx = i
            break
        km = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$', line)
        if km:
            fm[km.group(1)] = km.group(2).strip().strip('"\'')
    if end_idx is None:
        return fm, text
    return fm, ''.join(lines[end_idx + 1:])


def _parse_date(s):
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})', s or '')
    if not m:
        return None
    try:
        return date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def _review_overdue_days(review, updated):
    """review 주기(quarterly 등)와 updated 필드로 검토기한 초과일수 계산. 미적용시 None —
    review 없음/미등록 주기(on-change 등)/updated 파싱불가 전부 조용히 None(과탐보다 미탐 안전).
    updated 필드가 없는 노트는 영구히 미탐이 된다 — vault-staleness-scan.py는 반대로
    mtime 폴백을 쓰는데(그쪽은 "필드 없음=가장 방치됐을 가능성" 논리), 여기(SessionStart 매
    세션 주입)는 소음 민감도가 훨씬 높아 폴백 없이 미탐 쪽을 의도적으로 택했다(코드리뷰 확인)."""
    cadence_days = _REVIEW_CADENCE_DAYS.get((review or '').strip().lower())
    if cadence_days is None:
        return None
    updated_date = _parse_date(updated)
    if updated_date is None:
        return None
    overdue = (date.today() - updated_date).days - cadence_days
    return overdue if overdue > 0 else None


def title_and_desc(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read()
    except Exception:
        return None, None, None, None
    fm, body = split_frontmatter(text)
    h1 = re.search(r'^#\s+(.+)$', body, re.MULTILINE)
    title = h1.group(1).strip() if h1 else os.path.splitext(os.path.basename(path))[0]
    desc = ''
    if h1:
        after = body[h1.end():].lstrip('\n')
        para = after.split('\n\n', 1)[0].strip()
        desc = re.sub(r'\s+', ' ', para)[:100]
    updated = fm.get('updated', '')
    review = fm.get('review', '')
    return title, desc, updated, review


def collect(folder):
    items = []
    for path in sorted(glob.glob(os.path.join(folder, '*.md'))):
        title, desc, updated, review = title_and_desc(path)
        if title is None:
            continue
        overdue_days = _review_overdue_days(review, updated)
        items.append({'title': title, 'desc': desc, 'updated': updated, 'overdue_days': overdue_days})
    return items


def line_for(it):
    base = ("- %s: %s" % (it['title'], it['desc'])) if it['desc'] else ("- %s" % it['title'])
    if it.get('overdue_days'):
        base += " [⚠ 검토기한 %d일 초과]" % it['overdue_days']
    return base


def format_flat(items, label):
    if not items:
        return "[Vault %s] 인덱스 0건" % label
    header = "[Vault %s] %d개 노트" % (label, len(items))
    lines = [header] + [line_for(it) for it in items]
    out = '\n'.join(lines)
    if len(out) <= TOKEN_CHAR_BUDGET:
        return out
    # 최신순 정렬 후, 검토기한 초과 항목을 안정정렬로 앞으로 끌어올린다 — 초과 노트는 정의상
    # updated가 가장 오래돼 항상 맨 뒤로 밀려 예산 초과시 가장 먼저 잘리던 문제(코드리뷰 MEDIUM
    # 대응: 경고가 정작 필요한 대형 볼트에서 조용히 사라지는 실패모드). 안정정렬이라 각 그룹
    # 내부의 최신순은 그대로 유지됨.
    items_sorted = sorted(items, key=lambda x: x['updated'], reverse=True)
    items_sorted = sorted(items_sorted, key=lambda x: 0 if x.get('overdue_days') else 1)
    kept, total = [], len(header) + 1
    for it in items_sorted:
        line = line_for(it)
        if total + len(line) + 1 > TOKEN_CHAR_BUDGET:
            break
        kept.append(line)
        total += len(line) + 1
    cut = items_sorted[len(kept):]
    remaining = len(cut)
    result = [header] + kept
    if remaining > 0:
        cut_overdue = sum(1 for it in cut if it.get('overdue_days'))
        more_line = "+%d개 더, Read/검색으로 확인" % remaining
        if cut_overdue:
            more_line += " (검토기한 초과 %d건 포함)" % cut_overdue
        result.append(more_line)
    return '\n'.join(result)


def format_recursive(root, label):
    try:
        categories = sorted(d for d in os.listdir(root)
                             if os.path.isdir(os.path.join(root, d)) and not d.startswith('_'))
    except Exception:
        return "[Vault %s] 인덱스 0건 (폴더 접근 실패)" % label
    if not categories:
        return "[Vault %s] 인덱스 0건 (카테고리 폴더 없음)" % label

    all_items = {cat: collect(os.path.join(root, cat)) for cat in categories}
    total_count = sum(len(v) for v in all_items.values())
    if total_count == 0:
        return "[Vault %s] 인덱스 0건 (모든 카테고리 비어있음)" % label

    header = "[Vault %s] %d개 노트 (%d개 카테고리)" % (label, total_count, len(categories))
    full_lines = [header]
    for cat in categories:
        items = all_items[cat]
        if not items:
            continue
        full_lines.append("## %s (%d개)" % (cat, len(items)))
        full_lines.extend(line_for(it) for it in items)
    full_text = '\n'.join(full_lines)
    if len(full_text) <= TOKEN_CHAR_BUDGET:
        return full_text

    rollup_lines = [header]
    for cat in categories:
        items = all_items[cat]
        if not items:
            continue
        latest = max((it['updated'] for it in items if it['updated']), default='?')
        rollup_lines.append("- %s: %d개 노트, 최근갱신 %s (Read/검색으로 확인)" % (cat, len(items), latest))
    return '\n'.join(rollup_lines)


def main():
    if len(sys.argv) < 2:
        return
    folder = sys.argv[1]
    recursive = '--recursive' in sys.argv[2:]
    label = os.path.basename(folder.rstrip('/'))
    if not os.path.isdir(folder):
        print("[Vault %s] 폴더 없음" % label)
        return
    print(format_recursive(folder, label) if recursive else format_flat(collect(folder), label))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass
