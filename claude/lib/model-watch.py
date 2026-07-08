#!/usr/bin/env python3
"""claude-config: model-watch engine - keep the ADAPTIVE PLAN on the newest frontier model.

Adaptive plan (적응형 플랜): settings `model` stays on the `opusplan` alias (plan phase =
opus-alias model, execution = sonnet-alias model); the concrete frontier id lives ONLY in
the env remap ANTHROPIC_DEFAULT_OPUS_MODEL. So "adopt the newest frontier" means updating
that env remap - NOT pinning `model` to a concrete id (direct pins are deprecated here).
The remap is also propagated to the local claude-config repo copy, so config-sync ships
it to every machine on its normal commit/push/pull/deploy cycle.

Why probing: Claude Code has no cross-tier "always latest" alias (e.g. `fable` will not
jump to a future frontier family), and /v1/models is not callable with subscription OAuth.
So we ask the CLI itself: a headless `claude -p` session's system prompt contains the
current "most recent Claude models" info, kept fresh by CLI auto-update. $0 on
subscription, no API key, works on every machine claude-config deploys to.

Modes (argv[1], default `start`):
  start  SessionStart fast path (<50ms): print pending remap notice (becomes session
         additionalContext), then spawn today's DETACHED probe if not yet run today.
         Never blocks the session. FAIL-OPEN: any error -> silent exit 0.
  probe  Detached worker (once/day): detect the top model id, compare with the current
         effective frontier (env remap; a concrete `model` pin is honored as legacy),
         validate candidates with real `claude --model <id> -p` probes, then apply
         atomically to ~/.claude/settings.json (python json round-trip - preserves
         hooks arrays, unlike PS 5.1 ConvertTo-Json). Applies to NEW sessions only.

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

# Hook stdout is consumed by Claude Code as UTF-8; a cp949 Windows console default
# would raise UnicodeEncodeError on Korean/dash characters and silently kill notices.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude")
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")
WATCH_DIR = os.path.join(CLAUDE_DIR, "model-watch")
STATE = os.path.join(WATCH_DIR, "state.json")
HISTORY = os.path.join(WATCH_DIR, "history.jsonl")
PIN = os.path.join(WATCH_DIR, "pin")
CLAUDE_TIMEOUT = 240  # seconds per headless call (detached, so generous is fine)
ENV_KEY = "ANTHROPIC_DEFAULT_OPUS_MODEL"  # adaptive plan: the frontier id lives here

DETECT_PROMPT = (
    "Automation query (no human reads prose). Your system prompt environment "
    'section contains a line beginning "The most recent Claude models are" '
    "followed by model names and their exact model IDs. Output ONLY one line of "
    'JSON: {"model_ids_in_order": ["<id>", "..."], "most_capable_id": "<id>"} '
    "where model_ids_in_order lists ALL model IDs from that line in the exact "
    "order they appear, and most_capable_id is the one that line presents as the "
    "newest frontier generation. No code fences. No other text."
)
ID_RE = r"claude-[a-z0-9][a-z0-9.\-]*"


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
    """Resolve the claude CLI into an argv prefix. On Windows, prefer real
    executables (.exe, then cmd/c-wrapped .cmd shim) - a bare `claude` on PATH may
    be an extensionless bash script that CreateProcess cannot run (WinError 193)."""
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


def run_claude(prefix, args, prompt):
    """Run claude headless; the prompt goes via STDIN, never argv - the Windows
    npm shim needs a `cmd /c` wrap, and cmd.exe mangles argv quotes/</> chars.
    Child env gets CLAUDE_MODEL_WATCH_OFF=1 so nested SessionStart hooks never
    re-enter this script (no recursion)."""
    env = dict(os.environ, CLAUDE_MODEL_WATCH_OFF="1", CLAUDE_NO_AUTO_UPDATE="1")
    cp = subprocess.run(
        prefix + args,
        capture_output=True,
        text=True,
        timeout=CLAUDE_TIMEOUT,
        env=env,
        input=prompt,
    )
    return cp.returncode, (cp.stdout or "") + "\n" + (cp.stderr or "")


def detect_top(prefix):
    """Ask a headless session for the current frontier model id.

    EXTRACTION, not judgment: models answer "which is most capable" with self-bias
    (opus judged opus; haiku judged sonnet - both wrong). Extracting the env
    block's "The most recent Claude models are ..." line verbatim is reliable:
    Anthropic lists the frontier family FIRST, so list[0] is the answer.
    Judge = the currently configured model (no --model flag -> today's frontier
    detects tomorrow's), falling back to the `opus` alias if that call fails
    (e.g. the configured id was deprecated)."""
    for model_args in ([], ["--model", "opus"]):
        try:
            rc, out = run_claude(prefix, ["-p"] + model_args, DETECT_PROMPT)
        except Exception:
            continue
        if rc != 0:
            continue
        m = re.search(r"\{[^{}]*\"model_ids_in_order\"[^{}]*\}", out)
        if not m:
            continue
        try:
            obj = json.loads(m.group(0))
        except Exception:
            continue
        ids = [
            str(i).strip()
            for i in (obj.get("model_ids_in_order") or [])
            if re.fullmatch(ID_RE, str(i).strip())
        ]
        mc = str(obj.get("most_capable_id", "")).strip()
        if not ids:
            if re.fullmatch(ID_RE, mc):
                return mc
            continue
        if mc and mc != ids[0]:  # structural order beats soft judgment; keep a trace
            log_history({"event": "detect_disagreement", "list_first": ids[0], "most_capable": mc})
        return ids[0]
    return None


def model_valid(prefix, model):
    """A model id is valid iff a real headless call with it succeeds."""
    try:
        rc, _ = run_claude(prefix, ["-p", "--model", model], "Reply with exactly: ok")
        return rc == 0
    except Exception:
        return False


def effective_frontier(s):
    """(current frontier id, mode). Adaptive plan: `model` is an alias (opusplan) and the
    frontier id lives in env ANTHROPIC_DEFAULT_OPUS_MODEL -> mode "env". A concrete
    claude-* id in `model` is a legacy direct pin -> mode "model" (honored, not created)."""
    m = (s.get("model") or "").strip() if isinstance(s, dict) else ""
    if re.fullmatch(ID_RE, base_id(m)):
        return m, "model"
    env = s.get("env") if isinstance(s, dict) and isinstance(s.get("env"), dict) else {}
    return (env.get(ENV_KEY) or "").strip(), "env"


def propagate_to_repo(new_model):
    """Best-effort, ADAPTIVE-PLAN ONLY: mirror the env remap into the local claude-config
    repo settings so config-sync's normal auto-commit/push/deploy cycle ships it to every
    machine. Legacy direct pins are NEVER propagated - the installer merge treats the repo
    as the fleet source of truth for `model`, so writing a concrete id here would convert
    every machine to a direct pin and silently dismantle the adaptive plan (self-
    perpetuating: all machines would then report mode "model" forever).
    Never raises; skipped silently when the repo is absent."""
    try:
        pf = os.path.join(CLAUDE_DIR, ".config-sync-path")
        with open(pf, "r", encoding="utf-8") as f:
            repo = f.read().strip()
        rs = os.path.join(repo, "claude", "settings.json")
        s = load_json(rs)
        if not isinstance(s, dict):
            return
        env = s.setdefault("env", {})
        if not isinstance(env, dict) or env.get(ENV_KEY) == new_model:
            return
        env[ENV_KEY] = new_model
        write_json_atomic(rs, s)
        log_history({"event": "repo_propagated", "to": new_model})
    except Exception:
        pass


def apply_frontier(new_model, mode):
    """Atomically update the frontier in settings.json, preserving everything else.
    mode "env": update env ANTHROPIC_DEFAULT_OPUS_MODEL (adaptive plan - `model` alias
    untouched) and propagate to the repo. mode "model": update the legacy direct pin
    LOCALLY only (honored, not created, not propagated).
    Returns (status, old) where status is "applied" | "noop" | "error"; old may
    legitimately be None on a first application (key absent) - that is a success."""
    s = load_json(SETTINGS)
    if not isinstance(s, dict):
        return "error", None
    if mode == "model":
        old = s.get("model")
        if old == new_model:
            return "noop", old
    else:
        env = s.setdefault("env", {})
        if not isinstance(env, dict):
            return "error", None
        old = env.get(ENV_KEY)
        if old == new_model:
            return "noop", old
    try:  # same .bak.<epoch> glob as install.ps1, whose keep-5 pruning also covers ours
        shutil.copy2(SETTINGS, SETTINGS + ".bak.%d" % int(time.time()))
    except Exception:
        pass
    if mode == "model":
        s["model"] = new_model
    else:
        s["env"][ENV_KEY] = new_model
    write_json_atomic(SETTINGS, s)
    if mode == "env":
        propagate_to_repo(new_model)
    return "applied", old


def probe():
    st = read_state()
    st["checked"] = today()
    write_state(st)

    prefix = claude_cmdline()
    if not prefix:
        return
    s = load_json(SETTINGS)
    cur, mode = effective_frontier(s if isinstance(s, dict) else {})

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

    status, old = apply_frontier(chosen, mode)
    if status == "error":
        log_history({"event": "apply_failed", "to": chosen, "mode": mode})
        return
    if status == "noop":
        return  # 다른 주체(배포 머지 등)가 이미 적용 — 알림 불필요
    st = read_state()
    st["notify"] = {"from": old or "(account default)", "to": chosen, "mode": mode}
    write_state(st)
    log_history({"event": "remapped" if mode == "env" else "switched", "from": old, "to": chosen})


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
        # print BEFORE persisting the pop - if printing fails, the notice survives
        # for the next session instead of being silently lost.
        if notice.get("mode") == "model":  # legacy direct pin (deprecated path)
            msg = (
                "[model-watch] 새 최고 모델 감지 — 직지정 모델 전환됨: %s → %s. "
                "새 세션부터 적용됩니다(이 세션은 이전 모델일 수 있음). "
                "참고: 표준은 적응형 플랜(model=opusplan + env 재매핑)입니다. "
                "고정: ~/.claude/model-watch/pin 파일 생성, 끄기: CLAUDE_MODEL_WATCH_OFF=1"
            )
        else:
            msg = (
                "[model-watch] 새 최고 모델 감지 — 적응형 플랜 재매핑: %s → %s "
                "(ANTHROPIC_DEFAULT_OPUS_MODEL 갱신; model=opusplan 별칭은 그대로). "
                "새 세션부터 적용되며, 레포 반영을 통해 전 머신에 전파됩니다. "
                "고정: ~/.claude/model-watch/pin 파일 생성, 끄기: CLAUDE_MODEL_WATCH_OFF=1"
            )
        print(msg % (notice.get("from"), notice.get("to")))
        write_state(st)  # persist the consumed notice only after it was printed
    if st.get("checked") != today():
        st["checked"] = today()  # claim the day BEFORE spawning (multi-session stampede guard)
        write_state(st)
        spawn_probe_detached()


def main():
    if os.environ.get("CLAUDE_MODEL_WATCH_OFF") == "1":
        return 0
    if os.environ.get("CLAUDE_EVENTS_OFF") == "1":  # repo-wide hook kill switch (parity with sibling hooks)
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
