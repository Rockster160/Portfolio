# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2.0", "httpx>=0.27"]
# ///
"""
Read-only MCP server for the BlueBubbles REST API.

Every tool below performs a GET (or a POST that the BlueBubbles API happens to
model as a search — never a mutation). No message-send / delete / attachment-
upload / any state-changing endpoint is wired. This file is the single source
of truth for what the model can do — if a tool isn't defined here, the model
cannot call it.

Launched via `uv run` (see .mcp.json). Requires BLUE_BUBBLES_SERVER_PASSWORD
in the process env; base URL defaults to http://localhost:1234 and can be
overridden with BLUE_BUBBLES_SERVER_URL.
"""

from __future__ import annotations

import os
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

BASE_URL = os.environ.get("BLUE_BUBBLES_SERVER_URL", "http://localhost:1234").rstrip("/")
PASSWORD = os.environ.get("BLUE_BUBBLES_SERVER_PASSWORD")
if not PASSWORD:
    raise SystemExit(
        "BLUE_BUBBLES_SERVER_PASSWORD is not set. Add it to ~/.zshenv or the MCP env."
    )

TIMEOUT = httpx.Timeout(15.0, connect=5.0)
mcp = FastMCP("bluebubbles-readonly")


def _get(path: str, params: dict[str, Any] | None = None) -> Any:
    q = {"password": PASSWORD, **(params or {})}
    with httpx.Client(timeout=TIMEOUT) as client:
        r = client.get(f"{BASE_URL}{path}", params=q)
    r.raise_for_status()
    return r.json()


def _post(path: str, body: dict[str, Any]) -> Any:
    with httpx.Client(timeout=TIMEOUT) as client:
        r = client.post(
            f"{BASE_URL}{path}",
            params={"password": PASSWORD},
            json=body,
        )
    r.raise_for_status()
    return r.json()


@mcp.tool()
def server_info() -> dict:
    """Return the BlueBubbles server's own status and identity info.

    Useful as a sanity check that the MCP is reachable and the password is
    valid before running heavier queries.
    """
    return _get("/api/v1/server/info")


@mcp.tool()
def list_chats(
    limit: int = 25,
    offset: int = 0,
    with_last_message: bool = True,
    with_participants: bool = True,
) -> dict:
    """List conversations (chats), most recent first.

    Args:
        limit: Max chats to return (BlueBubbles caps at 1000).
        offset: Pagination offset.
        with_last_message: Include each chat's most recent message preview.
        with_participants: Include participant handles (phone/email).

    Returns the raw BlueBubbles response envelope: {status, message, data: [...]}
    Each chat has a `guid` (e.g. "iMessage;-;+15551234567") used by other tools.
    """
    withs: list[str] = []
    if with_last_message:
        withs.append("lastMessage")
    if with_participants:
        withs.append("participants")

    return _post("/api/v1/chat/query", {
        "limit": max(1, min(int(limit), 1000)),
        "offset": max(0, int(offset)),
        "with": withs,
        "sort": "lastmessage",
    })


@mcp.tool()
def get_chat(
    chat_guid: str,
    with_participants: bool = True,
    with_last_message: bool = True,
) -> dict:
    """Fetch a single chat by its GUID.

    Args:
        chat_guid: The chat's guid as returned by list_chats (e.g. "iMessage;-;+15551234567").
        with_participants: Include participant handles.
        with_last_message: Include the last message preview.
    """
    withs: list[str] = []
    if with_participants:
        withs.append("participants")
    if with_last_message:
        withs.append("lastmessage")
    return _get(f"/api/v1/chat/{chat_guid}", {"with": ",".join(withs) if withs else None})


@mcp.tool()
def get_chat_messages(
    chat_guid: str,
    limit: int = 25,
    offset: int = 0,
    with_attachments: bool = False,
    with_handle: bool = True,
    sort: str = "DESC",
    before: int | None = None,
    after: int | None = None,
) -> dict:
    """Get messages inside a specific chat.

    Args:
        chat_guid: The chat's guid.
        limit: Max messages to return (up to 1000).
        offset: Pagination offset (older-than-limit messages).
        with_attachments: Include attachment metadata (not the file bytes).
        with_handle: Include sender handle (phone/email + service).
        sort: "DESC" for newest first (default) or "ASC" for oldest first.
        before: Only messages with `dateCreated` (ms since epoch) < this value.
        after:  Only messages with `dateCreated` (ms since epoch) > this value.
    """
    withs: list[str] = []
    if with_attachments:
        withs.append("attachment")
    if with_handle:
        withs.append("handle")

    params: dict[str, Any] = {
        "limit": max(1, min(int(limit), 1000)),
        "offset": max(0, int(offset)),
        "sort": sort.upper() if sort.upper() in ("ASC", "DESC") else "DESC",
    }
    if withs:
        params["with"] = ",".join(withs)
    if before is not None:
        params["before"] = int(before)
    if after is not None:
        params["after"] = int(after)

    return _get(f"/api/v1/chat/{chat_guid}/message", params)


@mcp.tool()
def search_messages(
    text: str | None = None,
    chat_guid: str | None = None,
    from_me: bool | None = None,
    limit: int = 25,
    offset: int = 0,
    before: int | None = None,
    after: int | None = None,
    with_chats: bool = True,
    with_handle: bool = True,
) -> dict:
    """Search messages across all chats.

    At least one of `text`, `chat_guid`, `from_me`, `before`, or `after`
    should be provided to keep the result set bounded.

    Args:
        text: Substring to match in message body.
        chat_guid: Restrict search to a single chat.
        from_me: True → only messages I sent; False → only received; None → both.
        limit: Max messages returned.
        offset: Pagination offset.
        before: Only messages with `dateCreated` (ms since epoch) < this value.
        after:  Only messages with `dateCreated` (ms since epoch) > this value.
        with_chats: Include the chat each message belongs to.
        with_handle: Include sender handle.
    """
    body: dict[str, Any] = {
        "limit": max(1, min(int(limit), 1000)),
        "offset": max(0, int(offset)),
        "sort": "DESC",
        "convertAttachments": False,
    }
    withs: list[str] = []
    if with_chats:
        withs.append("chats")
    if with_handle:
        withs.append("handle")
    if withs:
        body["with"] = withs

    where: list[dict[str, Any]] = []
    if text:
        where.append({"statement": "message.text LIKE :text", "args": {"text": f"%{text}%"}})
    if chat_guid:
        body["chatGuid"] = chat_guid
    if from_me is True:
        where.append({"statement": "message.is_from_me = :fromMe", "args": {"fromMe": 1}})
    elif from_me is False:
        where.append({"statement": "message.is_from_me = :fromMe", "args": {"fromMe": 0}})
    if before is not None:
        body["before"] = int(before)
    if after is not None:
        body["after"] = int(after)
    if where:
        body["where"] = where

    return _post("/api/v1/message/query", body)


@mcp.tool()
def list_contacts(extra_properties: bool = False) -> dict:
    """Return the address-book contacts BlueBubbles can see.

    Args:
        extra_properties: If true, include additional per-contact metadata
            (birthday, notes, etc.) which makes the response noticeably larger.
    """
    params: dict[str, Any] = {}
    if extra_properties:
        params["extraProperties"] = "true"
    return _get("/api/v1/contact", params)


@mcp.tool()
def query_handles(address: str | None = None, limit: int = 50, offset: int = 0) -> dict:
    """Look up handles (phone numbers / emails) known to Messages.

    Args:
        address: Filter by address substring (e.g. "555" or "@gmail.com").
        limit: Max handles returned.
        offset: Pagination offset.
    """
    body: dict[str, Any] = {
        "limit": max(1, min(int(limit), 1000)),
        "offset": max(0, int(offset)),
    }
    if address:
        body["where"] = [{
            "statement": "handle.id LIKE :addr",
            "args": {"addr": f"%{address}%"},
        }]
    return _post("/api/v1/handle/query", body)


if __name__ == "__main__":
    mcp.run()
