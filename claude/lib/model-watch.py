#!/usr/bin/env python3
"""claude-config: model-watch engine - keep the ADAPTIVE PLAN on the newest frontier model.

Adaptive plan (적응형 플랜): settings `model` stays on the `opusplan` alias (plan phase =
opus-alias model, execution = sonnet-alias model); the concrete frontier id lives ONLY in
the env remap ANTHROPIC_DEFAULT_OPUS_MODEL. So "adopt the newest frontier" means updating
that env remap - NOT pinning `model` to a concrete id (direct pins are deprecated here).
The remap is also propagated to the local claude-config repo copy, so config-sync ships
it to every machine on its normal commit/push/pull/deploy cycle.

Mid tier (3단 릴레이 검토 슬롯): env CLAUDE_CONFIG_MID_MODEL holds the review-stage
model. On a frontier swap the OUTGOING top cascades into it (the only deterministic
source - never a position in the detected model list); every probe also checks the slot
(exists / != top / valid) and recovers it from history when broken. Human intent always
wins: a ~/.claude/model-watch/pin-mid file or state mid_source=="manual" turns ALL mid
automation (cascade / consistency check / recovery) off.

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
Mid pin (mid slot never auto-updated): ~/.claude/model-watch/pin-mid
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
PIN_MID = os.path.join(WATCH_DIR, "pin-mid")  # mid pin: turns ALL mid automation off (cascade/check/recovery)
CLAUDE_TIMEOUT = 240  # seconds per headless call (detached, so generous is fine)
ENV_KEY = "ANTHROPIC_DEFAULT_OPUS_MODEL"  # adaptive plan: the frontier id lives here
MID_ENV_KEY = "CLAUDE_CONFIG_MID_MODEL"  # relay mid tier (review stage): claude-config owned slot, NOT a native alias env

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


def mid_gate(st):
    """Source gate (사람 의도 우선): returns the skip reason when mid automation must
    stay away from the slot, else None. A pin-mid file or state mid_source=="manual"
    means a human set the mid value deliberately - cascade, consistency check and
    recovery must NEVER touch it (only "cascade" or unset sources are auto-managed)."""
    if os.path.exists(PIN_MID):
        return "skipped(pin-mid)"
    if st.get("mid_source") == "manual":
        return "skipped(manual)"
    return None


def read_mid(settings):
    """Current mid slot value from a settings dict ('' when absent)."""
    if not isinstance(settings, dict) or not isinstance(settings.get("env"), dict):
        return ""
    return (settings["env"].get(MID_ENV_KEY) or "").strip()


def set_local_mid(new_mid):
    """Atomically update only the mid env slot in the LOCAL settings.json."""
    s = load_json(SETTINGS)
    if not isinstance(s, dict):
        return False
    env = s.setdefault("env", {})
    if not isinstance(env, dict):
        return False
    if env.get(MID_ENV_KEY) == new_mid:
        return True
    try:  # same .bak.<epoch> glob as install.ps1, whose keep-5 pruning also covers ours
        shutil.copy2(SETTINGS, SETTINGS + ".bak.%d" % int(time.time()))
    except Exception:
        pass
    env[MID_ENV_KEY] = new_mid
    write_json_atomic(SETTINGS, s)
    return True


def find_mid_recovery_candidate(prefix, top):
    """Newest-first history scan for a mid recovery value. Candidates come ONLY from
    the `from` field of event=="remapped" entries: legacy "switched" entries may carry
    aliases ("opus" 등), and aliases are valid CLI args (detect_top's ["--model",
    "opus"] fallback is the precedent) so model_valid() cannot reject them - an alias
    in the mid slot resolves to top and silently collapses mid==top. Hence the double
    filter: remapped-only + re.fullmatch(ID_RE, ...) on the base_id-normalized value
    (variant suffix like "[1m]" stripped first, so a legitimate suffixed `from` is not
    refused; a None `from` on the first-ever remap is type-guarded)."""
    try:
        with open(HISTORY, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return None
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except Exception:
            continue
        if not isinstance(e, dict) or e.get("event") != "remapped":
            continue
        frm = e.get("from")
        if not isinstance(frm, str):  # first remap may have logged from=None
            continue
        cand = base_id(frm)
        if not re.fullmatch(ID_RE, cand):
            continue
        if cand == base_id(top):
            continue  # mid must stay distinct from top
        if model_valid(prefix, cand):
            return cand
    return None


def check_and_recover_mid(prefix, settings, top):
    """Per-probe mid consistency: the slot must (a) exist, (b) differ from top
    (base_id compare) and (c) pass model_valid(). Skipped entirely under the source
    gate (pin-mid / manual - human intent wins, silently). On violation, recover from
    history via the double-filtered scan - LOCAL settings only: the repo copy is the
    fleet source of truth and is only fed through the (stale-guarded) cascade path.
    Returns a notice string ("recovered:<id>" / "수동 개입 필요...") or None."""
    st = read_state()
    if mid_gate(st):
        return None
    mid = read_mid(settings)
    if mid and base_id(mid) != base_id(top) and model_valid(prefix, mid):
        return None  # healthy
    cand = find_mid_recovery_candidate(prefix, top)
    if cand and set_local_mid(cand):
        st = read_state()
        st["mid_source"] = "cascade"
        write_state(st)
        log_history({"event": "mid_recovered", "from": mid or None, "to": cand})
        return "recovered:%s" % cand
    log_history({"event": "mid_recovery_failed", "mid": mid or None, "top": top})
    return "수동 개입 필요(mid 슬롯 %s — %s 값을 유효한 비-top 모델 id로 직접 설정하세요)" % (
        "무효/오염" if mid else "누락",
        MID_ENV_KEY,
    )


def plan_mid_cascade(prefix, cur, top):
    """Frontier-swap cascade: carry the OUTGOING top into the mid slot. This is the
    only deterministic mid source - using a position of the detected model list
    (e.g. ids[1]) is FORBIDDEN: the models-line order does not rank capability, so
    ids[1] may well be a sonnet-tier id. The carried value is base_id()-stripped:
    a variant suffix like "[1m]" is a top-work context variant, not a review-tier
    requirement, and consistency compares base_id anyway (a carried suffix would
    cause false mismatches). Returns (new_mid | None, notice | None)."""
    st = read_state()
    gate = mid_gate(st)
    if gate:
        return None, gate
    cand = base_id(cur)
    if not re.fullmatch(ID_RE, cand):
        return None, None  # no concrete outgoing top (first application) - keep existing mid
    if cand == base_id(top):
        return None, None  # defensive: cannot happen past the probe early-return
    if not model_valid(prefix, cand):
        return None, "수동 개입 필요(구 top %s 검증 실패 — 기존 mid 유지)" % cand
    return cand, "cascaded:%s" % cand


def queue_mid_notice(note):
    """Attach a mid-only notice without clobbering a pending top notice."""
    st = read_state()
    n = st.get("notify") if isinstance(st.get("notify"), dict) else {}
    n["mid"] = note
    st["notify"] = n
    write_state(st)


def propagate_to_repo(new_model, new_mid=None):
    """Best-effort, ADAPTIVE-PLAN ONLY: mirror the env remaps (top slot + the
    gate-approved cascaded mid, both in one write) into the local claude-config repo
    settings so config-sync's normal auto-commit/push/deploy cycle ships them to every
    machine. Legacy direct pins are NEVER propagated - the installer merge treats the
    repo as the fleet source of truth for `model`, so writing a concrete id here would
    convert every machine to a direct pin and silently dismantle the adaptive plan
    (self-perpetuating: all machines would then report mode "model" forever).
    Multi-machine stale guard: if the repo top ALREADY equals the newly detected top
    (base_id compare), another machine finished the remap+cascade first and the repo
    mid is fresher than anything this machine's older local history could derive -
    skip the mid write so a long-offline machine cannot regress the repo.
    NOTE (accepted): the guard protects only the REPO; the stale machine's own LOCAL
    mid may lag one generation until the next config-sync merge - the repo is the
    fleet source of truth, so this converges naturally without extra logic.
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
        if not isinstance(env, dict):
            return
        repo_top_already_new = base_id(env.get(ENV_KEY) or "") == base_id(new_model)
        changed = {}
        if env.get(ENV_KEY) != new_model:
            env[ENV_KEY] = new_model
            changed["to"] = new_model
        if new_mid and not repo_top_already_new and env.get(MID_ENV_KEY) != new_mid:
            env[MID_ENV_KEY] = new_mid
            changed["mid"] = new_mid
        if not changed:
            return
        write_json_atomic(rs, s)
        log_history(dict({"event": "repo_propagated"}, **changed))
    except Exception:
        pass


def apply_frontier(new_model, mode, new_mid=None):
    """Atomically update the frontier in settings.json, preserving everything else.
    mode "env": update env ANTHROPIC_DEFAULT_OPUS_MODEL (adaptive plan - `model` alias
    untouched), write the gate-approved cascade value into the mid slot when given,
    and propagate both to the repo (stale-guarded). mode "model": update the legacy
    direct pin LOCALLY only (honored, not created, not propagated; mid untouched).
    Returns (status, old) where status is "applied" | "noop" | "error"; old may
    legitimately be None on a first application (key absent) - that is a success.
    On "noop" the mid slot is left alone too: another actor (deploy merge 등) already
    applied the top, and its own cascade decision is the fresher one."""
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
        if new_mid:
            s["env"][MID_ENV_KEY] = new_mid
    write_json_atomic(SETTINGS, s)
    if mode == "env":
        propagate_to_repo(new_model, new_mid)
    return "applied", old


def probe():
    st = read_state()
    st["checked"] = today()
    write_state(st)

    prefix = claude_cmdline()
    if not prefix:
        return
    s = load_json(SETTINGS)
    s = s if isinstance(s, dict) else {}
    cur, mode = effective_frontier(s)

    top = detect_top(prefix)
    st = read_state()
    st["top"] = top
    st["probed_at"] = now_iso()
    write_state(st)
    if not top:
        log_history({"event": "detect_failed"})
        return

    # Mid consistency check runs BEFORE the top early-return on purpose: it must
    # also catch the "top already current but mid broken" case.
    mid_note = check_and_recover_mid(prefix, s, top)

    if base_id(top) == base_id(cur):
        if mid_note:
            queue_mid_notice(mid_note)
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
        if mid_note:
            queue_mid_notice(mid_note)
        return

    # Frontier swap: cascade the outgoing top into the mid slot (adaptive plan only).
    new_mid, cascade_note = (None, None)
    if mode == "env":
        new_mid, cascade_note = plan_mid_cascade(prefix, cur, top)
    old_mid = read_mid(load_json(SETTINGS) or {})  # fresh read: recovery may have run above

    status, old = apply_frontier(chosen, mode, new_mid)
    if status == "error":
        log_history({"event": "apply_failed", "to": chosen, "mode": mode})
        if mid_note:
            queue_mid_notice(mid_note)
        return
    if status == "noop":
        # 다른 주체(배포 머지 등)가 이미 적용 — 알림 불필요, mid도 그쪽 결정을 존중
        if mid_note:
            queue_mid_notice(mid_note)
        return
    st = read_state()
    st["notify"] = {"from": old or "(account default)", "to": chosen, "mode": mode}
    if mode == "env":
        st["notify"]["mid"] = cascade_note or mid_note or "변경 없음(기존 값 유지)"
    elif mid_note:
        st["notify"]["mid"] = mid_note
    if new_mid and status == "applied":
        st["mid_source"] = "cascade"
    write_state(st)
    log_history({"event": "remapped" if mode == "env" else "switched", "from": old, "to": chosen})
    if new_mid and status == "applied":
        log_history({"event": "mid_cascaded", "from": old_mid or None, "to": new_mid})


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
        lines = []
        if notice.get("to"):
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
            lines.append(msg % (notice.get("from"), notice.get("to")))
        if notice.get("mid"):
            lines.append(
                "[model-watch] mid 슬롯(%s) 처리: %s. "
                "수동 고정: ~/.claude/model-watch/pin-mid 생성(또는 state.json mid_source=\"manual\") — "
                "이후 자동 캐스케이드·복구가 이 값을 건드리지 않습니다."
                % (MID_ENV_KEY, notice.get("mid"))
            )
        if lines:
            print("\n".join(lines))
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
