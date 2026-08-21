#!/usr/bin/env python3
"""Codex PreToolUse용 guardrail 어댑터.

판정 로직은 claude-config의 공통 guardrails.py를 재사용하되, Codex 전용
실행 경로와 사용자 메시지를 제공한다. 어떤 오류도 도구 실행을 깨지 않는
fail-open 계약을 유지한다.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


def codex_message(value: Any) -> Any:
    if isinstance(value, str):
        return value.replace("Claude", "Codex")
    if isinstance(value, list):
        return [codex_message(item) for item in value]
    if isinstance(value, dict):
        return {key: codex_message(item) for key, item in value.items()}
    return value


def main() -> None:
    core_path = Path(__file__).resolve().parents[2] / "claude" / "hooks" / "guardrails.py"
    if not core_path.is_file():
        return
    spec = importlib.util.spec_from_file_location("claude_config_guardrails_core", core_path)
    if spec is None or spec.loader is None:
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    def output_for_codex(payload: Any) -> None:
        sys.stdout.write(json.dumps(codex_message(payload), ensure_ascii=False))

    module._out = output_for_codex
    module.main()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    raise SystemExit(0)
