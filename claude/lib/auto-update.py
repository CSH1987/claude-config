#!/usr/bin/env python3
"""claude-config: auto-update engine - keep session-related components on latest, SAFELY.

Why: the user wants "always auto-latest" for everything the claude-config session
depends on, but blindly running newest third-party code every session is a supply-chain
risk (see decision 20260705-onboarding-architecture, supply-chain item). So this is the
SAFE variant: auto-update, but throttled + fail-open + KNOWN_GOOD-recorded + change-logged
+ auto-rollback for runtimes whose command breaks. Mirrors the proven model-watch.py
architecture (shared engine + thin .ps1/.sh wrappers + detached once/day probe).

Targets (all fail-open, once/day, in a DETACHED probe so SessionStart never blocks):
  plugins            `claude plugin marketplace update` - refreshes every marketplace AND
                     its installed plugins (there is no `claude plugin update`; marketplace
                     refresh is the documented path). Belt-and-suspenders with Claude Code's
                     own startup auto-update; harmless if already current.
  pwsh/node/gh/git   OS package manager: winget (Windows) / brew (macOS/Linuxbrew).
                     apt/dnf are NOT used - they need interactive sudo; those targets skip.
  claude-config repo NOT handled here - config-sync already `git pull`s it each SessionStart.

Safety rails (the user explicitly picked "safe auto-update", not "always latest"):
  - throttle : once/day (state["checked"]); the probe is detached, so start() is <50ms.
  - fail-open: any target failing is logged and skipped; the session is never blocked/erred.
  - KNOWN_GOOD: each runtime's version is recorded BEFORE updating -> rollback reference.
  - auto-rollback (runtimes, WINGET ONLY): if a runtime's `--version` STOPS working after an
    update, reinstall the recorded KNOWN_GOOD version. brew/macOS has NO version-pin rollback
    here -> snapshot+log only (recover manually via `brew`; see README). Plugins likewise get
    snapshot+log only (no cheap health signal; manual recovery documented in README).
    Either way, a break/failed-rollback is surfaced LOUDLY in the next-session notice.
  - change log: old->new per target in history.jsonl; a pending notice surfaces next start.

Modes (argv[1], default `start`):
  start  fast path: print any pending update notice (SessionStart additionalContext),
         then spawn today's DETACHED probe if not yet run today. Never blocks. FAIL-OPEN.
  probe  detached worker (once/day): update each target, record KNOWN_GOOD, log old->new.

Off: CLAUDE_NO_AUTO_UPDATE=1  |  CLAUDE_EVENTS_OFF=1 (repo-wide)  |  pin file ~/.claude/auto-update/pin
Dry-run (preview only, executes NO update/rollback - read-only version queries still run):
  AUTO_UPDATE_DRY_RUN=1
Debug: AUTO_UPDATE_DEBUG=1 (re-raise). Probe log: ~/.claude/auto-update/probe.log
State: ~/.claude/auto-update/state.json   History: ~/.claude/auto-update/history.jsonl
"""
import json
import os
import shutil
import subprocess
import sys
import time

# Hook stdout is consumed by Claude Code as UTF-8; a cp949 Windows console default would
# raise UnicodeEncodeError on Korean/dash chars and silently kill notices.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude")
AU_DIR = os.path.join(CLAUDE_DIR, "auto-update")
STATE = os.path.join(AU_DIR, "state.json")
HISTORY = os.path.join(AU_DIR, "history.jsonl")
PIN = os.path.join(AU_DIR, "pin")
CMD_TIMEOUT = 600  # seconds per update call (detached, so generous is fine)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def today():
    return time.strftime("%Y%m%d", time.gmtime())


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def write_json_atomic(path, obj):
    tmp = path + ".tmp-auto-update"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def read_state():
    st = load_json(STATE)
    return st if isinstance(st, dict) else {}


def write_state(st):
    os.makedirs(AU_DIR, exist_ok=True)
    write_json_atomic(STATE, st)


def log_history(entry):
    try:
        os.makedirs(AU_DIR, exist_ok=True)
        entry = dict(entry, ts=now_iso())
        with open(HISTORY, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def run(argv, timeout=CMD_TIMEOUT):
    """Run a command fully non-interactively. Child env disables our own hooks so a nested
    `claude ...` can never re-enter this script or model-watch. Returns (rc, combined_out)."""
    env = dict(os.environ, CLAUDE_NO_AUTO_UPDATE="1", CLAUDE_MODEL_WATCH_OFF="1")
    try:
        cp = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            stdin=subprocess.DEVNULL,
        )
        return cp.returncode, (cp.stdout or "") + (cp.stderr or "")
    except Exception as e:
        return 1, "exception: %r" % (e,)


def claude_cmdline():
    """Resolve the claude CLI to an argv prefix. On Windows prefer real executables:
    a bare `claude` may be an extensionless bash script CreateProcess cannot run (193)."""
    if os.name == "nt":
        exe = shutil.which("claude.exe")
        if exe:
            return [exe]
        for shim in ("claude.cmd", "claude.bat"):
            exe = shutil.which(shim)
            if exe:
                return ["cmd", "/c", exe]
        return None
    exe = shutil.which("claude")
    return [exe] if exe else None


def first_line(s):
    for ln in (s or "").splitlines():
        ln = ln.strip()
        if ln:
            return ln
    return ""


def cmd_version(argv):
    """Return a runtime's version string (first non-empty output line), or None if the
    command is missing/broken. This IS the health signal used for auto-rollback."""
    if not argv or not shutil.which(argv[0]):
        return None
    rc, out = run(argv, timeout=30)
    if rc != 0:
        return None
    return first_line(out) or None


# ---- target catalogue (per platform) ---------------------------------------

def runtime_targets():
    """List of runtime targets for this OS. Each: key, ver(argv for --version),
    and installer coordinates. Empty installer -> detect-only (can't safely update here)."""
    if os.name == "nt":
        pm = "winget" if shutil.which("winget") else None
        base = [
            {"key": "pwsh", "ver": ["pwsh", "--version"], "id": "Microsoft.PowerShell"},
            {"key": "node", "ver": ["node", "--version"], "id": "OpenJS.NodeJS"},
            {"key": "gh", "ver": ["gh", "--version"], "id": "GitHub.cli"},
            {"key": "git", "ver": ["git", "--version"], "id": "Git.Git"},
        ]
        return base, pm
    pm = "brew" if shutil.which("brew") else None  # macOS or Linuxbrew; apt/dnf need sudo -> skip
    base = [
        {"key": "pwsh", "ver": ["pwsh", "--version"], "brew": "powershell", "cask": True},
        {"key": "node", "ver": ["node", "--version"], "brew": "node"},
        {"key": "gh", "ver": ["gh", "--version"], "brew": "gh"},
        {"key": "git", "ver": ["git", "--version"], "brew": "git"},
    ]
    return base, pm


def dry_run():
    return os.environ.get("AUTO_UPDATE_DRY_RUN") == "1"


def do_update(t, pm):
    """Run the package-manager upgrade for one runtime target. Returns (rc, out)."""
    if dry_run():
        return 0, "dry-run"
    if pm == "winget":
        return run([
            "winget", "upgrade", "--id", t["id"], "--exact", "--silent",
            "--accept-source-agreements", "--accept-package-agreements",
            "--disable-interactivity",
        ])
    if pm == "brew":
        if t.get("cask"):
            return run(["brew", "upgrade", "--cask", t["brew"]])
        return run(["brew", "upgrade", t["brew"]])
    return 1, "no package manager"


def do_rollback(t, pm, version):
    """Best-effort reinstall of a KNOWN_GOOD version after an update broke the command."""
    if dry_run():
        return 0, "dry-run"
    if pm == "winget" and version:
        # winget records the raw --version line; extract a version-looking token.
        import re
        m = re.search(r"\d+\.\d+(?:\.\d+)*", version)
        if not m:
            return 1, "no version token in %r" % version
        return run([
            "winget", "install", "--id", t["id"], "--exact", "--version", m.group(0),
            "--silent", "--accept-source-agreements", "--accept-package-agreements",
            "--disable-interactivity", "--force",
        ])
    return 1, "rollback unsupported for %s" % pm


# ---- plugins ---------------------------------------------------------------

def plugin_snapshot(prefix):
    """Best-effort snapshot of installed plugins for change detection. Version fields are
    not documented, so we store the raw listing text and diff it whole."""
    if not prefix:
        return None
    for args in (["plugin", "list", "--json"], ["plugin", "list"]):
        rc, out = run(prefix + args, timeout=60)
        if rc == 0 and out.strip():
            return out.strip()
    return None


def update_plugins(st):
    prefix = claude_cmdline()
    if not prefix:
        log_history({"target": "plugins", "event": "skip", "reason": "claude CLI not found"})
        return None
    before = plugin_snapshot(prefix)
    st.setdefault("known_good", {})["plugins"] = before
    if dry_run():
        log_history({"target": "plugins", "event": "dry_run"})
        return None
    rc, out = run(prefix + ["plugin", "marketplace", "update"])
    if rc != 0:
        log_history({"target": "plugins", "event": "update_failed", "rc": rc, "out": first_line(out)})
        return None
    after = plugin_snapshot(prefix)
    if before is not None and after is not None and before != after:
        log_history({"target": "plugins", "event": "changed"})
        return "plugins"
    log_history({"target": "plugins", "event": "current"})
    return None


# ---- probe / start ---------------------------------------------------------

def probe():
    st = read_state()
    st["checked"] = today()
    st["probed_at"] = now_iso()
    write_state(st)

    changed = []

    # plugins (belt-and-suspenders with Claude Code's own startup auto-update)
    try:
        if update_plugins(st):
            changed.append("plugins")
        write_state(st)
    except Exception:
        if os.environ.get("AUTO_UPDATE_DEBUG") == "1":
            raise

    # runtimes (pwsh/node/gh/git) via winget/brew, each fail-open + auto-rollback on breakage
    targets, pm = runtime_targets()
    if pm is None:
        log_history({"target": "runtimes", "event": "skip", "reason": "no non-interactive package manager"})
    else:
        for t in targets:
            try:
                before = cmd_version(t["ver"])
                if before is None:
                    log_history({"target": t["key"], "event": "skip", "reason": "not installed"})
                    continue
                st.setdefault("known_good", {})[t["key"]] = before
                write_state(st)
                do_update(t, pm)  # return code intentionally ignored: winget returns non-zero
                # for "already up to date"; the before/after version delta below is the truth.
                after = cmd_version(t["ver"])
                if after is None:
                    # update broke the command -> auto-rollback to KNOWN_GOOD (winget only)
                    rrc, rout = do_rollback(t, pm, before)
                    restored = cmd_version(t["ver"])
                    log_history({"target": t["key"], "event": "broke_rolled_back",
                                 "known_good": before, "rollback_rc": rrc,
                                 "restored": restored})
                    # surface breakage LOUDLY in the next-session notice (not just history) -
                    # a broken/failed-rollback runtime is exactly what "safe" must not hide.
                    changed.append(
                        "[!] %s: 업데이트가 명령을 깨뜨림 -> 롤백 %s"
                        % (t["key"], "성공(known_good 복구)" if restored else "실패 - 수동 복구 필요")
                    )
                elif after != before:
                    log_history({"target": t["key"], "event": "updated",
                                 "from": before, "to": after})
                    changed.append("%s %s->%s" % (t["key"], before, after))
                else:
                    log_history({"target": t["key"], "event": "current", "version": before})
            except Exception:
                if os.environ.get("AUTO_UPDATE_DEBUG") == "1":
                    raise
                log_history({"target": t["key"], "event": "error"})

    st = read_state()
    if changed:
        st["notify"] = changed
    write_state(st)


def spawn_probe_detached():
    os.makedirs(AU_DIR, exist_ok=True)
    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = 0x00000008 | 0x00000200  # DETACHED | NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    with open(os.path.join(AU_DIR, "probe.log"), "ab") as logf:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "probe"],
            stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, **kwargs
        )


def start():
    st = read_state()
    notice = st.pop("notify", None)
    if notice:
        # print BEFORE persisting the pop - if printing fails, the notice survives.
        print(
            "[auto-update] 세션 구성요소 자동 업데이트: %s. "
            "직전 버전은 ~/.claude/auto-update/state.json(known_good)에 기록됨. "
            "끄기: CLAUDE_NO_AUTO_UPDATE=1, 고정: ~/.claude/auto-update/pin 파일 생성."
            % ", ".join(notice if isinstance(notice, list) else [str(notice)])
        )
        write_state(st)
    if st.get("checked") != today():
        st["checked"] = today()  # claim the day BEFORE spawning (multi-session stampede guard)
        write_state(st)
        spawn_probe_detached()


def main():
    if os.environ.get("CLAUDE_NO_AUTO_UPDATE") == "1":
        return 0
    if os.environ.get("CLAUDE_EVENTS_OFF") == "1":  # repo-wide hook kill switch (parity)
        return 0
    if os.path.exists(PIN):
        return 0
    mode = sys.argv[1] if len(sys.argv) > 1 else "start"
    try:
        if mode == "probe":
            probe()
        else:
            start()
    except Exception:
        if os.environ.get("AUTO_UPDATE_DEBUG") == "1":
            raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
