#!/usr/bin/env python3
# claude-config:leakscan.py — PII/secret scanner engine for the leak guard (v9 gate2a + gate2b).
#   Reads added-diff lines from STDIN. Exit 1 if PII/secret detected, else 0.
#   Hardened after adversarial review (2026-06-22): fine-grained PAT / sk-ant / ASIA / AWS-secret
#   coverage, anchored email allowlist (no loose substring), UTF-8 stdin + NFC (non-ASCII/Hangul
#   identity tokens), diff '+' marker strip, JWK private-key heuristic. Conservative: placeholder
#   exceptions are anchored to local-part/domain so a legit config push is never falsely blocked.
#   gate2b reads $CLAUDE_MEMORY_DIR/.leakwords; cold-start (absent) -> disabled + LOUD warn (R7).
#   Kill-switch: CLAUDE_LEAKGUARD_OFF=1.
import sys, os, re, unicodedata


def nfc(s):
    try:
        return unicodedata.normalize('NFC', s)
    except Exception:
        return s


def _nid(s):
    # evasion-resistant identity normalization (gate2b): NFC + lowercase + strip zero-width/bidi
    # + collapse separators (space/hyphen/underscore/dot) so 'John  Doe' / 'John-Doe' /
    # zero-width-inserted names match their .leakwords token. (review D2)
    try:
        s = unicodedata.normalize('NFC', s).lower()
    except Exception:
        s = s.lower()
    s = re.sub(r'[\u00ad\u200b-\u200f\u2060\u2066-\u2069\u202a-\u202e\ufeff]', '', s)  # zero-width/soft-hyphen/bidi (ASCII-escaped)
    s = re.sub(r'[\s\-_.]+', '', s)
    return s


def main():
    if os.environ.get('CLAUDE_LEAKGUARD_OFF') == '1':
        return 0

    # UTF-8-consistent decode (stdin may be cp949 on Korean Windows; .leakwords is UTF-8).
    try:
        raw = sys.stdin.buffer.read()
        text = raw.decode('utf-8', 'replace')
    except Exception:
        text = sys.stdin.read()
    # strip the unified-diff '+' marker from each added line (pipeline feeds '+content').
    text = '\n'.join((ln[1:] if ln[:1] == '+' else ln) for ln in text.split('\n'))
    text = nfc(text)
    if not text.strip():
        return 0

    hits = []

    def block(msg):
        hits.append(msg)
        sys.stderr.write('leak-guard: BLOCK — %s\n' % msg)

    # --- gate2a: email — exemptions ANCHORED to domain / local-part (no loose substring) ---
    rfc2606 = re.compile(r'@(example\.(com|org|net)|[a-z0-9.-]*\.(example|invalid|test)|localhost)$')
    allow_exact = {'noreply@anthropic.com', 'user@example.com', 'you@example.com', 'name@example.com'}
    # placeholder local-parts/domains — conventional doc fillers ONLY. Never include real email
    # providers (mail.com/email.com…) or real registrable domains (company.com/host.com) here:
    # they would exempt real third-party PII (adversarial review 2026-06-22, MEDIUM).
    ph_local = {
        'your-email', 'youremail', 'your.email', 'your_email', 'yourname', 'your.name', 'your-name',
        'you', 'user', 'username', 'name', 'firstname', 'lastname', 'first.last', 'email',
        'sample', 'dummy', 'test', 'changeme', 'placeholder', 'fixme', 'todo', 'example',
    }
    ph_domain = {
        'example.com', 'example.org', 'example.net', 'domain.com', 'yourdomain.com', 'your-domain.com',
        'yourcompany.com', 'mycompany.com', 'mydomain.com',
    }
    for m in re.findall(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', text):
        ml = m.lower()
        if rfc2606.search(ml) or ml in allow_exact:
            continue
        local, _, dom = ml.partition('@')
        if local in ph_local or dom in ph_domain:
            continue
        block('email-like: %s' % m)
        break

    # --- gate2a: API/VCS tokens (classic gh*, fine-grained PAT, Anthropic sk-ant, Slack xox) ---
    token_re = re.compile(
        r'gh[pousr]_[A-Za-z0-9]{20,}'
        r'|github_pat_[A-Za-z0-9_]{30,}'
        r'|sk-ant-[A-Za-z0-9_-]{20,}'
        r'|xox[baprs]-[A-Za-z0-9-]{10,}'
    )
    for m in token_re.findall(text):
        if 'EXAMPLE' in m or 'REDACT' in m or re.search(r'X{4,}', m):
            continue
        block('api/vcs-token-like: %s...' % m[:12])
        break

    # --- gate2a: AWS access key id (AKIA/ASIA) + secret access key (keyword-anchored, 40-char) ---
    for m in re.findall(r'A(?:KIA|SIA)[0-9A-Z]{16}', text):
        if 'EXAMPLE' in m:
            continue
        block('aws-access-key-id-like')
        break
    # canonical env-var form only (AWS_SECRET_ACCESS_KEY=<40>) — avoids false-positive on
    # 'aws ... secret ... hash: <40-hex SHA>' (review LOW). Misses freeform 'aws secret = x' by design.
    if re.search(r'aws[_.\- ]?secret[_.\- ]?access[_.\- ]?key\s*[=:]\s*["\x27]?[A-Za-z0-9/+]{40}', text, re.I):
        block('aws-secret-access-key-like (context)')

    # --- gate2a: private key (armor header + JWK private-key marker) ---
    if re.search(r'-----BEGIN [A-Z ]*PRIVATE KEY-----', text):
        block('private-key-block')
    if re.search(r'"kty"\s*:', text) and re.search(r'"d"\s*:\s*"[A-Za-z0-9_-]{40,}"', text):
        block('jwk-private-key-like')

    # --- gate2b: identity tokens from .leakwords (NFC-normalized; only if present) ---
    mem = os.environ.get('CLAUDE_MEMORY_DIR', '')
    lw = os.path.join(mem, '.leakwords') if mem else ''
    if lw and os.path.isfile(lw) and os.path.getsize(lw) > 0:
        low = nfc(text).lower()
        nlow = _nid(text)
        try:
            with open(lw, encoding='utf-8') as f:
                for line in f:
                    tok = nfc(line.strip())
                    if not tok or tok.startswith('#') or len(tok) < 3:
                        continue
                    if tok.lower() in low or _nid(tok) in nlow:
                        block('identity-token (.leakwords match): <redacted>')
        except Exception:
            pass
    else:
        sys.stderr.write('leak-guard: WARN — .leakwords 미존재(콜드스타트) → 식별토큰(실명) 검사 비활성. profile 시드 후 활성.\n')

    return 1 if hits else 0


try:
    sys.exit(main())
except Exception:
    sys.exit(0)  # fail-open on scanner bug (never hard-break the commit flow)
