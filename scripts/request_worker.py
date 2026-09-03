#!/usr/bin/env python3
"""Process one read-only Xiaohongshu search request.

The PowerShell wrapper owns the project lock, MCP process, Chromium cleanup,
Git pull/push, and pending-to-completed move. This module only accepts the
strict request schema and calls the read-only MCP tools used by collector.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import random
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from collector import (  # noqa: E402
    MCPClient,
    LoginRequired,
    RiskControlTriggered,
    atomic_write_json,
    classify_exception,
    detail_note,
    iso_beijing,
    json_from_tool_text,
    merge_non_null,
    record_key,
    safe_error,
    search_note,
    setup_logger,
)


REQUEST_TYPE = "xiaohongshu_search"
REQUEST_STATUS = "pending"
REQUEST_MAX_DETAILS = 20
REQUEST_MAX_QUERY_LENGTH = 500
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
ALLOWED_FIELDS = {
    "request_id",
    "created_at",
    "status",
    "type",
    "query",
    "keywords",
    "max_results_per_keyword",
}


class RequestValidationError(ValueError):
    """The request file does not match the allowlisted schema."""


def parse_request_datetime(value: Any) -> None:
    if not isinstance(value, str) or not value.strip():
        raise RequestValidationError("created_at must be a non-empty ISO 8601 string")
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise RequestValidationError("created_at is not valid ISO 8601") from exc
    if parsed.tzinfo is None:
        raise RequestValidationError("created_at must include a timezone")


def validate_request_path(path: Path, root: Path) -> Path:
    pending_root = (root / "requests" / "pending").resolve()
    request_path = path.resolve()
    if request_path.parent != pending_root:
        raise RequestValidationError("request path must be directly under requests/pending")
    if request_path.suffix.lower() != ".json":
        raise RequestValidationError("request file must use the .json extension")
    return request_path


def load_request(path: Path, root: Path) -> dict[str, Any]:
    request_path = validate_request_path(path, root)
    try:
        value = json.loads(request_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RequestValidationError("request file could not be read") from exc
    except json.JSONDecodeError as exc:
        raise RequestValidationError("request file is not valid JSON") from exc

    if not isinstance(value, dict):
        raise RequestValidationError("request JSON must be an object")

    unknown = sorted(set(value) - ALLOWED_FIELDS)
    if unknown:
        raise RequestValidationError("request contains unsupported fields")

    required = {
        "request_id",
        "created_at",
        "status",
        "type",
        "query",
        "keywords",
        "max_results_per_keyword",
    }
    missing = required - set(value)
    if missing:
        raise RequestValidationError("request is missing required fields")

    request_id = value["request_id"]
    if (
        not isinstance(request_id, str)
        or not request_id
        or not REQUEST_ID_RE.fullmatch(request_id)
    ):
        raise RequestValidationError("request_id contains unsupported characters")
    if request_path.stem != request_id:
        raise RequestValidationError("request filename must match request_id")

    parse_request_datetime(value["created_at"])

    if value["status"] != REQUEST_STATUS:
        raise RequestValidationError("status must be pending")
    if value["type"] != REQUEST_TYPE:
        raise RequestValidationError("type is not allowlisted")

    query = value["query"]
    if (
        not isinstance(query, str)
        or not query.strip()
        or len(query.strip()) > REQUEST_MAX_QUERY_LENGTH
    ):
        raise RequestValidationError("query must be a non-empty short string")

    keywords = value["keywords"]
    if not isinstance(keywords, list) or not 1 <= len(keywords) <= 10:
        raise RequestValidationError("keywords must contain 1 to 10 strings")
    clean_keywords: list[str] = []
    for keyword in keywords:
        if not isinstance(keyword, str) or not keyword.strip() or len(keyword.strip()) > 100:
            raise RequestValidationError("each keyword must be 1 to 100 characters")
        clean_keyword = keyword.strip()
        if clean_keyword not in clean_keywords:
            clean_keywords.append(clean_keyword)
    if not clean_keywords:
        raise RequestValidationError("keywords must not be empty")

    limit = value["max_results_per_keyword"]
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 30:
        raise RequestValidationError("max_results_per_keyword must be an integer from 1 to 30")

    return {
        "request_id": request_id,
        "created_at": value["created_at"],
        "status": REQUEST_STATUS,
        "type": REQUEST_TYPE,
        "query": query.strip(),
        "keywords": clean_keywords,
        "max_results_per_keyword": limit,
        "_path": request_path,
    }


def result_path_for_request(root: Path, request_path: Path) -> Path:
    results_root = (root / "requests" / "results").resolve()
    results_root.mkdir(parents=True, exist_ok=True)
    # request_path.name is a basename selected by the local wrapper; it cannot
    # introduce a directory or be interpreted as a command.
    return results_root / request_path.name


def result_record(search_record: dict[str, Any], keyword: str) -> dict[str, Any]:
    return {
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
    }


def add_matched_keyword(record: dict[str, Any], keyword: str) -> None:
    values = {
        str(item)
        for item in record.get("matched_keywords", [])
        if isinstance(item, str) and item
    }
    if record.get("keyword"):
        values.add(str(record["keyword"]))
    values.add(keyword)
    record["matched_keywords"] = sorted(values, key=str.casefold)


def build_result_document(
    request: dict[str, Any],
    *,
    status: str,
    completed_at: str,
    records: dict[str, dict[str, Any]],
    failed_keywords: list[str],
    warnings: list[str],
) -> dict[str, Any]:
    ordered = list(records.values())
    ordered.sort(
        key=lambda item: (
            item.get("published_at") or "",
            item.get("url") or "",
        ),
        reverse=True,
    )
    return {
        "request_id": request["request_id"],
        "query": request["query"],
        "status": status,
        "created_at": request["created_at"],
        "completed_at": completed_at,
        "keywords": request["keywords"],
        "result_count": len(ordered),
        "results": ordered,
        "failed_keywords": failed_keywords,
        "warnings": warnings,
    }


def write_result(
    root: Path,
    request: dict[str, Any],
    *,
    status: str,
    records: dict[str, dict[str, Any]] | None = None,
    failed_keywords: list[str] | None = None,
    warnings: list[str] | None = None,
) -> Path:
    path = result_path_for_request(root, request["_path"])
    document = build_result_document(
        request,
        status=status,
        completed_at=iso_beijing(),
        records=records or {},
        failed_keywords=failed_keywords or [],
        warnings=warnings or [],
    )
    atomic_write_json(path, document)
    return path


def validate_only(path: Path, root: Path) -> int:
    request = load_request(path, root)
    print(json.dumps({"valid": True, "request_id": request["request_id"]}, ensure_ascii=False))
    return 0


def search_request(
    root: Path,
    request: dict[str, Any],
    *,
    mcp_url: str,
    detail_timeout: int,
    detail_delay_min: float,
    detail_delay_max: float,
    keyword_delay_min: float,
    keyword_delay_max: float,
    logger: logging.Logger,
) -> tuple[str, dict[str, dict[str, Any]], list[str], list[str]]:
    client = MCPClient(mcp_url, logger)
    records: dict[str, dict[str, Any]] = {}
    failed_keywords: list[str] = []
    warnings: list[str] = []
    searches_ok = 0
    detail_attempts = 0

    client.initialize()
    login_text = client.call_tool("check_login_status")
    if not login_text or "已登录" not in login_text:
        raise LoginRequired("login required")

    for index, keyword in enumerate(request["keywords"]):
        if index:
            time.sleep(random.uniform(keyword_delay_min, keyword_delay_max))
        logger.info("SEARCH_START request_id=%s keyword=%s", request["request_id"], keyword)
        try:
            try:
                text = client.call_tool(
                    "search_feeds",
                    {"keyword": keyword, "filters": {"sort_by": "最新"}},
                )
                payload = json_from_tool_text(text)
            except Exception as first_exc:
                if "筛选" not in str(first_exc) and "点击" not in str(first_exc):
                    raise
                logger.warning(
                    "SEARCH_FILTER_FALLBACK request_id=%s keyword=%s",
                    request["request_id"],
                    keyword,
                )
                time.sleep(2.0)
                text = client.call_tool("search_feeds", {"keyword": keyword})
                payload = json_from_tool_text(text)

            feeds = payload.get("feeds", []) if isinstance(payload, dict) else []
            if not isinstance(feeds, list):
                feeds = []
            searches_ok += 1
            keyword_new = 0
            keyword_deduped = 0

            for feed in feeds[: request["max_results_per_keyword"]]:
                if not isinstance(feed, dict):
                    continue
                search_record = search_note(feed)
                key = record_key(search_record)
                if not key:
                    continue

                if key in records:
                    add_matched_keyword(records[key], keyword)
                    merge_non_null(records[key], search_record)
                    keyword_deduped += 1
                    continue

                record = result_record(search_record, keyword)
                if (
                    detail_attempts < REQUEST_MAX_DETAILS
                    and feed.get("xsecToken")
                    and feed.get("id")
                ):
                    detail_attempts += 1
                    time.sleep(random.uniform(detail_delay_min, detail_delay_max))
                    try:
                        detail_text = client.call_tool(
                            "get_feed_detail",
                            {"feed_id": feed["id"], "xsec_token": feed["xsecToken"]},
                            timeout=detail_timeout,
                        )
                        merge_non_null(record, detail_note(json_from_tool_text(detail_text)))
                    except Exception as detail_exc:
                        classified = classify_exception(detail_exc)
                        if isinstance(classified, (LoginRequired, RiskControlTriggered)):
                            raise classified
                        warnings.append("one public detail request failed or timed out")
                        logger.warning(
                            "DETAIL_FAILED request_id=%s keyword=%s reason=%s",
                            request["request_id"],
                            keyword,
                            safe_error(detail_exc),
                        )

                records[key] = record
                keyword_new += 1

            logger.info(
                "SEARCH_DONE request_id=%s keyword=%s returned=%d new=%d deduped=%d",
                request["request_id"],
                keyword,
                len(feeds),
                keyword_new,
                keyword_deduped,
            )
        except Exception as exc:
            classified = classify_exception(exc)
            if isinstance(classified, (LoginRequired, RiskControlTriggered)):
                raise classified
            if keyword not in failed_keywords:
                failed_keywords.append(keyword)
            logger.warning(
                "SEARCH_FAILED request_id=%s keyword=%s reason=%s",
                request["request_id"],
                keyword,
                safe_error(classified),
            )

    if searches_ok == 0:
        warnings.append("all keyword searches failed")
        return "failed", records, failed_keywords, warnings
    if failed_keywords:
        warnings.append(f"{len(failed_keywords)} keyword(s) failed or timed out and were skipped")
    return "completed", records, failed_keywords, warnings


def process_request(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    logger = setup_logger(root / "logs" / "request-worker.log")
    request_path = Path(args.request).resolve()
    request: dict[str, Any] | None = None
    logger.info("REQUEST_START path=%s", request_path.name)

    try:
        request = load_request(request_path, root)
    except RequestValidationError as exc:
        safe_request = {
            "request_id": request_path.stem,
            "created_at": iso_beijing(),
            "query": "",
            "keywords": [],
            "max_results_per_keyword": 1,
            "_path": request_path,
        }
        result_path = write_result(
            root,
            safe_request,
            status="invalid_request",
            warnings=[safe_error(exc)],
        )
        logger.error("INVALID_REQUEST result=%s", result_path.name)
        print(json.dumps({"valid": False, "result": str(result_path)}, ensure_ascii=False))
        return 10

    try:
        status, records, failed_keywords, warnings = search_request(
            root,
            request,
            mcp_url=args.mcp_url,
            detail_timeout=args.detail_timeout,
            detail_delay_min=args.detail_delay_min,
            detail_delay_max=args.detail_delay_max,
            keyword_delay_min=args.keyword_delay_min,
            keyword_delay_max=args.keyword_delay_max,
            logger=logger,
        )
    except LoginRequired:
        status = "login_required"
        records = {}
        failed_keywords = []
        warnings = ["LOGIN_REQUIRED"]
        logger.error("LOGIN_REQUIRED request_id=%s", request["request_id"])
    except RiskControlTriggered:
        status = "risk_controlled"
        records = {}
        failed_keywords = []
        warnings = ["RISK_CONTROL_TRIGGERED"]
        logger.error("RISK_CONTROL_TRIGGERED request_id=%s", request["request_id"])
    except Exception as exc:
        status = "failed"
        records = {}
        failed_keywords = []
        warnings = ["MCP_FAILED"]
        logger.error(
            "MCP_FAILED request_id=%s reason=%s",
            request["request_id"],
            safe_error(exc),
        )

    result_path = write_result(
        root,
        request,
        status=status,
        records=records,
        failed_keywords=failed_keywords,
        warnings=warnings,
    )
    logger.info(
        "REQUEST_DONE request_id=%s status=%s result_count=%d failed_keywords=%d",
        request["request_id"],
        status,
        len(records),
        len(failed_keywords),
    )
    print(
        json.dumps(
            {
                "request_id": request["request_id"],
                "status": status,
                "result_count": len(records),
                "failed_keywords": failed_keywords,
                "result": str(result_path),
            },
            ensure_ascii=False,
        )
    )
    return {
        "completed": 0,
        "login_required": 20,
        "risk_controlled": 21,
        "failed": 22,
    }.get(status, 22)


def write_failure(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    logger = setup_logger(root / "logs" / "request-worker.log")
    request_path = Path(args.request).resolve()
    try:
        request = load_request(request_path, root)
    except RequestValidationError:
        # The normal validation path creates the more useful invalid_request
        # document; this fallback is only for a worker crash before validation.
        request = {
            "request_id": request_path.stem,
            "created_at": iso_beijing(),
            "query": "",
            "keywords": [],
            "max_results_per_keyword": 1,
            "_path": request_path,
        }
    result_path = write_result(
        root,
        request,
        status=args.failure_status,
        warnings=[args.warning],
    )
    logger.error("FAILURE_RESULT status=%s result=%s", args.failure_status, result_path.name)
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only one-request Xiaohongshu worker")
    parser.add_argument("--root", default=str(SCRIPT_ROOT.parent))
    parser.add_argument("--request", required=True)
    parser.add_argument("--mcp-url", default="http://127.0.0.1:18060/mcp")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--write-failure", action="store_true")
    parser.add_argument("--failure-status", default="failed")
    parser.add_argument("--warning", default="WORKER_FAILED")
    parser.add_argument("--detail-timeout", type=int, default=45)
    parser.add_argument("--detail-delay-min", type=float, default=1.0)
    parser.add_argument("--detail-delay-max", type=float, default=2.5)
    parser.add_argument("--keyword-delay-min", type=float, default=2.0)
    parser.add_argument("--keyword-delay-max", type=float, default=5.0)
    args = parser.parse_args()
    if args.failure_status not in {"failed", "login_required", "risk_controlled"}:
        parser.error("unsupported failure status")
    if args.validate_only and args.write_failure:
        parser.error("--validate-only and --write-failure are mutually exclusive")
    return args


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    request_path = Path(args.request).resolve()
    if args.validate_only:
        try:
            return validate_only(request_path, root)
        except RequestValidationError as exc:
            logger = setup_logger(root / "logs" / "request-worker.log")
            try:
                request = load_request(request_path, root)
            except RequestValidationError:
                request = {
                    "request_id": request_path.stem,
                    "created_at": iso_beijing(),
                    "query": "",
                    "keywords": [],
                    "max_results_per_keyword": 1,
                    "_path": request_path,
                }
            result_path = write_result(
                root,
                request,
                status="invalid_request",
                warnings=[safe_error(exc)],
            )
            logger.error("INVALID_REQUEST result=%s", result_path.name)
            print(json.dumps({"valid": False, "result": str(result_path)}, ensure_ascii=False))
            return 10
    if args.write_failure:
        return write_failure(args)
    return process_request(args)


if __name__ == "__main__":
    raise SystemExit(main())
