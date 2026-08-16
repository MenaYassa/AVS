"""Plugin adapter + API tests (architecture §4.11).

Exercises the OAuth2 credential store, the Notion/Slack adapters (hermetic,
`httpx.MockTransport` — no network), and the `/api/v1/plugins` surface:
auth-url → state-checked token exchange → push → disconnect.

Adapter HTTP responses are recorded on-disk as golden fixtures under
`tests/fixtures/plugins/` (see `test_providers.py` for the same pattern) so
the exact payloads adapters rely on are versioned and diffable.
"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest
from app import plugins as plugins_module
from app import secrets as secrets_module
from app.main import app
from app.plugins.base import PluginNotFoundError, PluginPushError
from app.plugins.registry import (
    delete_credentials,
    get_plugin,
    is_connected,
    load_credentials,
    pop_pending_state,
    register_plugin,
    save_credentials,
    save_pending_state,
    set_http_client_factory,
    unregister_plugin,
)
from app.plugins.targets import NotionPlugin, SlackPlugin
from fastapi.testclient import TestClient

client = TestClient(app)

_FIXTURES = Path(__file__).parent / "fixtures" / "plugins"


def _fixture(name: str) -> dict:
    return json.loads((_FIXTURES / f"{name}.json").read_text())


@pytest.fixture(autouse=True)
def reset_secret_store():
    """Each test starts with a fresh in-memory secret store."""
    secrets_module._secret_store = secrets_module.MemorySecretStore()
    yield
    secrets_module._secret_store = None


@pytest.fixture(autouse=True)
def _configure_oauth(monkeypatch: pytest.MonkeyPatch):
    """Give every plugin a fake client_id/secret so `configured` is true."""

    def _config(kind: str) -> dict[str, str]:
        return {
            "notion": {"client_id": "n-id", "client_secret": "n-secret"},
            "slack": {"client_id": "s-id", "client_secret": "s-secret"},
        }[kind]

    monkeypatch.setattr(plugins_module.registry, "plugin_client_config", _config)


def _mock_client() -> httpx.AsyncClient:
    """Serves the recorded adapter fixtures — no network (architecture §4.11)."""

    def _handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/v1/oauth/token":
            return httpx.Response(200, json=_fixture("notion_token"))
        if path == "/v1/pages":
            return httpx.Response(200, json=_fixture("notion_pages"))
        if path == "/api/oauth.v2.access":
            return httpx.Response(200, json=_fixture("slack_token"))
        if path == "/api/chat.postMessage":
            return httpx.Response(200, json=_fixture("slack_post_message"))
        return httpx.Response(404, json={})

    return httpx.AsyncClient(transport=httpx.MockTransport(_handler))


@pytest.fixture(autouse=True)
def _mock_http():
    set_http_client_factory(_mock_client)
    yield
    set_http_client_factory(_default_http_client)


def _default_http_client() -> httpx.AsyncClient:
    return httpx.AsyncClient()


# --- adapter unit tests -----------------------------------------------------


async def _notion() -> NotionPlugin:
    return NotionPlugin(
        client=_mock_client(), client_id="n-id", client_secret="n-secret"
    )


async def _slack() -> SlackPlugin:
    return SlackPlugin(
        client=_mock_client(), client_id="s-id", client_secret="s-secret"
    )


async def test_notion_authorization_url() -> None:
    plugin = await _notion()
    url = plugin.authorization_url("https://app/oauth", "state-1")
    assert "client_id=n-id" in url
    assert "state=state-1" in url
    assert "response_type=code" in url
    assert "redirect_uri=https%3A%2F%2Fapp%2Foauth" in url



async def test_notion_exchange_and_refresh() -> None:
    plugin = await _notion()
    creds = await plugin.exchange_token("code-1", "https://app/oauth")
    assert creds.access_token == "n-access"
    assert creds.refresh_token == "n-refresh"
    refreshed = await plugin.refresh("n-refresh")
    assert refreshed.access_token == "n-access"



async def test_notion_push_builds_page() -> None:
    plugin = await _notion()
    creds = await plugin.exchange_token("code-1", "https://app/oauth")
    draft = {
        "title": "Meeting minutes",
        "body": "Line one\nLine two",
        "items": [{"title": "Follow up", "type": "task"}],
    }
    receipt = await plugin.push(creds, draft)
    assert receipt.ok
    assert receipt.external_id == "page-1"
    assert receipt.target_url == "https://notion.so/page-1"
    assert plugin._transform(draft, "parent-page")["parent"] == {
        "type": "page_id",
        "page_id": "parent-page",
    }
    transform = plugin._transform(draft, None)
    assert transform["parent"] == {"type": "workspace", "workspace": True}
    assert len(transform["children"]) == 3  # 2 body lines + 1 item



async def test_slack_push_posts_markdown() -> None:
    plugin = await _slack()
    creds = await plugin.exchange_token("code-1", "https://app/oauth")
    draft = {"title": "Report", "body": "Summary here", "items": [{"title": "Action"}]}
    receipt = await plugin.push(creds, draft, target="#team")
    assert receipt.ok
    assert receipt.external_id == "1234.567"
    assert receipt.message == "Posted to #team"
    assert "*Report*" in plugin._markdown(draft)
    assert "• Action" in plugin._markdown(draft)



async def test_slack_push_error_raises() -> None:
    async def _handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/oauth.v2.access":
            return httpx.Response(
                200,
                json={"ok": True, "access_token": "s-access", "token_type": "Bearer"},
            )
        return httpx.Response(200, json={"ok": False, "error": "channel_not_found"})

    client_ = httpx.AsyncClient(transport=httpx.MockTransport(_handler))
    plugin = SlackPlugin(client=client_, client_id="s-id", client_secret="s-secret")
    creds = await plugin.exchange_token("code-1", "https://app/oauth")
    with pytest.raises(PluginPushError) as exc_info:
        await plugin.push(creds, {"title": "T"}, target="#missing")
    assert "channel_not_found" in str(exc_info.value)


async def test_notion_push_requests_match_recorded_fixture() -> None:
    """The fixture golden captures the exact request the adapter sends, so a
    drift in the payload or the fixture is caught (no hidden contract)."""
    captured: list[dict] = []

    async def _handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/oauth/token":
            return httpx.Response(200, json=_fixture("notion_token"))
        captured.append(json.loads(request.content))
        return httpx.Response(200, json=_fixture("notion_pages"))

    plugin = NotionPlugin(
        client=httpx.AsyncClient(transport=httpx.MockTransport(_handler)),
        client_id="n-id",
        client_secret="n-secret",
    )
    creds = await plugin.exchange_token("code-1", "https://app/oauth")
    await plugin.push(
        creds,
        {"title": "Minutes", "body": "Body line", "items": [{"title": "Action"}]},
    )

    assert len(captured) == 1
    body = captured[0]
    assert body["parent"] == {"type": "workspace", "workspace": True}
    assert body["properties"]["title"]["title"][0]["text"]["content"] == "Minutes"
    assert body["children"] == [
        {
            "object": "block",
            "type": "paragraph",
            "paragraph": {
                "rich_text": [{"type": "text", "text": {"content": "Body line"}}]
            },
        },
        {
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": {
                "rich_text": [{"type": "text", "text": {"content": "Action"}}]
            },
        },
    ]


async def test_slack_push_requests_match_recorded_fixture() -> None:
    captured: list[dict] = []

    async def _handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/oauth.v2.access":
            return httpx.Response(200, json=_fixture("slack_token"))
        captured.append(json.loads(request.content))
        return httpx.Response(200, json=_fixture("slack_post_message"))

    plugin = SlackPlugin(
        client=httpx.AsyncClient(transport=httpx.MockTransport(_handler)),
        client_id="s-id",
        client_secret="s-secret",
    )
    creds = await plugin.exchange_token("code-1", "https://app/oauth")
    await plugin.push(creds, {"title": "Report", "body": "Body"}, target="#team")

    assert len(captured) == 1
    assert captured[0]["channel"] == "#team"
    assert captured[0]["text"] == "*Report*\n\nBody"


def test_registry_unknown_kind_raises() -> None:
    with pytest.raises(PluginNotFoundError):
        get_plugin("does_not_exist")


def test_registry_register_unregister_round_trip(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _fake_plugin() -> SlackPlugin:
        return SlackPlugin(client=_mock_client(), client_id="", client_secret="")

    monkeypatch.setattr(plugins_module.registry, "plugin_client_config", lambda k: {})
    register_plugin("test_plugin", _fake_plugin)
    try:
        assert get_plugin("test_plugin").kind == "slack"
    finally:
        unregister_plugin("test_plugin")


def test_credential_store_round_trip() -> None:
    from app.plugins.base import PluginCredentials

    creds = PluginCredentials(kind="notion", access_token="tok")
    save_credentials("u1", creds)
    assert is_connected("u1", "notion")
    assert load_credentials("u1", "notion") == creds
    delete_credentials("u1", "notion")
    assert not is_connected("u1", "notion")
    assert load_credentials("u1", "notion") is None


def test_pending_state_round_trip() -> None:
    save_pending_state("u1", "notion", "state-abc")
    assert pop_pending_state("u1", "notion") == "state-abc"
    assert pop_pending_state("u1", "notion") is None


# --- API surface ------------------------------------------------------------


def test_list_plugins() -> None:
    response = client.get("/api/v1/plugins", headers={"X-User-Id": "u1"})
    assert response.status_code == 200
    plugins = response.json()["data"]["plugins"]
    kinds = {p["kind"]: p for p in plugins}
    assert set(kinds) == {"notion", "slack"}
    assert kinds["notion"]["connected"] is False
    assert kinds["notion"]["configured"] is True


def test_auth_url_flow() -> None:
    response = client.get(
        "/api/v1/plugins/notion/auth-url",
        params={"redirect_uri": "https://app/oauth"},
        headers={"X-User-Id": "u1"},
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["kind"] == "notion"
    assert data["state"]
    assert "client_id=n-id" in data["url"]


def test_token_exchange_rejects_bad_state() -> None:
    response = client.post(
        "/api/v1/plugins/notion/token",
        headers={"X-User-Id": "u1"},
        json={"code": "c", "state": "wrong", "redirect_uri": "https://app/oauth"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "OAUTH_STATE_INVALID"


def test_token_exchange_connects() -> None:
    # Obtain a valid pending state first.
    auth = client.get(
        "/api/v1/plugins/notion/auth-url",
        params={"redirect_uri": "https://app/oauth"},
        headers={"X-User-Id": "u1"},
    ).json()["data"]

    response = client.post(
        "/api/v1/plugins/notion/token",
        headers={"X-User-Id": "u1"},
        json={"code": "code-1", "state": auth["state"], "redirect_uri": "https://app/oauth"},
    )
    assert response.status_code == 200
    assert response.json()["data"]["connected"] is True
    assert is_connected("u1", "notion")


def test_push_requires_connection() -> None:
    response = client.post(
        "/api/v1/plugins/notion/push",
        headers={"X-User-Id": "u1"},
        json={"draft": {"title": "T", "body": ""}},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "PLUGIN_NOT_CONNECTED"


def test_push_rejects_invalid_draft() -> None:
    response = client.post(
        "/api/v1/plugins/notion/push",
        headers={"X-User-Id": "u1"},
        json={"draft": {"body": "missing title"}},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "DRAFT_INVALID"


def test_push_round_trip() -> None:
    auth = client.get(
        "/api/v1/plugins/notion/auth-url",
        params={"redirect_uri": "https://app/oauth"},
        headers={"X-User-Id": "u1"},
    ).json()["data"]
    client.post(
        "/api/v1/plugins/notion/token",
        headers={"X-User-Id": "u1"},
        json={"code": "code-1", "state": auth["state"], "redirect_uri": "https://app/oauth"},
    )

    response = client.post(
        "/api/v1/plugins/notion/push",
        headers={"X-User-Id": "u1"},
        json={
            "draft": {
                "title": "Minutes",
                "body": "Body",
                "items": [{"title": "Action"}],
            }
        },
    )
    assert response.status_code == 200
    receipt = response.json()["data"]
    assert receipt["ok"] is True
    assert receipt["kind"] == "notion"
    assert receipt["external_id"] == "page-1"


def test_slack_push_round_trip() -> None:
    auth = client.get(
        "/api/v1/plugins/slack/auth-url",
        params={"redirect_uri": "https://app/oauth"},
        headers={"X-User-Id": "u1"},
    ).json()["data"]
    client.post(
        "/api/v1/plugins/slack/token",
        headers={"X-User-Id": "u1"},
        json={"code": "code-1", "state": auth["state"], "redirect_uri": "https://app/oauth"},
    )

    response = client.post(
        "/api/v1/plugins/slack/push",
        headers={"X-User-Id": "u1"},
        json={"draft": {"title": "Report", "body": "Body"}, "target": "#team"},
    )
    assert response.status_code == 200
    receipt = response.json()["data"]
    assert receipt["ok"] is True
    assert receipt["external_id"] == "1234.567"
    assert receipt["target_url"].startswith("https://team.slack.com")


def test_disconnect() -> None:
    auth = client.get(
        "/api/v1/plugins/notion/auth-url",
        params={"redirect_uri": "https://app/oauth"},
        headers={"X-User-Id": "u1"},
    ).json()["data"]
    client.post(
        "/api/v1/plugins/notion/token",
        headers={"X-User-Id": "u1"},
        json={"code": "code-1", "state": auth["state"], "redirect_uri": "https://app/oauth"},
    )
    assert is_connected("u1", "notion")

    response = client.delete(
        "/api/v1/plugins/notion/credentials", headers={"X-User-Id": "u1"}
    )
    assert response.status_code == 200
    assert response.json()["data"]["connected"] is False
    assert not is_connected("u1", "notion")


def test_unknown_plugin_kind() -> None:
    response = client.get(
        "/api/v1/plugins/nope/auth-url",
        params={"redirect_uri": "https://app/oauth"},
        headers={"X-User-Id": "u1"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "PLUGIN_UNKNOWN"
