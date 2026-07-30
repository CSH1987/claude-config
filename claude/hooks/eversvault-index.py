#!/usr/bin/env python3
# EversVault 노트 인덱스 생성기 — eversvault-context.sh(SessionStart 훅)가 호출.
# 10_컨텍스트: 실제 frontmatter에 title/설명 필드가 없음(type/created/updated/review/source/tags뿐) —
#   H1 헤딩=title 폴백, 그 직후 첫 문단=설명 폴백.
# 20_업무위키(--recursive): 카테고리 하위폴더별 순회, ~1500토큰(문자수 근사) 초과시 카테고리별 집계로 롤업.
# 실패해도 예외를 던지지 않는다 — 상위 bash 스크립트가 빈 출력을 "0건"으로 감싸 처리.
import sys, os, re, glob

TOKEN_CHAR_BUDGET = 1500 * 2  # 1500토큰 근사 — 한글은 ~1.5~2.5자/토큰이라 보수적으로 2자/토큰 적용


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


def title_and_desc(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read()
    except Exception:
        return None, None, None
    fm, body = split_frontmatter(text)
    h1 = re.search(r'^#\s+(.+)$', body, re.MULTILINE)
    title = h1.group(1).strip() if h1 else os.path.splitext(os.path.basename(path))[0]
    desc = ''
    if h1:
        after = body[h1.end():].lstrip('\n')
        para = after.split('\n\n', 1)[0].strip()
        desc = re.sub(r'\s+', ' ', para)[:100]
    updated = fm.get('updated', '')
    return title, desc, updated


def collect(folder):
    items = []
    for path in sorted(glob.glob(os.path.join(folder, '*.md'))):
        title, desc, updated = title_and_desc(path)
        if title is None:
            continue
        items.append({'title': title, 'desc': desc, 'updated': updated})
    return items


def line_for(it):
    return ("- %s: %s" % (it['title'], it['desc'])) if it['desc'] else ("- %s" % it['title'])


def format_flat(items, label):
    if not items:
        return "[EversVault %s] 인덱스 0건" % label
    header = "[EversVault %s] %d개 노트" % (label, len(items))
    lines = [header] + [line_for(it) for it in items]
    out = '\n'.join(lines)
    if len(out) <= TOKEN_CHAR_BUDGET:
        return out
    items_sorted = sorted(items, key=lambda x: x['updated'], reverse=True)
    kept, total = [], len(header) + 1
    for it in items_sorted:
        line = line_for(it)
        if total + len(line) + 1 > TOKEN_CHAR_BUDGET:
            break
        kept.append(line)
        total += len(line) + 1
    remaining = len(items) - len(kept)
    result = [header] + kept
    if remaining > 0:
        result.append("+%d개 더, Read/검색으로 확인" % remaining)
    return '\n'.join(result)


def format_recursive(root, label):
    try:
        categories = sorted(d for d in os.listdir(root)
                             if os.path.isdir(os.path.join(root, d)) and not d.startswith('_'))
    except Exception:
        return "[EversVault %s] 인덱스 0건 (폴더 접근 실패)" % label
    if not categories:
        return "[EversVault %s] 인덱스 0건 (카테고리 폴더 없음)" % label

    all_items = {cat: collect(os.path.join(root, cat)) for cat in categories}
    total_count = sum(len(v) for v in all_items.values())
    if total_count == 0:
        return "[EversVault %s] 인덱스 0건 (모든 카테고리 비어있음)" % label

    header = "[EversVault %s] %d개 노트 (%d개 카테고리)" % (label, total_count, len(categories))
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
        print("[EversVault %s] 폴더 없음" % label)
        return
    print(format_recursive(folder, label) if recursive else format_flat(collect(folder), label))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass
