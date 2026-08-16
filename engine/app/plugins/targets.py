"""First plugin targets (architecture §4.11).

Two representative adapters:
- **Notion** — structured: the draft becomes a page (parent workspace or a
  page id passed as `target`) with the body as paragraphs and items as
  bulleted list blocks.
- **Slack** — Markdown: the draft becomes a chat.postMessage to `target`
  (channel name, default `#general`).
"""

from __future__ import annotations

from typing import Any
from urllib.parse import urlencode

import httpx

from app.plugins.base import (
    Plugin,
    PluginAuthError,
    PluginCredentials,
    PluginPushError,
    PushReceipt,
    _error_details,
)

_NOTION_MAX_BLOCK_CHARS = 2000
_NOTION_VERSION = "2022-06-28"


class NotionPlugin(Plugin):
    kind = "notion"
    display_name = "Notion"
    scopes = ["read_content", "write_content"]

    auth_base_url = "https://api.notion.com/v1/oauth/authorize"
    token_url = "https://api.notion.com/v1/oauth/token"
    pages_url = "https://api.notion.com/v1/pages"

    def authorization_url(self, redirect_uri: str, state: str) -> str:
        params = urlencode(
            {
                "client_id": self.client_id,
                "redirect_uri": redirect_uri,
                "response_type": "code",
                "owner": "user",
                "state": state,
            }
        )
        return f"{self.auth_base_url}?{params}"

    def _credentials_from_response(self, resp: httpx.Response) -> PluginCredentials:
        if not resp.is_success:
            raise PluginAuthError(
                f"notion: token exchange failed (HTTP {resp.status_code})",
                details=_error_details(resp),
            )
        payload = resp.json()
        access_token = payload.get("access_token")
        if not access_token:
            raise PluginAuthError(
                "notion: token response missing access_token",
                details={"body": payload},
            )
        return PluginCredentials(
            kind=self.kind,
            access_token=access_token,
            refresh_token=payload.get("refresh_token"),
            token_type=payload.get("token_type", "Bearer"),
            scope=payload.get("scope"),
        )

    async def exchange_token(
        self, code: str, redirect_uri: str
    ) -> PluginCredentials:
        resp = await self.client.post(
            self.token_url,
            auth=(self.client_id, self.client_secret),
            json={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri,
            },
        )
        return self._credentials_from_response(resp)

    async def refresh(self, refresh_token: str) -> PluginCredentials:
        resp = await self.client.post(
            self.token_url,
            auth=(self.client_id, self.client_secret),
            json={"grant_type": "refresh_token", "refresh_token": refresh_token},
        )
        return self._credentials_from_response(resp)

    @staticmethod
    def _body_blocks(draft: dict[str, Any]) -> list[dict[str, Any]]:
        blocks: list[dict[str, Any]] = []
        for line in (draft.get("body") or "").splitlines():
            content = line.strip()
            if not content:
                continue
            for chunk in (
                content[i : i + _NOTION_MAX_BLOCK_CHARS]
                for i in range(0, len(content), _NOTION_MAX_BLOCK_CHARS)
            ):
                blocks.append(
                    {
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": {
                            "rich_text": [
                                {"type": "text", "text": {"content": chunk}}
                            ]
                        },
                    }
                )
        for item in draft.get("items") or []:
            title = str(item.get("title") or "").strip()
            if not title:
                continue
            blocks.append(
                {
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": {
                        "rich_text": [
                            {"type": "text", "text": {"content": title[:2000]}}
                        ]
                    },
                }
            )
        return blocks

    def _transform(
        self, draft: dict[str, Any], target: str | None
    ) -> dict[str, Any]:
        parent: dict[str, Any] = (
            {"type": "page_id", "page_id": target}
            if target
            else {"type": "workspace", "workspace": True}
        )
        return {
            "parent": parent,
            "properties": {
                "title": {
                    "title": [
                        {
                            "type": "text",
                            "text": {"content": draft.get("title", "")},
                        }
                    ]
                }
            },
            "children": self._body_blocks(draft),
        }

    async def push(
        self,
        credentials: PluginCredentials,
        draft: dict[str, Any],
        target: str | None = None,
    ) -> PushReceipt:
        payload = self._transform(draft, target)
        resp = await self.client.post(
            self.pages_url,
            headers={
                "Authorization": f"{credentials.token_type} {credentials.access_token}",
                "Notion-Version": _NOTION_VERSION,
                "Content-Type": "application/json",
            },
            json=payload,
        )
        if not resp.is_success:
            raise PluginPushError(
                f"notion: push failed (HTTP {resp.status_code})",
                details=_error_details(resp),
            )
        data = resp.json()
        url = next(
            (data.get(key) for key in ("public_url", "url") if data.get(key)),
            None,
        )
        return PushReceipt(
            kind=self.kind,
            ok=True,
            target_url=url,
            external_id=data.get("id"),
            message="Created Notion page",
        )


class SlackPlugin(Plugin):
    kind = "slack"
    display_name = "Slack"
    scopes = ["chat:write"]

    auth_base_url = "https://slack.com/oauth/v2/authorize"
    token_url = "https://slack.com/api/oauth.v2.access"
    post_url = "https://slack.com/api/chat.postMessage"

    def authorization_url(self, redirect_uri: str, state: str) -> str:
        params = urlencode(
            {
                "client_id": self.client_id,
                "scope": " ".join(self.scopes),
                "redirect_uri": redirect_uri,
                "state": state,
            }
        )
        return f"{self.auth_base_url}?{params}"

    async def exchange_token(
        self, code: str, redirect_uri: str
    ) -> PluginCredentials:
        resp = await self.client.post(
            self.token_url,
            data={
                "client_id": self.client_id,
                "client_secret": self.client_secret,
                "code": code,
                "redirect_uri": redirect_uri,
            },
        )
        if not resp.is_success:
            raise PluginAuthError(
                f"slack: token exchange failed (HTTP {resp.status_code})",
                details=_error_details(resp),
            )
        payload = resp.json()
        access_token = payload.get("access_token")
        if not payload.get("ok") or not access_token:
            raise PluginAuthError(
                f"slack: token exchange failed: {payload.get('error', 'unknown')}",
                details={"body": payload},
            )
        return PluginCredentials(
            kind=self.kind,
            access_token=access_token,
            token_type=payload.get("token_type", "Bearer"),
            scope=payload.get("scope"),
        )

    async def refresh(self, refresh_token: str) -> PluginCredentials:
        # Slack access tokens are long-lived; "refresh" is a no-op.
        return PluginCredentials(
            kind=self.kind, access_token=refresh_token, token_type="Bearer"
        )

    @staticmethod
    def _markdown(draft: dict[str, Any]) -> str:
        parts = [f"*{draft.get('title', '')}*"]
        if draft.get("body"):
            parts.append(draft["body"])
        items = [
            str(item.get("title") or "").strip()
            for item in draft.get("items") or []
            if item.get("title")
        ]
        for item in items:
            parts.append(f"• {item}")
        return "\n\n".join(parts)

    async def push(
        self,
        credentials: PluginCredentials,
        draft: dict[str, Any],
        target: str | None = None,
    ) -> PushReceipt:
        channel = target or "#general"
        payload = {"channel": channel, "text": self._markdown(draft)}
        resp = await self.client.post(
            self.post_url,
            headers={"Authorization": f"Bearer {credentials.access_token}"},
            json=payload,
        )
        if not resp.is_success:
            raise PluginPushError(
                f"slack: push failed (HTTP {resp.status_code})",
                details=_error_details(resp),
            )
        data = resp.json()
        if not data.get("ok"):
            raise PluginPushError(
                f"slack: {data.get('error', 'unknown error')}",
                details={"body": data},
            )
        return PushReceipt(
            kind=self.kind,
            ok=True,
            target_url=data.get("permalink"),
            external_id=data.get("ts"),
            message=f"Posted to {channel}",
        )
