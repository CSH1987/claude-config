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
_EV_WRITE_OP = re.compile(
    r'(?:>>?\s*(?P<redir>\S+))|'
    r'(?:\btee\b\s+(?:-a\s+)?(?P<tee>\S+))|'
    r'(?:\bcp\b\s+\S+\s+(?P<cp>\S+))|'
    r'(?:\bmv\b\s+\S+\s+(?P<mv>\S+))|'
    r'(?:\brsync\b(?:\s+\S+)*?\s+(?P<rsync>\S+)\s*$)|'
    r'(?:\bsed\b\s+-i\S*\s+\S+\s+(?P<sed>\S+))|'
    r'(?:\bchmod\b\s+\S+\s+(?P<chmod>\S+))'
)


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
    import os, unicodedata
    try:
        rel = os.path.relpath(path, vault) if os.path.isabs(path) else path
        return unicodedata.normalize('NFC', rel.replace(os.sep, '/'))
    except Exception:
        return None


def _ev_frontmatter(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read()
    except Exception:
        return {}
    m = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
    if not m:
        return {}
    fm = {}
    for line in m.group(1).splitlines():
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
    """리다이렉션/tee/cp/mv/rsync/sed-i/chmod의 '쓰기 대상' 인자가 실제 vault 경로 하위인지
    (단순 '20_업무위키' 문자열 매치가 아니라 vault 절대경로 포함 여부로 확인 — 무관한 경로의
    동명 폴더에 대한 오탐을 막는다)."""
    for m in _EV_WRITE_OP.finditer(cmd):
        target = next((g for g in m.groups() if g), None)
        if not target:
            continue
        target = target.strip('\'"')
        if vault not in target:
            continue
        rel = _ev_normalize_rel(target, vault)
        if rel and re.match(r'^(10_컨텍스트|90_Hermes|20_업무위키)(/|$)', rel):
            return True
    return False


def _ev_guard(tool, ti):
    """차단 사유 문자열 또는 None. 호출부에서 이미 맥미니 확인 후 try/except로 감싸 호출."""
    vault = _ev_config()
    if not vault:
        return None

    if tool == 'Bash':
        cmd = str(ti.get('command', ''))
        if _ev_bash_writes_to(cmd, vault):
            return ("EversVault 가드: Bash를 통한 볼트 쓰기는 차단됩니다 "
                    "(10_컨텍스트/90_Hermes/20_업무위키는 Write/Edit/patch_content 채널로만 쓰기 가능)")
        return None

    is_mcp = tool.startswith('mcp__')
    if is_mcp and 'delete_file' in tool:
        fp = str(ti.get('filepath') or ti.get('file_path') or ti.get('path') or '')
        rel = _ev_normalize_rel(fp, vault) if fp else None
        if rel is not None and not rel.startswith('..'):
            return "EversVault 가드: delete_file은 볼트 전체에서 예외 없이 차단됩니다 (%s)" % rel
        return None

    if not (tool in ('Edit', 'Write', 'MultiEdit') or (is_mcp and ('patch_content' in tool or 'append_content' in tool))):
        return None

    fp = str(ti.get('file_path') or ti.get('filepath') or ti.get('path') or '')
    if not fp:
        return None
    rel = _ev_normalize_rel(fp, vault)
    if rel is None or rel.startswith('..'):
        return None

    if rel.startswith('10_컨텍스트/'):
        return "EversVault 가드: 10_컨텍스트는 사람 정본입니다 — Claude Code 자동쓰기 절대 금지 (%s)" % rel
    if rel.startswith('90_Hermes/'):
        return "EversVault 가드: 90_Hermes는 Hermes 전용 자동산출물입니다 — Claude Code 쓰기 금지, 읽기는 승격목적으로만 허용 (%s)" % rel
    if rel.startswith('20_업무위키/'):
        if is_mcp and 'append_content' in tool:
            return "EversVault 가드: 20_업무위키에 append_content는 예외없이 차단됩니다(큐 우회 벡터) (%s)" % rel
        if rel.startswith('20_업무위키/_pending/'):
            return None  # 신규 제안 생성 및 기존 제안파일 Edit(status 전환 포함)은 항상 허용
        if _ev_has_approved_proposal(vault, rel):
            return None
        return "EversVault 가드: 20_업무위키 canonical 노트는 승인된 제안(_pending, status:approved) 경유로만 반영 가능합니다 (%s)" % rel

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
    try:
        if _ev_is_mac_mini():
            ev_reason = _ev_guard(tool, ti)
            if ev_reason:
                block.append(ev_reason)
    except Exception:
        pass

    if block:
        reason = "claude-config guardrail BLOCKED a catastrophic command: " + "; ".join(block) + ". If truly intended, run it outside Claude."
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
