#!/usr/bin/env python3
"""claude-config: model-watch engine - keep Claude Code on the newest frontier model.

Why: Claude Code has no cross-tier "always latest" alias (e.g. `fable` will not jump
to a future frontier family), and /v1/models is not callable with subscription OAuth.
So we ask the CLI itself: a headless `claude -p` session's system prompt contains the
current "most recent Claude models" info, kept fresh by CLI auto-update. $0 on
subscription, no API key, works on every machine claude-config deploys to.

Modes (argv[1], default `start`):
  start  SessionStart fast path (<50ms): print pending switch notice (becomes session
         additionalContext), then spawn today's DETACHED probe if not yet run today.
         Never blocks the session. FAIL-OPEN: any error -> silent exit 0.
  probe  Detached worker (once/day): ask `claude -p --model haiku` for the top model id,
         compare with settings.json `model` (base id, ignoring variant suffixes like
         "[1m]"), validate candidates with real `claude --model <id> -p` probes
         (prefer keeping the current variant suffix), then apply atomically to
         ~/.claude/settings.json (python json round-trip - preserves hooks arrays,
         unlike PS 5.1 ConvertTo-Json). Applies to NEW sessions only.

Off switch: CLAUDE_MODEL_WATCH_OFF=1   Pin (never auto-switch): ~/.claude/model-watch/pin
Debug: MODEL_WATCH_DEBUG=1 (re-raise errors). Probe output: ~/.claude/model-watch/probe.log
State: ~/.claude/model-watch/state.json  History: ~/.claude/model-watch/history.jsonl
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude")
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")
WATCH_DIR = os.path.join(CLAUDE_DIR, "model-watch")
STATE = os.path.join(WATCH_DIR, "state.json")
HISTORY = os.path.join(WATCH_DIR, "history.jsonl")
PIN = os.path.join(WATCH_DIR, "pin")
CLAUDE_TIMEOUT = 240  # seconds per headless call (detached, so generous is fine)

DETECT_PROMPT = (
    "Automation query (no human is reading prose). Your system prompt's environment "
    "section states which Claude models are the most recent. Respond with ONLY one "
    'line of JSON: {"top_model_id": "<id>"} where <id> is the exact model ID of the '
    "most capable (frontier) generally-available Claude model. Do not use code "
    "fences. Do not add any other text."
)


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
    tmp = path + ".tmp-model-watch"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def read_state():
    st = load_json(STATE)
    return st if isinstance(st, dict) else {}


def write_state(st):
    os.makedirs(WATCH_DIR, exist_ok=True)
    write_json_atomic(STATE, st)


def log_history(entry):
    try:
        os.makedirs(WATCH_DIR, exist_ok=True)
        entry = dict(entry, ts=now_iso())
        with open(HISTORY, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def base_id(model):
    """claude-fable-5[1m] -> claude-fable-5 (variant suffix stripped)."""
    return re.sub(r"\[[^\]]*\]$", "", (model or "").strip())


def claude_cmdline():
    """Resolve the claude CLI into an argv prefix (cmd /c wrap for .cmd/.bat shims)."""
    exe = shutil.which("claude")
    if not exe:
        return None
    if os.name == "nt" and exe.lower().endswith((".cmd", ".bat")):
        return ["cmd", "/c", exe]
    return [exe]


def run_claude(prefix, args):
    """Run claude headless. Child env gets CLAUDE_MODEL_WATCH_OFF=1 so nested
    SessionStart hooks never re-enter this script (no recursion)."""
    env = dict(os.environ, CLAUDE_MODEL_WATCH_OFF="1")
    cp = subprocess.run(
        prefix + args,
        capture_output=True,
        text=True,
        timeout=CLAUDE_TIMEOUT,
        env=env,
    )
    return cp.returncode, (cp.stdout or "") + "\n" + (cp.stderr or "")


def detect_top(prefix):
    """Ask a cheap headless session for the current frontier model id."""
    try:
        rc, out = run_claude(prefix, ["-p", "--model", "haiku", DETECT_PROMPT])
    except Exception:
        return None
    if rc != 0:
        return None
    m = re.search(r"\{[^{}]*\"top_model_id\"[^{}]*\}", out)
    if not m:
        return None
    try:
        mid = str(json.loads(m.group(0)).get("top_model_id", "")).strip()
    except Exception:
        return None
    return mid if re.fullmatch(r"claude-[a-z0-9][a-z0-9.\-]*", mid) else None


def model_valid(prefix, model):
    """A model id is valid iff a real headless call with it succeeds."""
    try:
        rc, _ = run_claude(prefix, ["-p", "--model", model, "Reply with exactly: ok"])
        return rc == 0
    except Exception:
        return False


def apply_model(new_model):
    """Atomically set settings.json `model`, preserving everything else. Returns old value."""
    s = load_json(SETTINGS)
    if not isinstance(s, dict):
        return None
    old = s.get("model")
    if old == new_model:
        return None
    try:  # same .bak.<epoch> glob as install.ps1, whose keep-5 pruning also covers ours
        shutil.copy2(SETTINGS, SETTINGS + ".bak.%d" % int(time.time()))
    except Exception:
        pass
    s["model"] = new_model
    write_json_atomic(SETTINGS, s)
    return old


def probe():
    st = read_state()
    st["checked"] = today()
    write_state(st)

    prefix = claude_cmdline()
    if not prefix:
        return
    cur = ""
    s = load_json(SETTINGS)
    if isinstance(s, dict):
        cur = s.get("model") or ""

    top = detect_top(prefix)
    st = read_state()
    st["top"] = top
    st["probed_at"] = now_iso()
    write_state(st)
    if not top:
        log_history({"event": "detect_failed"})
        return
    if base_id(top) == base_id(cur):
        return  # already on the frontier model

    # Prefer carrying over the current variant suffix (e.g. "[1m]") when available.
    candidates = []
    suffix = re.search(r"(\[[^\]]*\])$", cur.strip())
    if suffix:
        candidates.append(top + suffix.group(1))
    candidates.append(top)
    chosen = next((c for c in candidates if model_valid(prefix, c)), None)
    if not chosen:
        log_history({"event": "validation_failed", "top": top, "current": cur})
        return

    old = apply_model(chosen)
    if old is None and chosen != cur:
        log_history({"event": "apply_failed", "to": chosen})
        return
    st = read_state()
    st["notify"] = {"from": old or "(account default)", "to": chosen}
    write_state(st)
    log_history({"event": "switched", "from": old, "to": chosen})


def spawn_probe_detached():
    os.makedirs(WATCH_DIR, exist_ok=True)
    kwargs = {}
    if os.name == "nt":
        # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP: survives the hook returning
        kwargs["creationflags"] = 0x00000008 | 0x00000200
    else:
        kwargs["start_new_session"] = True
    with open(os.path.join(WATCH_DIR, "probe.log"), "ab") as logf:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "probe"],
            stdout=logf,
            stderr=logf,
            stdin=subprocess.DEVNULL,
            **kwargs
        )


def start():
    st = read_state()
    notice = st.pop("notify", None)
    if notice:
        write_state(st)
        print(
            "[model-watch] 새 최고 모델 감지 — 기본 모델 자동 전환됨: %s → %s. "
            "새 세션부터 적용됩니다(이 세션은 이전 모델일 수 있음). "
            "자동 전환 고정 해제: ~/.claude/model-watch/pin 파일 생성, 끄기: CLAUDE_MODEL_WATCH_OFF=1"
            % (notice.get("from"), notice.get("to"))
        )
    if st.get("checked") != today():
        st["checked"] = today()  # claim the day BEFORE spawning (multi-session stampede guard)
        write_state(st)
        spawn_probe_detached()


def main():
    if os.environ.get("CLAUDE_MODEL_WATCH_OFF") == "1":
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
        if os.environ.get("MODEL_WATCH_DEBUG") == "1":
            raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
