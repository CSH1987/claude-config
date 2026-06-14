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
