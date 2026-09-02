#!/usr/bin/env python3
"""Read-only Xiaohongshu public-feed collector.

The MCP session and xsec_token values stay in memory for one run only.
Only cleaned public note fields are written to output/xhs-feed.json.
"""

from __future__ import annotations

import argparse
import json
import logging
import random
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit


DEFAULT_MCP_URL = "http://127.0.0.1:18060/mcp"
DEFAULT_MAX_AGE_DAYS = 60
DEFAULT_PER_KEYWORD_LIMIT = 10
DEFAULT_MAX_TOTAL = 80
DEFAULT_MAX_DETAILS = 20
DEFAULT_DETAIL_TIMEOUT = 45

SENSITIVE_KEY_RE = re.compile(
    r"(cookie|token|session|authorization|password|secret|credential|"
    r"手机号|密码|令牌|会话)",
    re.IGNORECASE,
)
RISK_RE = re.compile(r"(验证码|风控|风险验证|risk.?control|captcha|verification)", re.IGNORECASE)
LOGIN_RE = re.compile(r"(登录|login|未登录|login.?required|auth)", re.IGNORECASE)


class CollectorError(RuntimeError):
    """Base collector error."""


class LoginRequired(CollectorError):
    pass


class RiskControlTriggered(CollectorError):
    pass


class MCPToolError(CollectorError):
    pass


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat().replace("+00:00", "Z")


def safe_error(value: Any) -> str:
    """Remove sensitive-looking values before putting an error in logs."""

    text = str(value)
    text = re.sub(
        r'(?i)("?(?:xsec[_-]?token|token|cookie|session|authorization)"?\s*[:=]\s*"?)[^,"\s}"]+',
        r"\1[REDACTED]",
        text,
    )
    text = re.sub(r"(?i)([?&](?:xsec_token|xsecToken)=)[^&\s\"]+", r"\1[REDACTED]", text)
    return text[:600]


def setup_logger(log_path: Path) -> logging.Logger:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("xhscollector")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    handler = RotatingFileHandler(
        log_path,
        maxBytes=2 * 1024 * 1024,
        backupCount=3,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    return logger


def mcp_json(raw: bytes) -> dict[str, Any]:
    text = raw.decode("utf-8", errors="replace").strip()
    if not text:
        raise MCPToolError("MCP returned an empty response")

    candidates = [text]
    if "data:" in text:
        candidates.extend(
            line[5:].strip()
            for line in text.splitlines()
            if line.strip().startswith("data:")
        )

    for candidate in candidates:
        try:
            value = json.loads(candidate)
            if isinstance(value, dict):
                return value
        except json.JSONDecodeError:
            continue
    raise MCPToolError("MCP response was not valid JSON")


def text_from_tool_response(response: dict[str, Any]) -> str:
    if "error" in response:
        error = response.get("error") or {}
        raise MCPToolError(safe_error(error.get("message", "MCP JSON-RPC error")))
    result = response.get("result") or {}
    if result.get("isError"):
        parts = result.get("content") or []
        text = " ".join(str(part.get("text", "")) for part in parts if isinstance(part, dict))
        raise MCPToolError(safe_error(text or "MCP tool returned an error"))
    parts = result.get("content") or []
    text_parts = [part.get("text", "") for part in parts if isinstance(part, dict)]
    return "\n".join(str(item) for item in text_parts if item is not None)


def json_from_tool_text(text: str) -> Any:
    stripped = text.strip()
    if not stripped:
        raise MCPToolError("MCP tool returned no text")
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    fenced = re.sub(r"^```(?:json)?\s*|\s*```$", "", stripped, flags=re.IGNORECASE)
    try:
        return json.loads(fenced)
    except json.JSONDecodeError:
        pass

    decoder = json.JSONDecoder()
    for index, char in enumerate(stripped):
        if char not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(stripped[index:])
            return value
        except json.JSONDecodeError:
            continue
    raise MCPToolError("MCP tool text did not contain a JSON payload")


def classify_exception(exc: BaseException) -> CollectorError:
    message = str(exc)
    if RISK_RE.search(message):
        return RiskControlTriggered("risk control or verification detected")
    if LOGIN_RE.search(message):
        return LoginRequired("login required")
    if isinstance(exc, CollectorError):
        return exc
    return CollectorError(message)


class MCPClient:
    def __init__(self, endpoint: str, logger: logging.Logger, timeout: int = 120) -> None:
        self.endpoint = endpoint
        self.logger = logger
        self.timeout = timeout
        self.session_id: str | None = None
        self.request_id = 0

    def _post(self, payload: dict[str, Any], timeout: int | None = None) -> dict[str, Any]:
        headers = {
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "User-Agent": "XHSCollector/1.0",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout or self.timeout) as response:
                session = next(
                    (
                        value
                        for key, value in response.headers.items()
                        if key.lower() == "mcp-session-id"
                    ),
                    None,
                )
                if session and not self.session_id:
                    self.session_id = session
                return mcp_json(response.read())
        except urllib.error.HTTPError as exc:
            raise MCPToolError(f"MCP HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise MCPToolError(f"MCP connection failed: {safe_error(exc.reason)}") from exc

    def initialize(self) -> None:
        self.request_id += 1
        response = self._post(
            {
                "jsonrpc": "2.0",
                "id": self.request_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "xhscollector", "version": "1.0"},
                },
            },
            timeout=30,
        )
        text_from_tool_response(response)
        if not self.session_id:
            raise MCPToolError("MCP did not provide a session id")

    def call_tool(
        self,
        name: str,
        arguments: dict[str, Any] | None = None,
        timeout: int | None = None,
    ) -> str:
        self.request_id += 1
        response = self._post(
            {
                "jsonrpc": "2.0",
                "id": self.request_id,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments or {}},
            },
            timeout=timeout,
        )
        return text_from_tool_response(response)


def parse_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(str(value).replace(",", "").strip())
    except (TypeError, ValueError):
        return None


def timestamp_to_iso(value: Any) -> str | None:
    number = parse_int(value)
    if number is None:
        return None
    if number < 10**12:
        number *= 1000
    try:
        return datetime.fromtimestamp(number / 1000, timezone.utc).isoformat().replace(
            "+00:00", "Z"
        )
    except (OverflowError, OSError, ValueError):
        return None


def clean_summary(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    summary = re.sub(r"\s+", " ", value).strip()
    return summary[:500] if summary else None


def normalize_url(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    parsed = urlsplit(value.strip())
    if not parsed.scheme or not parsed.netloc:
        return None
    path = parsed.path.rstrip("/") or "/"
    return urlunsplit((parsed.scheme.lower(), parsed.netloc.lower(), path, "", ""))


def public_note_url(note_id: str | None) -> str | None:
    return f"https://www.xiaohongshu.com/explore/{note_id}" if note_id else None


def search_note(feed: dict[str, Any]) -> dict[str, Any]:
    card = feed.get("noteCard") or {}
    user = card.get("user") or {}
    interaction = card.get("interactInfo") or {}
    note_id = feed.get("id") or card.get("noteId")
    return {
        "id": note_id,
        "title": card.get("displayTitle") or card.get("title"),
        "author": user.get("nickname") or user.get("nickName"),
        "published_at": timestamp_to_iso(card.get("time") or card.get("publishTime")),
        "url": public_note_url(note_id),
        "summary": clean_summary(card.get("desc")),
        "likes": parse_int(interaction.get("likedCount")),
        "comments": parse_int(interaction.get("commentCount")),
        "collects": parse_int(interaction.get("collectedCount")),
        "location": card.get("ipLocation") or card.get("location"),
    }


def detail_note(payload: dict[str, Any]) -> dict[str, Any]:
    data = payload.get("data") or {}
    note = data.get("note") if isinstance(data, dict) else None
    if not isinstance(note, dict):
        note = payload.get("note") if isinstance(payload.get("note"), dict) else {}
    user = note.get("user") or {}
    interaction = note.get("interactInfo") or {}
    note_id = note.get("noteId") or payload.get("feed_id")
    return {
        "id": note_id,
        "title": note.get("title"),
        "author": user.get("nickname") or user.get("nickName"),
        "published_at": timestamp_to_iso(note.get("time") or note.get("publishTime")),
        "url": public_note_url(note_id),
        "summary": clean_summary(note.get("desc")),
        "likes": parse_int(interaction.get("likedCount")),
        "comments": parse_int(interaction.get("commentCount")),
        "collects": parse_int(interaction.get("collectedCount")),
        "location": note.get("ipLocation") or note.get("location"),
    }


def record_key(record: dict[str, Any]) -> str | None:
    note_id = record.get("id")
    if isinstance(note_id, str) and note_id.strip():
        return f"id:{note_id.strip()}"
    normalized = normalize_url(record.get("url"))
    return f"url:{normalized}" if normalized else None


def merge_non_null(target: dict[str, Any], source: dict[str, Any]) -> None:
    for field in (
        "title",
        "author",
        "published_at",
        "url",
        "summary",
        "likes",
        "comments",
        "collects",
        "location",
    ):
        value = source.get(field)
        if value is not None and value != "":
            target[field] = value


def load_history(path: Path, logger: logging.Logger) -> dict[str, dict[str, Any]]:
    if not path.exists():
        return {}
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CollectorError(f"existing output is not valid JSON: {safe_error(exc)}") from exc

    result: dict[str, dict[str, Any]] = {}
    for item in document.get("results", []):
        if not isinstance(item, dict):
            continue
        key = record_key(item)
        if not key:
            continue
        keywords = item.get("matched_keywords")
        if not isinstance(keywords, list):
            keywords = [item["keyword"]] if item.get("keyword") else []
        item["matched_keywords"] = sorted(
            {str(keyword) for keyword in keywords if keyword},
            key=str.casefold,
        )
        if item.get("matched_keywords") and not item.get("keyword"):
            item["keyword"] = item["matched_keywords"][0]
        result[key] = item
    logger.info("loaded existing history records=%d", len(result))
    return result


def trim_history(
    records: dict[str, dict[str, Any]],
    max_age_days: int,
    now: datetime,
) -> dict[str, dict[str, Any]]:
    cutoff = now - timedelta(days=max_age_days)
    kept: dict[str, dict[str, Any]] = {}
    for key, record in records.items():
        candidate = record.get("published_at") or record.get("last_seen_at")
        try:
            when = datetime.fromisoformat(str(candidate).replace("Z", "+00:00"))
        except (TypeError, ValueError):
            when = now
        if when >= cutoff:
            kept[key] = record
    return kept


def write_output(path: Path, records: dict[str, dict[str, Any]], now: datetime) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered = list(records.values())
    ordered.sort(
        key=lambda item: (
            item.get("published_at") or "",
            item.get("last_seen_at") or "",
        ),
        reverse=True,
    )
    document = {
        "updated_at": now.isoformat().replace("+00:00", "Z"),
        "source": "xiaohongshu",
        "results": ordered,
    }
    temp_path = path.with_name(path.name + ".tmp")
    temp_path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temp_path.replace(path)


def load_keywords(path: Path) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not all(isinstance(item, str) and item.strip() for item in data):
        raise CollectorError("keywords.json must contain a non-empty string array")
    return [item.strip() for item in data]


@dataclass
class RunStats:
    searches_ok: int = 0
    searches_failed: int = 0
    returned: int = 0
    unique_seen: int = 0
    details_ok: int = 0
    details_failed: int = 0
    newly_added: int = 0
    deduped: int = 0


def run(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    logger = setup_logger(root / "logs" / "collector.log")
    output_path = root / "output" / "xhs-feed.json"
    keyword_path = Path(args.keywords).resolve()
    started = utc_now()
    stats = RunStats()
    logger.info("TASK_START mcp_url=%s keywords_file=%s", args.mcp_url, keyword_path)

    try:
        keywords = load_keywords(keyword_path)
        records = load_history(output_path, logger)
        client = MCPClient(args.mcp_url, logger)
        client.initialize()
        login_text = client.call_tool("check_login_status")
        if not login_text or "已登录" not in login_text:
            logger.error("LOGIN_REQUIRED")
            return 20

        seen_this_run: set[str] = set()
        detail_count = 0
        detail_attempts = 0
        for index, keyword in enumerate(keywords):
            if stats.unique_seen >= args.max_total:
                logger.info("MAX_TOTAL_LIMIT reached=%d", args.max_total)
                break
            if index:
                time.sleep(random.uniform(args.keyword_delay_min, args.keyword_delay_max))
            try:
                try:
                    text = client.call_tool(
                        "search_feeds",
                        {"keyword": keyword, "filters": {"sort_by": "最新"}},
                    )
                    search_payload = json_from_tool_text(text)
                except Exception as first_exc:
                    if "筛选" not in str(first_exc) and "点击" not in str(first_exc):
                        raise
                    logger.warning("search filter fallback keyword=%s", keyword)
                    time.sleep(2.0)
                    text = client.call_tool("search_feeds", {"keyword": keyword})
                    search_payload = json_from_tool_text(text)

                feeds = search_payload.get("feeds", []) if isinstance(search_payload, dict) else []
                if not isinstance(feeds, list):
                    feeds = []
                stats.searches_ok += 1
                stats.returned += len(feeds)
                keyword_new = 0
                keyword_dedup = 0
                for feed in feeds[: args.per_keyword_limit]:
                    if not isinstance(feed, dict):
                        continue
                    search_record = search_note(feed)
                    key = record_key(search_record)
                    if not key:
                        continue
                    if key in seen_this_run:
                        keyword_dedup += 1
                        continue
                    seen_this_run.add(key)
                    stats.unique_seen += 1
                    now_text = iso_now()
                    if key in records:
                        record = records[key]
                        old_keywords = set(record.get("matched_keywords") or [])
                        old_keywords.add(keyword)
                        record["matched_keywords"] = sorted(old_keywords, key=str.casefold)
                        record["last_seen_at"] = now_text
                        merge_non_null(record, search_record)
                        stats.deduped += 1
                        continue

                    record = {
                        "id": search_record.get("id"),
                        "keyword": keyword,
                        "matched_keywords": [keyword],
                        "title": search_record.get("title"),
                        "author": search_record.get("author"),
                        "published_at": search_record.get("published_at"),
                        "url": search_record.get("url"),
                        "summary": search_record.get("summary"),
                        "likes": search_record.get("likes"),
                        "comments": search_record.get("comments"),
                        "collects": search_record.get("collects"),
                        "location": search_record.get("location"),
                        "first_seen_at": now_text,
                        "last_seen_at": now_text,
                    }
                    if detail_attempts < args.max_details and feed.get("xsecToken") and feed.get("id"):
                        detail_attempts += 1
                        time.sleep(random.uniform(args.detail_delay_min, args.detail_delay_max))
                        try:
                            detail_text = client.call_tool(
                                "get_feed_detail",
                                {"feed_id": feed["id"], "xsec_token": feed["xsecToken"]},
                                timeout=args.detail_timeout,
                            )
                            detail_record = detail_note(json_from_tool_text(detail_text))
                            merge_non_null(record, detail_record)
                            stats.details_ok += 1
                            detail_count += 1
                        except Exception as detail_exc:
                            classified = classify_exception(detail_exc)
                            if isinstance(classified, (LoginRequired, RiskControlTriggered)):
                                raise classified
                            stats.details_failed += 1
                            logger.warning(
                                "detail_failed keyword=%s id=%s reason=%s",
                                keyword,
                                record.get("id"),
                                safe_error(detail_exc),
                            )
                    records[key] = record
                    keyword_new += 1
                    stats.newly_added += 1
                logger.info(
                    "SEARCH keyword=%s returned=%d new=%d deduped=%d",
                    keyword,
                    len(feeds),
                    keyword_new,
                    keyword_dedup,
                )
            except Exception as exc:
                classified = classify_exception(exc)
                if isinstance(classified, LoginRequired):
                    logger.error("LOGIN_REQUIRED keyword=%s", keyword)
                    return 20
                if isinstance(classified, RiskControlTriggered):
                    logger.error("RISK_CONTROL_TRIGGERED keyword=%s", keyword)
                    return 21
                stats.searches_failed += 1
                logger.warning("SEARCH_FAILED keyword=%s reason=%s", keyword, safe_error(classified))

        if stats.searches_ok == 0:
            logger.error("MCP_FAILED all searches failed; previous output preserved")
            return 22

        trimmed = trim_history(records, args.max_age_days, started)
        write_output(output_path, trimmed, started)
        logger.info(
            "TASK_END success searches_ok=%d searches_failed=%d returned=%d unique=%d "
            "new=%d deduped=%d details_ok=%d details_failed=%d records=%d",
            stats.searches_ok,
            stats.searches_failed,
            stats.returned,
            stats.unique_seen,
            stats.newly_added,
            stats.deduped,
            stats.details_ok,
            stats.details_failed,
            len(trimmed),
        )
        print(
            json.dumps(
                {
                    "success": True,
                    "searches_ok": stats.searches_ok,
                    "searches_failed": stats.searches_failed,
                    "returned": stats.returned,
                    "unique_seen": stats.unique_seen,
                    "new": stats.newly_added,
                    "deduped": stats.deduped,
                    "details_ok": stats.details_ok,
                    "records": len(trimmed),
                    "output": str(output_path),
                },
                ensure_ascii=False,
            )
        )
        return 0
    except LoginRequired:
        logger.error("LOGIN_REQUIRED")
        return 20
    except RiskControlTriggered:
        logger.error("RISK_CONTROL_TRIGGERED")
        return 21
    except Exception as exc:
        logger.exception("MCP_FAILED reason=%s", safe_error(exc))
        return 22
    finally:
        for handler in logger.handlers:
            handler.flush()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only Xiaohongshu MCP collector")
    script_root = Path(__file__).resolve().parents[1]
    parser.add_argument("--root", default=str(script_root))
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    parser.add_argument("--keywords", default=str(script_root / "config" / "keywords.json"))
    parser.add_argument("--per-keyword-limit", type=int, default=DEFAULT_PER_KEYWORD_LIMIT)
    parser.add_argument("--max-total", type=int, default=DEFAULT_MAX_TOTAL)
    parser.add_argument("--max-details", type=int, default=DEFAULT_MAX_DETAILS)
    parser.add_argument("--detail-timeout", type=int, default=DEFAULT_DETAIL_TIMEOUT)
    parser.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
    parser.add_argument("--keyword-delay-min", type=float, default=2.0)
    parser.add_argument("--keyword-delay-max", type=float, default=5.0)
    parser.add_argument("--detail-delay-min", type=float, default=1.0)
    parser.add_argument("--detail-delay-max", type=float, default=2.5)
    return parser.parse_args()


if __name__ == "__main__":
    sys.exit(run(parse_args()))
