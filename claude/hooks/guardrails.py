#!/usr/bin/env python3
# claude-config global PreToolUse guardrail (single source of logic; the .ps1/.sh wrappers call this).
# FAIL-OPEN by contract: on ANY error, or no match, print nothing and exit 0 -> the tool is allowed.
# BLOCK only unambiguously CATASTROPHIC commands; WARN on dangerous ones + secret-file edits.
# Block format (Claude Code PreToolUse): {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}, "systemMessage": "..."}
# Warn format: {"systemMessage": "..."}   |   Allow: print nothing.
import sys, json, re


def _out(obj):
    try:
        sys.stdout.write(json.dumps(obj))
    except Exception:
        pass


# A token only counts as CATASTROPHIC when it BEGINS a command (start-of-input or after a shell
# separator), optionally via sudo. So the same literal inside quotes / commit messages / here-docs
# (e.g. git commit -m "... rm -rf / ...", echo, a heredoc writing an install script) does NOT block.
# Conservative on purpose: a miss falls through to WARN/allow (fail-open); a false block is the worst case.
_CMD = r'(?:^|[;&|(]|&&|\|\||\$\()\s*(?:sudo\s+)?'

CATASTROPHIC = [
    (_CMD + r'rm\s+-\S*r\S*\s+/(\s|$|\*)',                       'rm -rf on / (root)'),
    (_CMD + r'rm\s+-\S*r\S*\s+~(/\*|\s|$)',                      'rm -rf on ~ (home)'),
    (_CMD + r'rm\s+-\S*r\S*\s+\$\{?HOME\}?',                     'rm -rf on $HOME'),
    (_CMD + r':\s*\(\s*\)\s*\{\s*:\s*\|\s*:?\s*&?\s*\}\s*;\s*:', 'fork bomb'),
    (_CMD + r'mkfs\.',                                           'mkfs (format a filesystem)'),
    (_CMD + r'dd\b[^\n]*\bof=/dev/(sd|nvme|hd|vd|disk)',         'dd onto a raw disk device'),
]

# WARN-only: dangerous but sometimes legitimate, or hard to anchor (redirects are positional) -> never block.
DANGEROUS = [
    (r'\brm\s+-\S*r\S*f|\brm\s+-\S*f\S*r',     'recursive force delete (rm -rf) - double-check the path'),
    (r'>\s*/dev/(sd|nvme|hd|vd|disk)[a-z0-9]', 'redirect onto a raw disk device'),
    (r'\bchmod\s+-?\S*\s*777\b',               'chmod 777 (world-writable)'),
    (r'\bgit\s+push\b[^\n]*(--force\b|--force-with-lease\b|\s-f\b)', 'git force-push - can overwrite remote history'),
    (r'\bgit\s+reset\s+--hard\b',              'git reset --hard - discards local changes'),
    (r'\bgit\s+clean\s+-\S*f',                 'git clean -f - deletes untracked files'),
    (r'\bsudo\s+rm\b',                         'sudo rm'),
]

SECRET = (r'(^|/)\.env($|\.)|\.envrc$|\.(pem|key|p12|pfx|jks|keystore|ppk|p8)$|'
          r'(^|/)id_(rsa|ed25519|dsa|ecdsa)$|\.(npmrc|netrc|pgpass|pypirc)$|'
          r'(service[-_]account|credentials).*\.json$|(^|/)\.(aws|kube|ssh)/|'
          r'\.tfstate$|secrets?\.(ya?ml|json|env)$')


# ---------------------------------------------------------------------------
# EversVault(옵시디언 LLM위키) 가드 — 계획: ~/.omc/plans/eversvault-llm-wiki.md
# 완전히 격리된 부가 블록: 이 블록의 어떤 예외도 위 CATASTROPHIC/DANGEROUS/SECRET 검사에
# 영향을 주지 않는다(맥미니 전용, scope.json 로딩 실패는 이 블록만 조용히 무력화).
# 위협모델: 협조적 에이전트의 실수 방지용이지 적대적 방어가 아님(fail-open 계약 그대로 상속).
# ---------------------------------------------------------------------------
# 쓰기를 시사하는 명령/연산자 토큰(코드리뷰 HIGH#2·3·4 대응 — 개별 연산자 정규식은 cp -r, mv -f,
# chmod -R, macOS BSD sed -i '' 같은 흔한 플래그 변형에서 캡처가 밀려 뚫림. shlex 토큰 스캔으로 전환:
# "쓰기표시 토큰이 있고" + "어떤 토큰이든 보호경로로 정규화되면" 차단 — 위치 의존 캡처 자체를 없앤다.
_EV_WRITE_MARKER_WORDS = {
    'rm', 'cp', 'mv', 'rsync', 'tee', 'dd', 'install', 'ln', 'truncate',
    'sed', 'chmod', 'chown', 'shred', 'shutil',
}
# 실제 파일에 쓰는 리다이렉션만 표시로 취급 — `2>/dev/null`·`2>&1`·`&>/dev/null`처럼 에러 억제용으로
# 흔히 쓰이는 관용구(거의 모든 Bash 명령에 등장)를 오탐하면 정당한 읽기 작업까지 막아버린다
# (실측으로 발견: 순수 `ls ... 2>/dev/null`이 차단됐었음 — 반드시 고쳐야 하는 회귀였다).
_EV_REDIRECT_RE = re.compile(r'(?:\d*|&)>{1,2}(?!\s*&)\s*(?!/dev/null\b)\S')


def _ev_is_mac_mini():
    try:
        import socket
        return 'macmini' in (socket.gethostname() or '').lower()
    except Exception:
        return False


def _ev_config():
    """scope.json 로드 + 볼트 센티널 검증. 실패시 None(이 블록만 no-op, 상위 검사엔 영향 없음)."""
    try:
        import os
        cfg_path = os.path.expanduser('~/.claude/eversvault-scope.json')
        with open(cfg_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        vault = cfg.get('vaultPath')
        if not vault or not isinstance(vault, str):
            return None
        vault = os.path.expanduser(vault)
        if not os.path.isabs(vault):
            # 상대경로면 실제 참조지점이 '이 프로세스의 cwd'가 돼 세션마다 비결정적으로 동작하고,
            # cwd에 우연히 같은 이름+센티널을 가진 무관 디렉터리가 있으면 경고 없이 그걸 볼트로
            # 오인할 위험이 있다(종합테스트 워크플로 실측 발견) — 절대경로만 유효한 vaultPath로 인정.
            return None
        with open(os.path.join(vault, '00_홈.md'), 'r', encoding='utf-8') as f:
            first_line = f.readline()
        if '에버스 위키 홈' not in first_line:
            return None
        return vault
    except Exception:
        return None


def _ev_normalize_rel(path, vault):
    """vault 기준 상대경로(NFC, '/'구분)로 정규화. 절대·상대경로 둘 다 os.path.normpath로 lexical
    정규화(코드리뷰 MEDIUM 대응 — './10_컨텍스트/x'나 'a/../10_컨텍스트/x' 우회 방지)."""
    import os, unicodedata
    try:
        rel = os.path.relpath(path, vault) if os.path.isabs(path) else os.path.normpath(path)
        return unicodedata.normalize('NFC', rel.replace(os.sep, '/'))
    except Exception:
        return None


def _ev_rel_under(rel, prefix):
    """대소문자 무시 비교(코드리뷰 MEDIUM 대응 — 기본 APFS는 case-insensitive라 '90_hermes'로 우회 가능)."""
    if rel is None:
        return False
    r = rel.lower()
    p = prefix.lower().rstrip('/')
    return r == p or r.startswith(p + '/')


def _ev_frontmatter(path):
    """YAML 프론트매터의 최상위 key: value 만 파싱. 정규식 백트래킹 폭발 방지(코드리뷰 MEDIUM
    대응 — 닫는 '---' 없는 파일에서 quadratic 백트래킹 발생 확인됨) 위해 lazy DOTALL 정규식 대신
    라인 단위로 처음 200줄만 스캔."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            lines = []
            for i, line in enumerate(f):
                if i >= 200:
                    break
                lines.append(line)
    except Exception:
        return {}
    if not lines or lines[0].strip() != '---':
        return {}
    fm = {}
    for line in lines[1:]:
        if line.strip() == '---':
            break
        km = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$', line)
        if km:
            fm[km.group(1)] = km.group(2).strip().strip('"\'')
    return fm


def _ev_has_approved_proposal(vault, target_rel):
    import os, glob
    try:
        for p in glob.glob(os.path.join(vault, '20_업무위키', '_pending', '*', '*.md')):
            fm = _ev_frontmatter(p)
            t = fm.get('target')
            if t and fm.get('status') == 'approved' and _ev_normalize_rel(t, vault) == target_rel:
                return True
    except Exception:
        return False
    return False


def _ev_bash_writes_to(cmd, vault):
    """쓰기표시 토큰(마커 단어 또는 리다이렉션)이 있고, 어떤 토큰이든 vault 보호경로로 정규화되면
    차단(코드리뷰 HIGH#2·3·4 대응 — shlex 토큰 전체 스캔이라 rm/cp -r/mv -f/chmod -R/BSD sed -i ''
    전부 위치 무관하게 잡힘). vault 절대경로가 토큰에 실제 포함돼야 하므로 무관 경로 오탐은 없음."""
    import shlex
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = cmd.split()
    has_marker = _EV_REDIRECT_RE.search(cmd) is not None or any(
        t in _EV_WRITE_MARKER_WORDS for t in tokens)
    if not has_marker:
        return False
    for tok in tokens:
        tok = tok.strip('\'"')
        if vault.lower() not in tok.lower():
            continue
        rel = _ev_normalize_rel(tok, vault)
        if rel and (_ev_rel_under(rel, '10_컨텍스트') or _ev_rel_under(rel, '90_Hermes')
                    or _ev_rel_under(rel, '20_업무위키') or rel.lower() == '00_홈.md'
                    or rel == '.'):
            # rel == '.' — 볼트 루트 자체를 겨냥한 명령(코드리뷰 MEDIUM 대응: 실측으로 발견
            # — `chmod -R u+w <볼트>`처럼 루트를 대상으로 하면 위 4개 prefix 매칭에 전혀
            # 안 걸려 무검사 통과했음. -R 같은 재귀 플래그 유무를 안정적으로 파싱해 구분하는
            # 대신, 루트 대상 쓰기표시 명령 자체를 보수적으로 전부 차단 — 협조적 에이전트가
            # 볼트 루트를 non-recursive로만 건드릴 정당한 이유는 거의 없다).
            return True
    return False


# 도구별 경로 파라미터 키 후보(파일시스템 MCP 등 서버마다 키 이름이 다를 수 있어 전부 시도)
_EV_PATH_KEYS = ('file_path', 'filepath', 'path')


def _ev_extract_path(ti):
    for k in _EV_PATH_KEYS:
        v = ti.get(k)
        if v:
            return str(v)
    return ''


# 실제 등록된 eversvault-obsidian MCP 서버(Obsidian Local REST API+MCP 플러그인)는 파일시스템
# MCP와 명명 관례가 달라(vault_write/vault_patch/vault_append/vault_delete/vault_move/vault_copy)
# 위 write_file/patch_content/append_content/delete_file/move_file 부분문자열 매칭이 이 서버의
# 실제 툴 이름과 전혀 겹치지 않았다 — 2026-07-30 실측으로 발견: 미승인 vault_write가 20_업무위키
# canonical에 그대로 성공, 90_Hermes에도 그대로 성공, vault_delete도 무검사 통과. 서버 접두사로
# 한정한 명시적 분류를 별도로 추가한다(다른 MCP 서버의 기존 부분문자열 매칭엔 영향 없음).
_EV_OBSIDIAN_PREFIX = 'mcp__eversvault-obsidian__'
_EV_OBSIDIAN_WRITE_TOOLS = {'vault_write', 'vault_patch', 'open_file'}  # open_file: 대상 없으면 새 문서 생성
_EV_OBSIDIAN_APPEND_TOOLS = {'vault_append'}
_EV_OBSIDIAN_DELETE_MOVE_TOOLS = {'vault_delete', 'vault_move'}
_EV_OBSIDIAN_COPY_TOOLS = {'vault_copy'}  # source는 읽기일 뿐이라 destination만 취급
# 경로 파라미터가 없어(활성 파일 기준으로 동작) 폴더 규칙 적용이 원천적으로 불가능한 도구 —
# 예외 없이 차단(보안리뷰 M-2: Claude Code의 이 볼트 사용 패턴에 UI 커맨드가 필요한 경우가
# 없으므로, 위협모델 안에서 전면 차단이 가장 싸고 정합적).
_EV_OBSIDIAN_UNSCOPED_TOOLS = {'command_execute'}
# Bash로 로컬 REST API(Obsidian Local REST API+MCP 플러그인, 127.0.0.1:27123/27124)를 직접
# 때리면 _ev_bash_writes_to의 마커단어+vault절대경로 매칭이 전혀 안 걸린다 — curl/wget 같은
# HTTP 클라이언트는 마커단어 집합에 없고, URL은 vault의 실제 파일시스템 절대경로를 포함하지
# 않기 때문(2026-07-31 종합테스트 워크플로 실측 발견, CONFIRMED). 이 채널로는 정당한 용도가
# 없다(읽기도 eversvault-obsidian MCP 도구로 이미 가능) — 메서드를 구분하려는 시도(PUT만 차단
# 등)는 curl -X 생략시 -d로도 POST가 되는 등 우회 여지가 있어, 포트 언급 자체를 예외 없이 차단.
# 커버 범위는 표준 표기(127.0.0.1/localhost/[::1], 대소문자 무관)까지 — 8진수·정수 IP 등 의도적
# 우회 표기는 위협모델("협조적 에이전트의 실수 방지, 적대적 방어 아님") 밖이라 다루지 않는다
# (보안리뷰 확인). 부수효과: 이 레포 자체를 Bash로 다룰 때(grep/sed로 포트 리터럴 검색 등)도
# 차단되니, 이 상수를 다룰 땐 Bash 대신 Grep/Read 도구를 쓸 것(보안리뷰 LOW 대응).
_EV_LOCAL_REST_API_RE = re.compile(
    r'\b(?:127\.0\.0\.1|localhost)[:](?:27123|27124)\b'
    r'|\[?::1\]?[:](?:27123|27124)\b',
    re.IGNORECASE)  # [::1](IPv6 루프백)은 '['/':'가 단어문자가 아니라 앞선 \b가 안 걸려 별도 분기


def _ev_obsidian_normalize_rel(fp, vault, is_obsidian_tool):
    """is_obsidian_tool=True면 eversvault-obsidian 스키마상 경로는 항상 vault-relative이므로
    선행 슬래시를 벗겨 상대경로로 강제 해석한다(보안리뷰 M-1 대응 — 선행 슬래시가 있으면
    os.path.isabs가 참이 돼 _ev_normalize_rel이 실제 파일시스템 절대경로로 오인, vault 밖으로
    계산되는 relpath('..'로 시작)가 나와 보호검사를 면제받는 갭이 실측으로 확인됨). 다른 MCP
    서버(예: 범용 filesystem MCP)의 절대경로 의미론은 그대로 유지 — 이 함수는 eversvault-obsidian
    분기에서만 호출된다."""
    if is_obsidian_tool and fp.startswith('/'):
        fp = fp.lstrip('/')
    return _ev_normalize_rel(fp, vault)


def _ev_is_parent_escape(rel):
    """rel이 실제로 상위 디렉터리로 이탈하는 표기('..' 자체 또는 '../'로 시작)인지 판정.
    단순 rel.startswith('..')는 '..drafts/x.md'처럼 두 점으로 시작하는 정상 파일/디렉터리명도
    오분류한다(보안리뷰 LOW 대응 — 실사용 영향은 사실상 없지만 정밀화)."""
    return rel == '..' or rel.startswith('../')


def _ev_obsidian_escape_block(rel, fp, is_obsidian_tool):
    """rel이 '..'로 시작하면(볼트 밖으로 나가는 경로) 어떻게 취급할지 결정.
    eversvault-obsidian 툴은 스키마상 경로가 항상 vault-relative이므로(각 툴 설명: 'File path
    relative to vault root') '..'가 남는 입력 자체가 원천적으로 무의미/의심스럽다 — 그런데도
    기존 코드는 이를 '볼트 밖이라 해당없음(allow)'으로 그냥 통과시켰다(2026-07-31 종합테스트
    워크플로 실측 발견, CONFIRMED: vault_write에 '../10_컨텍스트/x.md'를 주면 무검사 통과).
    이 함수는 그 경우 차단 사유 문자열을, 통과시켜야 하면 None을 반환한다. 다른 MCP 서버(예:
    범용 filesystem MCP)는 절대경로 의미론이라 볼트 밖 경로가 실제로 무관할 수 있으므로 그
    경우엔 여전히 None(허용)을 반환 — 이 완화는 is_obsidian_tool=True일 때만 적용한다."""
    if is_obsidian_tool:
        return ("eversvault-obsidian 경로는 스키마상 항상 vault-relative입니다 — '..'로 볼트 "
                "밖을 가리키는 경로는 무조건 차단됩니다 (%s)" % fp)
    return None


def _ev_check_target(vault, rel, is_append):
    """rel(볼트 상대경로)에 폴더별 규칙 적용. 차단 사유 문자열 또는 None.
    쓰기류/복사류(destination)가 공유하는 판정 로직 — 중복·드리프트 방지를 위해 분리.

    2026-07-31 사용자 명시적 결정(자가발전 목적, "전체적으로 승인문턱을 전부 낮춰" → 범위확인
    질문에 "10_컨텍스트/90_Hermes도 포함 전체" + "20_업무위키 승인게이트 자체를 제거" 선택)으로
    10_컨텍스트·90_Hermes 쓰기금지와 20_업무위키 승인게이트(_ev_has_approved_proposal 경유)를
    전부 해제. 위험(사람 정본 오염 가능성, 90_Hermes의 "Hermes가 실제로 만들었다"는 출처 구분
    소실, 되돌리기 어려운 드리프트 축적)은 결정 전 명시적으로 고지·확인됨.

    정확한 복원은 git revert가 정본이다(이 함수 본문 + eversvault-write.md의 대응 절 — 커밋
    메시지에서 "policy change" 이전 커밋 참조). 아래는 그 커밋이 담고 있던 로직의 요약일
    뿐이며 곧이곧대로 베끼면 안 된다(코드리뷰 MEDIUM 대응 — is_append 체크가 _pending 여부와
    무관하게 20_업무위키 전체에 "예외없이" 먼저 걸렸다는 순서가 중요):
        if rel.lower() == '00_홈.md': return "00_홈.md(볼트 센티널)는 ..."
        if _ev_rel_under(rel, '10_컨텍스트'): return "10_컨텍스트는 사람 정본입니다 ..."
        if _ev_rel_under(rel, '90_Hermes'): return "90_Hermes는 Hermes 전용 ..."
        if _ev_rel_under(rel, '20_업무위키'):
            if is_append: return "...예외없이 차단..."  # _pending 포함, 큐 우회 벡터라 무조건
            if _ev_rel_under(rel, '20_업무위키/_pending'): return None
            if not _ev_has_approved_proposal(vault, rel): return "...승인된 제안 경유로만..."

    (`_ev_has_approved_proposal`·`_ev_frontmatter`는 삭제하지 않고 남겨둠 — 재도입 시 그대로
    재사용 가능. 둘 다 현재는 이 함수에서 호출 안 해 실행경로상 도달 불가능한 상태.)
    is_append 파라미터는 이 함수 본문에서 더 이상 안 읽지만, 재도입 대비 + 호출부(_ev_guard의
    두 지점) 변경을 최소화하려고 시그니처는 그대로 유지했다.

    00_홈.md 센티널 자기보호만 예외로 유지 — 이건 "승인 문턱"이 아니라 가드 자체가 살아있기
    위한 구조적 안전장치라 이번 결정 범위 밖으로 판단함(건드려도 자가발전에 득이 없고, 건드리면
    _ev_config()의 센티널 검사가 깨져 가드 전체가 fail-open으로 무력화되는 부작용만 있음).
    삭제/이동 차단(_ev_guard 상단, 볼트 전체 예외없이)·command_execute 차단·Bash REST-API
    포트 차단·'..' 탈출 차단은 "승인 문턱"이 아니라 데이터손실·아웃오브밴드 우회 방지용 별개
    안전장치라 이번 결정과 무관하게 그대로 유지(사용자 요청 범위 밖으로 판단)."""
    if rel.lower() == '00_홈.md':
        return "00_홈.md(볼트 센티널)는 가드 자기보호를 위해 쓰기 금지입니다"
    return None


def _ev_guard(tool, ti):
    """차단 사유 문자열 또는 None. 호출부에서 이미 맥미니 확인 후 try/except로 감싸 호출."""
    vault = _ev_config()
    if not vault:
        return None

    if tool == 'Bash':
        cmd = str(ti.get('command', ''))
        if _EV_LOCAL_REST_API_RE.search(cmd):
            return ("Bash를 통한 Obsidian Local REST API(127.0.0.1:27123/27124) 직접 접근은 "
                    "차단됩니다 — eversvault-obsidian MCP 도구(vault_read/vault_write 등)를 사용하세요")
        if _ev_bash_writes_to(cmd, vault):
            return ("Bash를 통한 볼트 쓰기는 차단됩니다 "
                    "(10_컨텍스트/90_Hermes/20_업무위키는 Write/Edit/patch_content 채널로만 쓰기 가능)")
        return None

    is_mcp = tool.startswith('mcp__')
    # .lower() — 경로 비교(_ev_rel_under)는 이미 대소문자 무시인데 툴명 비교만 구분해 일관성이
    # 깨져 있었다(보안리뷰 MEDIUM 대응, defense-in-depth — 실제 MCP 프로토콜상 툴명은 서버가
    # 고정 등록하므로 공격자가 대소문자를 바꿔치기할 실질 경로는 없지만 비용이 거의 없는 강화).
    ev_obsidian_tool = (tool[len(_EV_OBSIDIAN_PREFIX):].lower()
                        if tool.lower().startswith(_EV_OBSIDIAN_PREFIX) else None)
    is_ev_obsidian = ev_obsidian_tool is not None

    # 경로 파라미터가 없는 잔여 벡터(command_execute) — 폴더 규칙 판정 자체가 불가능하므로 조기 차단.
    if ev_obsidian_tool in _EV_OBSIDIAN_UNSCOPED_TOOLS:
        return ("command_execute는 활성 파일 기준으로 동작해 폴더 규칙을 적용할 경로 파라미터가 "
                "없습니다 — 예외 없이 차단(필요 시 commandId allowlist 도입 검토)")

    # 삭제/이동류(delete_file/move_file 부분문자열 매칭 + eversvault-obsidian 실제 툴명) — 볼트
    # 전체에서 예외 없이 차단. move_file/vault_move는 delete+create 조합이므로 source/destination
    # 둘 다 같은 취급(코드리뷰 HIGH#1 대응 — filesystem MCP의 move_file은 canonical 삭제 우회 경로였음).
    if is_mcp and (('delete_file' in tool or 'move_file' in tool)
                   or ev_obsidian_tool in _EV_OBSIDIAN_DELETE_MOVE_TOOLS):
        if ev_obsidian_tool == 'vault_move':
            candidates = [_ev_extract_path(ti), str(ti.get('destination') or '')]
        elif 'move_file' in tool:
            candidates = [str(ti.get('source') or ''), str(ti.get('destination') or '')]
        else:
            candidates = [_ev_extract_path(ti)]
        for fp in candidates:
            if not fp:
                continue
            rel = _ev_obsidian_normalize_rel(fp, vault, is_ev_obsidian)
            if rel is None:
                continue
            if _ev_is_parent_escape(rel):
                blocked = _ev_obsidian_escape_block(rel, fp, is_ev_obsidian)
                if blocked:
                    return blocked
                continue
            return "삭제/이동은 볼트 전체에서 예외 없이 차단됩니다 (%s)" % rel
        return None

    # 복사류(vault_copy) — source는 읽기일 뿐이라 destination만 폴더 규칙 대상.
    if is_mcp and ev_obsidian_tool in _EV_OBSIDIAN_COPY_TOOLS:
        fp = str(ti.get('destination') or '')
        if not fp:
            return None
        rel = _ev_obsidian_normalize_rel(fp, vault, is_ev_obsidian)
        if rel is None:
            return None
        if _ev_is_parent_escape(rel):
            return _ev_obsidian_escape_block(rel, fp, is_ev_obsidian)
        return _ev_check_target(vault, rel, is_append=False)

    # 쓰기류로 취급할 도구: Write/Edit/MultiEdit + MCP의 patch_content/write_file/edit_file/
    # create_directory(코드리뷰 HIGH#1 대응 — filesystem MCP의 write_file/edit_file이 원래
    # 미커버였음) + eversvault-obsidian 실제 툴명(vault_write/vault_patch/open_file). append_content/
    # vault_append는 아래에서 20_업무위키 전용 규칙으로 별도 처리.
    write_like = (tool in ('Edit', 'Write', 'MultiEdit') or
                  (is_mcp and any(k in tool for k in
                                  ('patch_content', 'write_file', 'edit_file', 'create_directory'))) or
                  (ev_obsidian_tool in _EV_OBSIDIAN_WRITE_TOOLS))
    is_append = (is_mcp and 'append_content' in tool) or (ev_obsidian_tool in _EV_OBSIDIAN_APPEND_TOOLS)
    if not (write_like or is_append):
        return None

    fp = _ev_extract_path(ti)
    if not fp:
        return None
    rel = _ev_obsidian_normalize_rel(fp, vault, is_ev_obsidian)
    if rel is None:
        return None
    if _ev_is_parent_escape(rel):
        return _ev_obsidian_escape_block(rel, fp, is_ev_obsidian)

    return _ev_check_target(vault, rel, is_append)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return  # unparseable input -> allow (fail-open)
    if not isinstance(data, dict):
        return
    tool = data.get('tool_name', '')
    ti = data.get('tool_input', {}) or {}
    if not isinstance(ti, dict):
        return

    block, warn = [], []
    if tool == 'Bash':
        cmd = str(ti.get('command', ''))
        for pat, why in CATASTROPHIC:
            if re.search(pat, cmd, re.IGNORECASE):
                block.append(why)
        if not block:
            for pat, why in DANGEROUS:
                if re.search(pat, cmd, re.IGNORECASE):
                    warn.append(why)
    elif tool in ('Edit', 'Write', 'MultiEdit'):
        fp = str(ti.get('file_path', ''))
        if fp and not re.search(r'\.(example|sample|template|dist)$', fp, re.IGNORECASE) \
                and re.search(SECRET, fp, re.IGNORECASE):
            warn.append('editing a secret-looking file (%s) - keep secrets out of git; ensure it is .gitignored' % fp)

    # EversVault 가드 — 완전히 격리된 부가 검사. 이 블록의 예외는 위 검사 결과에 영향 없음.
    ev_block = []
    try:
        if _ev_is_mac_mini():
            ev_reason = _ev_guard(tool, ti)
            if ev_reason:
                ev_block.append(ev_reason)
    except Exception:
        pass

    if block or ev_block:
        parts = []
        if block:
            parts.append("catastrophic command blocked: " + "; ".join(block))
        if ev_block:
            parts.append("EversVault guard blocked: " + "; ".join(ev_block))
        reason = "claude-config guardrail — " + " | ".join(parts) + ". If truly intended, run it outside Claude."
        _out({
            "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason},
            "systemMessage": reason
        })
    elif warn:
        _out({"systemMessage": "claude-config guardrail: " + "; ".join(warn)})
    # else: no output -> allow


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
