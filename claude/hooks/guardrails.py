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
    # touch/mkdir(후속과제 반영 — 보호폴더 안에 새 파일·하위폴더를 생성하는 것도 "쓰기"의
    # 일종인데, 기존 마커 집합엔 삭제/수정 계열만 있고 생성 계열이 빠져 있어 무검사 통과했음.
    'touch', 'mkdir',
}
# 실제 파일에 쓰는 리다이렉션만 표시로 취급 — `2>/dev/null`·`2>&1`·`&>/dev/null`처럼 에러 억제용으로
# 흔히 쓰이는 관용구(거의 모든 Bash 명령에 등장)를 오탐하면 정당한 읽기 작업까지 막아버린다
# (실측으로 발견: 순수 `ls ... 2>/dev/null`이 차단됐었음 — 반드시 고쳐야 하는 회귀였다).
_EV_REDIRECT_RE = re.compile(r'(?:\d*|&)>{1,2}(?!\s*&)\s*(?!/dev/null\b)\S')
# 토큰 맨 앞에 붙은 리다이렉션 연산자만 떼어내는 용도(예: '2>/dev/null', '>evil.md'). shlex는
# 공백 없이 붙은 연산자+경로를 하나의 토큰으로 묶으므로, 상대경로 후보 판정 전에 연산자
# 부분을 제거해야 실제 경로(있다면)만 남는다(코드리뷰 HIGH 대응 — 아래 참고).
_EV_REDIRECT_TOKEN_PREFIX_RE = re.compile(r'^[\d&]*>{1,2}')
# `python3 -c "os.chmod(...)"` 같은 dotted-call은 shlex 토큰화에서 'os.chmod('가 하나의 토큰이 돼
# _EV_WRITE_MARKER_WORDS의 정확 일치('chmod')에 안 걸린다(2026-07-31 실측 발견 — 직접 `chmod`
# 명령은 차단되는데 python으로 감싸면 통과). 마커단어 집합 전체를 느슨한 부분문자열/단어경계로
# 넓히면 오탐이 커지므로(예: 'dd'/'mv'/'cp'/'ln'처럼 흔한 변수명과 겹침), 실제 악용 가능한
# 파이썬 파일조작 함수만 별도의 좁은 패턴으로 잡는다.
_EV_PYTHON_WRITE_CALL_RE = re.compile(
    r'\b(?:os\.(?:chmod|chown|lchown|remove|unlink|rename|replace|rmdir|removedirs)'
    r'|shutil\.(?:chown|rmtree|move|copy2?|copytree|copyfile))\s*\(')


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
        # 딥인터뷰 스펙은 "헤딩 텍스트(# 에버스 위키 홈) 포함 여부"까지 요구했는데 기존 구현은
        # 단순 부분문자열 검사라 그보다 약했다(종합테스트 워크플로 발견) — 마크다운 H1 마커까지
        # 요구하도록 강화. 위험은 낮았지만(어차피 다른 우연한 파일이 이 문구를 담을 확률은
        # 낮음) 스펙 의도를 실제로 구현하는 정밀화.
        if not re.match(r'^#\s.*에버스 위키 홈', first_line):
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


def _ev_split_subcommands(cmd):
    """cmd를 셸 구분자(';', '&&', '||', 단일 '|'/'&', 개행) 경계에서 원문 그대로 서브커맨드로
    쪼갠다(따옴표 안의 구분자는 무시 — 문자 단위 상태기계, 이스케이프 문자도 건너뜀). 실패해도
    예외 없이 [cmd] 하나로 폴백(기존 '전체 문자열 하나로 검사' 동작과 동일 — fail 방향이 더
    보수적이라 안전). 여러 서브커맨드를 하나로 뭉쳐 검사하면 무관한 서브커맨드의 마커단어가
    다른 무관한 서브커맨드의 vault 경로 언급과 잘못 결합돼 오탐이 생긴다(2026-08-01 실측 발견 —
    'hermes status | sed ...' 처럼 무관한 'sed'와, 완전히 다른 서브커맨드에서 읽기전용으로 볼트
    루트 경로를 인자로 넘기는 것뿐인 호출이 같은 한 줄에 있다는 이유만으로 차단됐음)."""
    parts, buf, i, n = [], [], 0, len(cmd)
    quote = None
    while i < n:
        c = cmd[i]
        if quote:
            buf.append(c)
            if c == quote and cmd[i - 1] != '\\':
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            buf.append(c)
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            buf.append(c)
            buf.append(cmd[i + 1])
            i += 2
            continue
        if cmd[i:i + 2] in ('&&', '||'):
            parts.append(''.join(buf))
            buf = []
            i += 2
            continue
        if c in (';', '|', '&', '\n'):
            parts.append(''.join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    parts.append(''.join(buf))
    return [p for p in parts if p.strip()] or [cmd]


def _ev_bash_writes_to(cmd, vault, cwd=None):
    """cmd를 서브커맨드로 나눠 각각 독립적으로 검사 — 하나라도 걸리면 차단. cwd(PreToolUse
    페이로드 최상위 'cwd' — 실제 세션 작업 디렉터리, main()이 전달)를 시작점으로 cd/pushd를
    순서대로 추적해, 뒤 서브커맨드의 상대경로 인자도 올바르게 해석한다(2026-08-01 보안리뷰
    HIGH 대응 — 서브커맨드 분리 자체는 정확했지만, 분리 이전부터 있던 더 근본적인 갭이 새로
    드러남: 'vault 절대경로가 토큰에 그대로 포함돼야'만 감지했기 때문에 `cd <볼트>/10_컨텍스트
    && rm -f <상대경로파일>`가 무검사 통과했다 — cd의 절대경로 인자는 감지되지만 rm의 실제
    쓰기대상인 상대경로 인자는 애초에 검사 대상이 아니었다)."""
    try:
        subs = _ev_split_subcommands(cmd)
    except Exception:
        subs = [cmd]
    effective_cwd = cwd
    for sub in subs:
        if _ev_bash_subcommand_writes_to(sub, vault, effective_cwd):
            return True
        effective_cwd = _ev_track_cd(sub, effective_cwd)
    return False


def _ev_track_cd(sub, cwd):
    """sub가 cd/pushd면 그 인자를 cwd 기준으로 해석해 다음 서브커맨드가 볼 새 유효 cwd를
    반환, 아니면 cwd 그대로. 해석 불가능한 경우(인자 없는 cwd에서 상대 cd, 'cd -')는 None —
    이후 상대경로 판단을 보수적으로 건너뛰게 만든다(모른다는 사실을 정직하게 전파, 오탐보다
    미탐이 이 축에서는 fail-open 계약과 일관됨)."""
    import os, shlex
    try:
        tokens = shlex.split(sub)
    except ValueError:
        return cwd
    if not tokens or tokens[0] not in ('cd', 'pushd'):
        return cwd
    # 단독 '-'(직전 디렉터리, $OLDPWD)는 -L/-P 같은 실제 플래그가 아니라 유효한 타깃 인자이므로
    # '-'로 시작한다고 걸러내면 안 된다 — 걸러내면 아래 target == '-' 분기가 죽은 코드가 되고,
    # 대신 "인자 없음" 경로로 새서 실제로는 $OLDPWD인데 $HOME으로 잘못 취급하게 된다(자체 발견).
    args = [t for t in tokens[1:] if not (t.startswith('-') and t != '-')]
    if not args:
        return os.path.expanduser('~')  # 인자 없는 cd = $HOME. 볼트는 $HOME 자체가 아니라 무관.
    target = args[0].strip('\'"')
    if target == '-':
        return None  # 'cd -'(직전 디렉터리)는 이 함수 스코프에서 추적 불가
    # $HOME 같은 셸 환경변수는 shlex가 확장하지 않으므로 expandvars로 별도 처리해야 한다
    # (자체 발견 — expanduser만 쓰면 `cd $HOME/Documents/EversVault/10_컨텍스트`가 절대경로로
    # 인식되지 못해 cwd가 잘못 해석되고, 뒤이은 상대경로 쓰기 검사가 엉뚱한 기준점으로 조용히
    # 새는 조합이 남는다). 이 훅 프로세스의 환경은 실제 Bash 실행과 같은 세션에서 상속되므로
    # os.environ 기준 확장이 실제 셸 확장과 사실상 일치한다.
    target = os.path.expandvars(os.path.expanduser(target))
    if '$' in target or '`' in target:
        # expandvars 후에도 '$'/backtick이 남으면 명령치환(`$(...)`/백틱)이거나 미설정 변수라는
        # 뜻 — 정적으로는 실제 값을 알 수 없다(코드리뷰 MEDIUM 대응: 실측 발견 — 이걸 무시하고
        # 리터럴 문자열째로 join하면 "모르는 타깃"이 이전 cwd의 볼트 접두사를 그대로 상속해
        # '가짜로 여전히 볼트 안'인 것처럼 보이는 조합이 생겼음. 모른다는 사실을 'cd -'와
        # 동일하게 None으로 정직히 전파한다).
        return None
    if not os.path.isabs(target):
        if cwd is None:
            return None
        target = os.path.join(cwd, target)
    return os.path.normpath(target)


def _ev_bash_subcommand_writes_to(cmd, vault, cwd=None):
    """쓰기표시 토큰(마커 단어 또는 리다이렉션)이 있고, 어떤 토큰이든 vault 보호경로로 정규화되면
    차단(코드리뷰 HIGH#2·3·4 대응 — shlex 토큰 전체 스캔이라 rm/cp -r/mv -f/chmod -R/BSD sed -i ''
    전부 위치 무관하게 잡힘). 절대경로 토큰은 vault 절대경로가 그대로 포함돼야 매칭(기존 동작).
    상대경로 토큰은 cwd(호출부가 cd/pushd 추적으로 넘겨준 유효 작업 디렉터리)가 알려져 있을 때만
    cwd 기준으로 해석해 추가로 매칭한다(2026-08-01 보안리뷰 HIGH 대응). 호출부(_ev_bash_writes_to)
    가 이미 셸 구분자로 서브커맨드를 나눈 뒤 이 함수를 서브커맨드 단위로 호출한다 — 이 함수
    자체는 "한 서브커맨드 안에서는 마커·경로 위치가 뒤섞여도 전부 잡는다"는 기존 설계를 유지."""
    import os, shlex, unicodedata
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = cmd.split()
    has_marker = (_EV_REDIRECT_RE.search(cmd) is not None
                  or any(t in _EV_WRITE_MARKER_WORDS for t in tokens)
                  or _EV_PYTHON_WRITE_CALL_RE.search(cmd) is not None)
    if not has_marker:
        return False
    vault_norm = unicodedata.normalize('NFC', vault).lower().rstrip('/')
    # 심볼릭 링크가 보호폴더를 가리키는 경우 대응(후속과제 반영 — 기존 설계 한계: 이 함수는
    # lexical 문자열 매칭만 하므로 `/tmp/evil -> <볼트>/10_컨텍스트` 같은 링크를 거치면 토큰
    # 문자열엔 볼트가 전혀 안 보여 무검사 통과했음). vault_real 계산에 실패하면(권한 오류 등)
    # 아래 realpath 보완 체크들은 전부 건너뛴다 — 기존 lexical 체크는 그대로 유지되므로
    # fail-open 방향(이 축의 추가 보완만 못 받는 것)이라 안전.
    try:
        vault_real = os.path.realpath(vault)
    except Exception:
        vault_real = None
    for i, tok in enumerate(tokens):
        tok = tok.strip('\'"')
        if not tok:
            continue
        # `~`/`$HOME` 같은 확장을 여기서도 적용(코드리뷰 MEDIUM 대응: cd 타깃은 이미
        # expandvars/expanduser를 적용하는데 쓰기대상 토큰 쪽엔 빠져 있어서 `rm -f
        # ~/Documents/EversVault/10_컨텍스트/x.md`나 `$HOME/.../x.md`가 무검사 통과했음 —
        # 확장 후 절대경로가 되면 아래 절대경로 분기가 그대로 잡아준다). 일반 단어는
        # expandvars/expanduser가 no-op이라 안전.
        tok = os.path.expandvars(os.path.expanduser(tok))
        if vault.lower() in tok.lower():
            rel = _ev_normalize_rel(tok, vault)
            if rel and (_ev_rel_under(rel, '10_컨텍스트') or _ev_rel_under(rel, '90_Hermes')
                        or _ev_rel_under(rel, '20_업무위키') or rel.lower() == '00_홈.md'
                        or rel == '.'):
                # rel == '.' — 볼트 루트 자체를 겨냥한 명령(코드리뷰 MEDIUM 대응: 실측으로
                # 발견 — `chmod -R u+w <볼트>`처럼 루트를 대상으로 하면 위 4개 prefix 매칭에
                # 전혀 안 걸려 무검사 통과했음. -R 같은 재귀 플래그 유무를 안정적으로 파싱해
                # 구분하는 대신, 루트 대상 쓰기표시 명령 자체를 보수적으로 전부 차단 —
                # 협조적 에이전트가 볼트 루트를 non-recursive로만 건드릴 정당한 이유는 거의
                # 없다).
                return True
            # 폴백: 토큰이 `python3 -c "...os.chmod(<경로>)..."`처럼 경로를 감싼 코드 전체인
            # 경우 _ev_normalize_rel이 그 토큰 전체를 하나의(무의미한) 경로로 취급해 실패한다
            # (2026-07-31 실측 발견 — _EV_PYTHON_WRITE_CALL_RE가 has_marker는 잡아내는데
            # 정규화 기반 매칭은 그 뒤에서 못 잡아 결과적으로 무검사 통과했었음). 정규화 대신
            # 원문 부분문자열로 대략 확인 — vault_norm 뒤에 보호폴더 접두사가 그대로 이어붙는지,
            # 또는 vault 자체를 가리키는지(재귀 삭제/변경 등).
            tok_norm = unicodedata.normalize('NFC', tok).lower()
            if any((vault_norm + '/' + p) in tok_norm
                   for p in ('10_컨텍스트', '90_hermes', '20_업무위키', '00_홈.md')):
                return True
            # 볼트 루트 자체를 가리키는 경우 — 경로 인자가 vault_norm에서 "끝나는"지 확인
            # (트레일링 슬래시 하나는 허용하되 그 뒤에 하위경로 세그먼트가 있으면 안 됨:
            # 따옴표·괄호·쉼표·공백·문자열끝만 경계로 인정). 하위경로가 이어지면 위 4개
            # 접두사 검사가 담당.
            if re.search(re.escape(vault_norm) + r'/?(?:[^/a-z0-9_-]|$)', tok_norm):
                return True
            continue
        if os.path.isabs(tok) and vault_real:
            # 문자열엔 볼트가 안 보이는 절대경로 토큰(예: 심링크 `/tmp/evil/x.md`)도 실제
            # 물리경로가 보호폴더 안이면 잡는다. argv[0]도 여기서 제외하지 않는다 — 위
            # vault-substring 절대경로 분기도 원래 argv[0]을 그대로 검사하므로(코드리뷰에서
            # `/tmp/FV/10_컨텍스트/tool.sh install x` 케이스로 확인된 기존 동작) 같은
            # 분기의 심링크 보완이 다른 기준을 쓸 이유가 없다.
            try:
                real = os.path.realpath(tok)
            except Exception:
                real = None
            if real:
                rel = _ev_normalize_rel(real, vault_real)
                if rel and (_ev_rel_under(rel, '10_컨텍스트') or _ev_rel_under(rel, '90_Hermes')
                            or _ev_rel_under(rel, '20_업무위키') or rel.lower() == '00_홈.md'
                            or rel == '.'):
                    return True
            continue
        # 상대경로 토큰 — cwd가 알려져 있을 때만 cwd 기준으로 해석해 재시도(2026-08-01
        # 보안리뷰 HIGH 대응: cd로 보호폴더에 먼저 들어간 뒤 상대경로로 쓰기를 시도하는
        # 패턴이 이전에는 전혀 안 잡혔음). 플래그 토큰(-*)은 경로가 아니므로 제외.
        #
        # argv[0](명령 이름 자체)은 후보에서 제외한다(코드리뷰 HIGH 대응: 실측 재현 — cwd가
        # 추적된 보호폴더 안일 때 `cp`/`rm`/`sed` 같은 명령 이름 토큰 자체가 `join(cwd,'rm')`
        # 처럼 "cwd 하위 상대경로"로 오인되어, 대상이 전부 볼트 밖(/tmp 등)인 무관한 명령까지
        # 통째로 차단됐음 — 절대경로 분기(위)는 argv[0]이어도 그대로 검사한다, 기존 동작 보존).
        if i == 0:
            continue
        # 공백 없이 붙은 리다이렉션 연산자(`2>/dev/null`, `>evil.md`)를 떼어낸다 — 순수
        # 연산자만 있던 토큰('>','2>>' 등)은 실제 대상이 다음 토큰에서 별도로 검사되므로
        # 건너뛴다(코드리뷰 HIGH 대응: 실측 재현 — `ls > /tmp/out.txt`의 '>' 토큰이나
        # `rm -f /tmp/x 2>/dev/null`의 '2>/dev/null' 토큰이 그대로 상대경로 후보가 돼
        # `10_컨텍스트/>` 같은 무의미한 rel로 오매칭됐음).
        m = _EV_REDIRECT_TOKEN_PREFIX_RE.match(tok)
        if m:
            tok = tok[m.end():]
            if not tok:
                continue
        if cwd is None or os.path.isabs(tok) or tok.startswith('-'):
            continue
        if '.' not in tok and '/' not in tok and not os.path.exists(os.path.join(cwd, tok)):
            # 확장자도 슬래시도 없는 순수 단어는 대개 경로가 아니라 sed 스크립트/정렬 키 같은
            # 비경로 인자다(2차 코드리뷰 제안 반영 — 실측: cwd가 추적된 보호폴더 안일 때
            # `sed -n 1p /tmp/notes.txt`의 '1p'가 상대경로로 오인돼 무관한 읽기 명령까지
            # 차단됐음). 단 "확장자 없음"만으로 걸러내면 폴더명(예: '10_컨텍스트' 자체)까지
            # 같이 걸러져 `cd <볼트> && rm -rf 10_컨텍스트`처럼 이 가드의 핵심 보호대상인
            # 폴더 재귀삭제/변경이 다시 무검사 통과하는 회귀가 생긴다(3차 재검증에서 실측 발견
            # — HIGH). cwd 아래 실제로 존재하는 이름이면(폴더가 대표 사례) 확장자 유무와
            # 무관하게 후보로 복귀시킨다 — "아직 생성 전인, 확장자 없는 새 이름"(`tee 새이름`)만
            # 남는 잔여 미탐이고, 이 정도는 수용 가능하다고 판단.
            continue
        resolved = os.path.normpath(os.path.join(cwd, tok))
        rel = _ev_normalize_rel(resolved, vault)
        if rel and (_ev_rel_under(rel, '10_컨텍스트') or _ev_rel_under(rel, '90_Hermes')
                    or _ev_rel_under(rel, '20_업무위키') or rel.lower() == '00_홈.md'
                    or rel == '.'):
            return True
        if vault_real:
            # 위 lexical 체크의 심링크 보완판 — cwd 자체나 tok의 중간 경로에 심링크가 끼어
            # 있어 lexical 결과는 볼트 밖으로 보이지만 실제 물리경로는 보호폴더 안인 경우.
            # normpath를 거친 `resolved`가 아니라 원본 join을 realpath에 넘긴다(4차 코드리뷰
            # 제안 반영 — normpath가 먼저 `..`를 문자열 차원에서 접어버리면, 예를 들어
            # `cd <심링크→10_컨텍스트> && rm -f ../90_Hermes/y.md`에서 커널은 실제로 물리
            # 부모(볼트 루트)를 거쳐 90_Hermes에 도달하는데 normpath는 심링크를 안 풀고
            # 그냥 심링크의 부모 디렉터리로 문자열째 접어버려 realpath가 심링크를 관통하지
            # 못하게 됨 — 원본 join을 그대로 realpath에 넘기면 커널의 물리 해석과 일치한다).
            try:
                real = os.path.realpath(os.path.join(cwd, tok))
            except Exception:
                real = None
            if real:
                rel2 = _ev_normalize_rel(real, vault_real)
                if rel2 and (_ev_rel_under(rel2, '10_컨텍스트') or _ev_rel_under(rel2, '90_Hermes')
                             or _ev_rel_under(rel2, '20_업무위키') or rel2.lower() == '00_홈.md'
                             or rel2 == '.'):
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


def _ev_guard(tool, ti, cwd=None):
    """차단 사유 문자열 또는 None. 호출부에서 이미 맥미니 확인 후 try/except로 감싸 호출.
    cwd(PreToolUse 페이로드 최상위 'cwd' 필드 — 실제 세션 작업 디렉터리, main()이 전달)는
    Bash 상대경로 인자 해석에만 쓰인다."""
    vault = _ev_config()
    if not vault:
        return None

    if tool == 'Bash':
        cmd = str(ti.get('command', ''))
        if _EV_LOCAL_REST_API_RE.search(cmd):
            return ("Bash를 통한 Obsidian Local REST API(127.0.0.1:27123/27124) 직접 접근은 "
                    "차단됩니다 — eversvault-obsidian MCP 도구(vault_read/vault_write 등)를 사용하세요")
        if _ev_bash_writes_to(cmd, vault, cwd):
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
    cwd = data.get('cwd')
    cwd = cwd if isinstance(cwd, str) and cwd else None

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
            ev_reason = _ev_guard(tool, ti, cwd)
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
