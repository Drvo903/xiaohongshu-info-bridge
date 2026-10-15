#!/usr/bin/env python3
"""Check Xiaohongshu login state through the read-only MCP tool."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from collector import (  # noqa: E402
    MCPClient,
    atomic_write_json,
    iso_beijing,
    safe_error,
    setup_logger,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--mcp-url", default="http://127.0.0.1:18060/mcp")
    return parser.parse_args()


def build_document(
    *,
    status: str,
    checked_at: str,
    warning: str | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    document: dict[str, Any] = {
        "checked_at": checked_at,
        "login_status": status,
        "source": "xiaohongshu-mcp",
        "warnings": [warning] if warning else [],
    }
    if error:
        document["error"] = error
    return document


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    logger = setup_logger(root / "logs" / "login-check.log")
    output_path = root / "data" / "login-status.json"
    alert_path = root / "data" / "login-alert.pending.json"
    checked_at = iso_beijing()
    previous_status = None
    try:
        previous = json.loads(output_path.read_text(encoding="utf-8"))
        if isinstance(previous, dict):
            previous_status = previous.get("login_status")
    except (OSError, json.JSONDecodeError):
        pass

    try:
        client = MCPClient(args.mcp_url, logger, timeout=45)
        client.initialize()
        login_text = client.call_tool("check_login_status", timeout=30)
        if login_text and "已登录" in login_text:
            document = build_document(status="ok", checked_at=checked_at)
            exit_code = 0
            logger.info("LOGIN_CHECK_OK")
        else:
            document = build_document(
                status="login_required",
                checked_at=checked_at,
                warning="LOGIN_REQUIRED",
            )
            exit_code = 20
            logger.error("LOGIN_REQUIRED")
    except Exception as exc:  # noqa: BLE001 - bounded status probe
        message = safe_error(exc)
        document = build_document(
            status="failed",
            checked_at=checked_at,
            warning="LOGIN_CHECK_FAILED",
            error=message,
        )
        exit_code = 22
        logger.error("LOGIN_CHECK_FAILED reason=%s", message)

    atomic_write_json(output_path, document)
    if document["login_status"] == "login_required":
        if previous_status != "login_required":
            atomic_write_json(
                alert_path,
                {
                    "created_at": checked_at,
                    "reason": "LOGIN_REQUIRED",
                },
            )
            logger.warning("LOGIN_ALERT_PENDING")
    elif document["login_status"] == "ok" and alert_path.exists():
        try:
            alert_path.unlink()
            logger.info("LOGIN_ALERT_CLEARED")
        except OSError as exc:
            logger.warning("LOGIN_ALERT_CLEAR_FAILED reason=%s", safe_error(exc))
    print(json.dumps(document, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
