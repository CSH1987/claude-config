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
                    or _ev_rel_under(rel, '20_업무위키') or rel.lower() == '00_홈.md'):
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


def _ev_guard(tool, ti):
    """차단 사유 문자열 또는 None. 호출부에서 이미 맥미니 확인 후 try/except로 감싸 호출."""
    vault = _ev_config()
    if not vault:
        return None

    if tool == 'Bash':
        cmd = str(ti.get('command', ''))
        if _ev_bash_writes_to(cmd, vault):
            return ("Bash를 통한 볼트 쓰기는 차단됩니다 "
                    "(10_컨텍스트/90_Hermes/20_업무위키는 Write/Edit/patch_content 채널로만 쓰기 가능)")
        return None

    is_mcp = tool.startswith('mcp__')

    # 삭제류(delete_file) — 볼트 전체에서 예외 없이 차단(코드리뷰 확인: 다른 서버명이라도 이름에
    # delete_file이 들어가면 매치). move_file은 delete+create 조합이므로 source/destination 둘 다
    # 같은 취급(코드리뷰 HIGH#1 대응 — filesystem MCP의 move_file은 canonical 삭제 우회 경로였음).
    if is_mcp and ('delete_file' in tool or 'move_file' in tool):
        candidates = [_ev_extract_path(ti)]
        if 'move_file' in tool:
            candidates = [str(ti.get('source') or ''), str(ti.get('destination') or '')]
        for fp in candidates:
            if not fp:
                continue
            rel = _ev_normalize_rel(fp, vault)
            if rel is not None and not rel.startswith('..'):
                return "delete_file/move_file은 볼트 전체에서 예외 없이 차단됩니다 (%s)" % rel
        return None

    # 쓰기류로 취급할 도구: Write/Edit/MultiEdit + MCP의 patch_content/write_file/edit_file/
    # create_directory(코드리뷰 HIGH#1 대응 — filesystem MCP의 write_file/edit_file이 원래
    # 미커버였음). append_content는 아래에서 20_업무위키 전용 규칙으로 별도 처리.
    write_like = (tool in ('Edit', 'Write', 'MultiEdit') or
                  (is_mcp and any(k in tool for k in
                                  ('patch_content', 'write_file', 'edit_file', 'create_directory'))))
    is_append = is_mcp and 'append_content' in tool
    if not (write_like or is_append):
        return None

    fp = _ev_extract_path(ti)
    if not fp:
        return None
    rel = _ev_normalize_rel(fp, vault)
    if rel is None or rel.startswith('..'):
        return None

    # 센티널 자기무장해제 방지(코드리뷰 MEDIUM 대응 — 00_홈.md를 건드리면 다음 호출부터 vault가
    # None이 돼 가드 전체가 무음 비활성화됨).
    if rel.lower() == '00_홈.md':
        return "00_홈.md(볼트 센티널)는 가드 자기보호를 위해 쓰기 금지입니다"

    if _ev_rel_under(rel, '10_컨텍스트'):
        return "10_컨텍스트는 사람 정본입니다 — Claude Code 자동쓰기 절대 금지 (%s)" % rel
    if _ev_rel_under(rel, '90_Hermes'):
        return "90_Hermes는 Hermes 전용 자동산출물입니다 — Claude Code 쓰기 금지, 읽기는 승격목적으로만 허용 (%s)" % rel
    if _ev_rel_under(rel, '20_업무위키'):
        if is_append:
            return "20_업무위키에 append_content는 예외없이 차단됩니다(큐 우회 벡터) (%s)" % rel
        if _ev_rel_under(rel, '20_업무위키/_pending'):
            return None  # 신규 제안 생성 및 기존 제안파일 Edit(status 전환 포함)은 항상 허용
        if _ev_has_approved_proposal(vault, rel):
            return None
        return "20_업무위키 canonical 노트는 승인된 제안(_pending, status:approved) 경유로만 반영 가능합니다 (%s)" % rel

    return None


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
