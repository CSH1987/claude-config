#!/usr/bin/env python3
# EversVault 노후화 감지 스캐너 — Phase 3 거버넌스(계획: ~/.omc/plans/eversvault-llm-wiki.md).
# 온디맨드 실행(세션마다 자동주입 아님 — 노후화 점검은 주기적/의도적 행위라 매번 끼워넣으면
# 소음이 된다). 파일시스템 직접스캔만 사용(MCP 불필요, Obsidian이 꺼져 있어도 동작).
# 액션(삭제/수정)은 항상 사람 판단 — 이 스크립트는 후보를 나열만 하고 아무것도 고치지 않는다.
# 스캔 대상은 20_업무위키(canonical, _pending 제외) — 10_컨텍스트는 사람 정본(Claude가 손댈 수
# 없으니 노후화 후보를 나열해도 실행 불가), 90_Hermes는 Hermes 자체 산출 주기가 있어 이 스캐너의
# "노후화=방치" 판정과 성격이 다르다(90_Hermes는 별도로 승격 절차가 다룸).
import sys, os, re, glob, unicodedata
from datetime import date

STALE_DAYS = 90                  # updated 필드가 이보다 오래되면 "오래됨" 후보 (조정 가능한 기본값)
PENDING_PROPOSED_STALE_DAYS = 30  # status:proposed 미검토 경고 임계 (계획서 명시값)
PENDING_APPROVED_STALE_DAYS = 7   # status:approved 미반영 경고 임계 — 코드리뷰 MEDIUM 대응:
                                   # approved는 guard가 무기한 유효한 반영 티켓으로 인정하는 상태라
                                   # proposed보다 짧은 임계로 더 빨리 표면화해야 함(살아있는 쓰기
                                   # 권한이 방치되는 쪽이 검토 대기보다 더 급함).
OVERSIZED_LINES = 300     # 이 줄수 넘으면 "비대 노트" 후보
OVERSIZED_BYTES = 20_000  # 또는 이 바이트수 넘으면

_WIKILINK_RE = re.compile(r'\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]')


def _nfc(s):
    return unicodedata.normalize('NFC', s)


def _split_frontmatter(text):
    """(frontmatter dict, body) 반환. 처음 200줄만 스캔(quadratic 백트래킹 방지 — 기존 관례와 동일)."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != '---':
        return {}, text
    fm, end_idx = {}, None
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


def _all_vault_basenames(vault):
    """볼트 전역 .md 파일의 basename(확장자 제외, NFC, lower) 집합 — 링크 해석용."""
    names = set()
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for f in files:
            if f.endswith('.md'):
                names.add(_nfc(os.path.splitext(f)[0]).lower())
    return names


def _outgoing_links(body):
    """본문의 [[링크]] 대상 basename(확장자 제외, NFC, lower) 목록. 노트 링크만 대상 —
    ![[image.png]] 같은 비-md 첨부 임베드는 제외한다(코드리뷰 MEDIUM 대응: 첨부파일은
    _all_vault_basenames에 없어 그대로 두면 전부 깨진 링크로 오탐)."""
    out = []
    for m in _WIKILINK_RE.finditer(body):
        target = m.group(1).strip().rstrip('\\')  # 표 안 이스케이프 파이프(`\|`) 잔여 백슬래시 제거
        if not target:
            continue
        base = target.rsplit('/', 1)[-1]
        root, ext = os.path.splitext(base)
        if ext:
            if ext.lower() != '.md':
                continue  # 노트가 아닌 첨부(이미지/PDF 등) 임베드 — 이 스캐너의 대상 아님
            base = root
        out.append(_nfc(base).lower())
    return out


def _build_backlink_index(vault):
    """볼트 전역에서 각 note가 발신하는 링크를 모아 {대상basename: 발신 note 경로 집합} 반환."""
    index = {}
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for f in files:
            if not f.endswith('.md'):
                continue
            path = os.path.join(root, f)
            try:
                with open(path, 'r', encoding='utf-8') as fh:
                    text = fh.read()
            except Exception:
                continue
            _, body = _split_frontmatter(text)
            for target in _outgoing_links(body):
                index.setdefault(target, set()).add(path)
    return index


def _parse_date(s):
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})', s or '')
    if not m:
        return None
    try:
        return date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def scan_canonical(vault, category_root, all_basenames, backlink_index, today):
    """20_업무위키 canonical 노트(4종 후보) 스캔. 결과: {stale, broken_links, orphan, oversized} 각 리스트."""
    result = {'stale': [], 'broken_links': [], 'orphan': [], 'oversized': []}
    for path in glob.glob(os.path.join(category_root, '*', '*.md')):
        # _pending은 카테고리 폴더가 아니라 스테이징 영역 — glob 패턴이 우연히 걸러주는 게 아니라
        # 명시적으로 제외한다(코드리뷰 MEDIUM 대응: 기존 eversvault-index.py의 not d.startswith('_')
        # 관례와 동일하게, _pending 안의 2단계 깊이 파일이 canonical로 오분류되던 실측 버그).
        category = os.path.basename(os.path.dirname(path))
        if category.startswith('_'):
            continue
        rel = os.path.relpath(path, vault)
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                text = fh.read()
        except Exception:
            continue
        fm, body = _split_frontmatter(text)

        updated = _parse_date(fm.get('updated', ''))
        via_mtime = False
        if updated is None:
            # updated 필드가 없거나 파싱 불가한 노트가 오히려 가장 방치됐을 가능성이 높은데
            # 조용히 통과시키면 사각지대가 된다(코드리뷰 LOW 대응) — mtime으로 폴백.
            try:
                updated = date.fromtimestamp(os.path.getmtime(path))
                via_mtime = True
            except Exception:
                updated = None
        if updated is not None and (today - updated).days > STALE_DAYS:
            label = rel + (" [updated 필드 없음, mtime 기준]" if via_mtime else "")
            result['stale'].append((label, (today - updated).days))

        broken = []
        for target in _outgoing_links(body):
            if target and target not in all_basenames:
                broken.append(target)
        if broken:
            result['broken_links'].append((rel, sorted(set(broken))))

        own_base = _nfc(os.path.splitext(os.path.basename(path))[0]).lower()
        referrers = backlink_index.get(own_base, set()) - {path}
        if not referrers:
            result['orphan'].append(rel)

        line_count = len(text.splitlines())  # text.count('\n')+1은 개행종료 파일에서 1줄 과다계산
        byte_size = len(text.encode('utf-8'))
        if line_count > OVERSIZED_LINES or byte_size > OVERSIZED_BYTES:
            result['oversized'].append((rel, line_count, byte_size))

    return result


def scan_pending(vault, today):
    """20_업무위키/_pending 방치 제안. status:proposed(검토 대기)와 status:approved(반영 대기 —
    guard가 무기한 유효한 쓰기 티켓으로 인정하는 상태라 더 짧은 임계로 본다, 코드리뷰 MEDIUM 대응)
    를 각각 별도 리스트로 반환: (proposed_stale, approved_stale). 나이는 파일 mtime 기준 —
    _pending 안 편집은 프로토콜상 항상 허용이라 status 전환 자체가 시계를 리셋시킨다는 한계가
    있음(코드리뷰 LOW 대응, 문서 §4에 명시)."""
    proposed_stale, approved_stale = [], []
    for path in glob.glob(os.path.join(vault, '20_업무위키', '_pending', '*', '*.md')):
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                text = fh.read()
        except Exception:
            continue
        fm, _ = _split_frontmatter(text)
        status = fm.get('status')
        if status not in ('proposed', 'approved'):
            continue
        try:
            mtime = date.fromtimestamp(os.path.getmtime(path))
        except Exception:
            continue
        age = (today - mtime).days
        rel = os.path.relpath(path, vault)
        if status == 'proposed' and age > PENDING_PROPOSED_STALE_DAYS:
            proposed_stale.append((rel, age))
        elif status == 'approved' and age > PENDING_APPROVED_STALE_DAYS:
            approved_stale.append((rel, age))
    return proposed_stale, approved_stale


def format_report(result, proposed_stale, approved_stale, today):
    lines = ["[EversVault 노후화 스캔] %s 기준" % today.isoformat()]
    total = sum(len(v) for v in result.values()) + len(proposed_stale) + len(approved_stale)
    if total == 0:
        lines.append("이상 없음 — 4종 후보 전부 0건, _pending 노후 제안도 0건")
        return '\n'.join(lines)

    if result['stale']:
        lines.append("\n## 오래됨 (updated > %d일, %d건)" % (STALE_DAYS, len(result['stale'])))
        for rel, days in sorted(result['stale'], key=lambda x: -x[1]):
            lines.append("- %s (%d일 경과)" % (rel, days))
    if result['broken_links']:
        lines.append("\n## 깨진 링크 (%d건)" % len(result['broken_links']))
        for rel, targets in result['broken_links']:
            lines.append("- %s → [[%s]]" % (rel, ']] [['.join(targets)))
    if result['orphan']:
        lines.append("\n## 고아 노트 (아무 노트도 링크 안 함, %d건)" % len(result['orphan']))
        for rel in result['orphan']:
            lines.append("- %s" % rel)
    if result['oversized']:
        lines.append("\n## 비대 노트 (>%d줄 또는 >%dKB, %d건)"
                      % (OVERSIZED_LINES, OVERSIZED_BYTES // 1000, len(result['oversized'])))
        for rel, lc, bs in result['oversized']:
            lines.append("- %s (%d줄, %.1fKB)" % (rel, lc, bs / 1000))
    if proposed_stale:
        lines.append("\n## _pending 검토대기 방치 (status:proposed, >%d일, %d건)"
                      % (PENDING_PROPOSED_STALE_DAYS, len(proposed_stale)))
        for rel, days in sorted(proposed_stale, key=lambda x: -x[1]):
            lines.append("- %s (%d일 경과)" % (rel, days))
    if approved_stale:
        lines.append("\n## _pending 반영대기 방치 (status:approved — 살아있는 쓰기 티켓, >%d일, %d건)"
                      % (PENDING_APPROVED_STALE_DAYS, len(approved_stale)))
        for rel, days in sorted(approved_stale, key=lambda x: -x[1]):
            lines.append("- %s (%d일 경과)" % (rel, days))

    lines.append("\n(전부 후보 나열일 뿐입니다 — 삭제/수정은 사람이 직접 판단)")
    return '\n'.join(lines)


def main():
    if len(sys.argv) < 2:
        print("usage: eversvault-staleness-scan.py <vault_path>")
        return
    vault = sys.argv[1]
    category_root = os.path.join(vault, '20_업무위키')
    if not os.path.isdir(category_root):
        print("[EversVault 노후화 스캔] 20_업무위키 폴더 없음: %s" % category_root)
        return
    today = date.today()
    all_basenames = _all_vault_basenames(vault)
    backlink_index = _build_backlink_index(vault)
    result = scan_canonical(vault, category_root, all_basenames, backlink_index, today)
    proposed_stale, approved_stale = scan_pending(vault, today)
    print(format_report(result, proposed_stale, approved_stale, today))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        # 사람이 직접 실행하는 온디맨드 CLI라 SessionStart 훅과 달리 실패를 성공 종료코드로
        # 감출 필요가 없다(코드리뷰 LOW 대응 — 스크립트 체이닝 시 오류 은폐 방지).
        print("[EversVault 노후화 스캔] 실패: %s" % e)
        sys.exit(1)
