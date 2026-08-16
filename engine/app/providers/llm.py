"""LLM provider adapters (architecture §4.4).

One class per provider family; every adapter maps provider-native shapes to
the canonical `LLMProvider` contract and never leaks provider types into the
pipeline.

- `OpenAICompatibleLLM`: any `/chat/completions` endpoint — OpenAI, OpenRouter,
  Ollama, LM Studio, and user-supplied *custom* providers (base URL/model/key
  come from job options). Structured output uses the native
  `response_format={"type":"json_object"}` when a schema ref is requested.
- `AnthropicMessagesLLM`: Anthropic Messages API. No native JSON mode, so
  `complete_structured` falls back to prompt-constrained JSON + `extract_json`
  (the stage retry loop handles residual malformed output, §2.1).
- `GeminiLLM`: Gemini `generateContent` with `responseMimeType: application/json`
  for structured output.
"""

from __future__ import annotations

import json
import re
from typing import Any

import httpx
from app.providers.base import Message, ProviderOutputError

DEFAULT_TIMEOUT = httpx.Timeout(60.0, connect=10.0)


def extract_json(text: str) -> dict[str, Any]:
    """Parse the first balanced JSON object in provider text output.

    Tolerates markdown fences and surrounding prose (fallback path for
    providers without a native structured-output mode).
    """
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    start = cleaned.find("{")
    if start == -1:
        raise ProviderOutputError("provider output contains no JSON object")
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(cleaned)):
        char = cleaned[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                try:
                    parsed = json.loads(cleaned[start : index + 1])
                except json.JSONDecodeError as exc:
                    raise ProviderOutputError(
                        f"provider output is not valid JSON: {exc}"
                    ) from exc
                if not isinstance(parsed, dict):
                    raise ProviderOutputError("provider JSON output must be an object")
                return parsed
    raise ProviderOutputError("provider output contains no complete JSON object")


def _dict_messages(messages: list[Message]) -> list[dict[str, str]]:
    return [{"role": m.role, "content": m.content} for m in messages]


class OpenAICompatibleLLM:
    """OpenAI / OpenRouter / Ollama / LM Studio / custom chat-completions."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None = None,
        temperature: float | None = None,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self._temperature = temperature
        self._client = client

    async def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        client = self._client
        close = False
        if client is None:
            client = httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
            close = True
        try:
            response = await client.post(
                f"{self._base_url}{path}", json=payload, headers=headers
            )
            response.raise_for_status()
            return response.json()
        finally:
            if close:
                await client.aclose()

    async def complete(
        self,
        messages: list[Message],
        *,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        payload: dict[str, Any] = {
            "model": model or self.model,
            "messages": _dict_messages(messages),
            "temperature": temperature
            if temperature is not None
            else self._temperature,
            "max_tokens": max_tokens,
        }
        if payload["temperature"] is None:
            del payload["temperature"]
        if payload["max_tokens"] is None:
            del payload["max_tokens"]
        data = await self._post("/chat/completions", payload)
        try:
            return data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ProviderOutputError(f"malformed chat completion: {exc}") from exc

    async def complete_structured(
        self,
        prompt: str,
        json_schema: str | dict[str, Any] | None,
        *,
        system_prompt: str | None = None,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> dict[str, Any]:
        messages: list[dict[str, str]] = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        payload: dict[str, Any] = {
            "model": model or self.model,
            "messages": messages,
            "temperature": temperature
            if temperature is not None
            else self._temperature,
            "max_tokens": max_tokens,
        }
        if payload["temperature"] is None:
            del payload["temperature"]
        if payload["max_tokens"] is None:
            del payload["max_tokens"]
        if json_schema is not None:
            payload["response_format"] = {"type": "json_object"}
        data = await self._post("/chat/completions", payload)
        try:
            content = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ProviderOutputError(f"malformed chat completion: {exc}") from exc
        return extract_json(content)


class AnthropicMessagesLLM:
    """Anthropic Messages API with prompt-constrained JSON for structure."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None,
        temperature: float | None = None,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self._temperature = temperature
        self._client = client

    async def _post(self, payload: dict[str, Any]) -> dict[str, Any]:
        if not self._api_key:
            raise ProviderOutputError("Anthropic requires an API key")
        headers = {
            "x-api-key": self._api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
        client = self._client
        close = False
        if client is None:
            client = httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
            close = True
        try:
            response = await client.post(
                f"{self._base_url}/v1/messages", json=payload, headers=headers
            )
            response.raise_for_status()
            return response.json()
        finally:
            if close:
                await client.aclose()

    def _text(self, data: dict[str, Any]) -> str:
        try:
            parts = data["content"]
            return "".join(
                block.get("text", "") for block in parts if block.get("type") == "text"
            )
        except (KeyError, TypeError) as exc:
            raise ProviderOutputError(f"malformed messages response: {exc}") from exc

    async def complete(
        self,
        messages: list[Message],
        *,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        system = "\n".join(m.content for m in messages if m.role == "system")
        history = [
            {"role": m.role, "content": m.content}
            for m in messages
            if m.role != "system"
        ]
        payload: dict[str, Any] = {
            "model": model or self.model,
            "max_tokens": max_tokens or 1024,
            "messages": history,
        }
        if system:
            payload["system"] = system
        if temperature is not None or self._temperature is not None:
            payload["temperature"] = (
                temperature if temperature is not None else self._temperature
            )
        return self._text(await self._post(payload))

    async def complete_structured(
        self,
        prompt: str,
        json_schema: str | dict[str, Any] | None,
        *,
        system_prompt: str | None = None,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> dict[str, Any]:
        user_prompt = f"{prompt}\n\nRespond with a single JSON object and nothing else."
        payload: dict[str, Any] = {
            "model": model or self.model,
            "max_tokens": max_tokens or 4096,
            "messages": [{"role": "user", "content": user_prompt}],
        }
        if system_prompt:
            payload["system"] = system_prompt
        if temperature is not None or self._temperature is not None:
            payload["temperature"] = (
                temperature if temperature is not None else self._temperature
            )
        return extract_json(self._text(await self._post(payload)))


class GeminiLLM:
    """Google Gemini `generateContent` (structured via responseMimeType)."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None,
        temperature: float | None = None,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self._temperature = temperature
        self._client = client

    async def _generate(
        self, payload: dict[str, Any], model: str | None
    ) -> dict[str, Any]:
        if not self._api_key:
            raise ProviderOutputError("Gemini requires an API key")
        client = self._client
        close = False
        if client is None:
            client = httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
            close = True
        try:
            response = await client.post(
                f"{self._base_url}/v1beta/models/{model or self.model}:generateContent",
                json=payload,
                headers={
                    "x-goog-api-key": self._api_key,
                    "content-type": "application/json",
                },
            )
            response.raise_for_status()
            return response.json()
        finally:
            if close:
                await client.aclose()

    def _text(self, data: dict[str, Any]) -> str:
        try:
            parts = data["candidates"][0]["content"]["parts"]
            return "".join(part.get("text", "") for part in parts)
        except (KeyError, IndexError, TypeError) as exc:
            raise ProviderOutputError(f"malformed generateContent: {exc}") from exc

    async def complete(
        self,
        messages: list[Message],
        *,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        contents = [
            {"parts": [{"text": m.content}]} for m in messages if m.role != "system"
        ]
        system_prompt = "\n".join(m.content for m in messages if m.role == "system")
        payload: dict[str, Any] = {
            "contents": contents,
            "generationConfig": {
                "temperature": temperature
                if temperature is not None
                else (self._temperature if self._temperature is not None else 0.7),
                "maxOutputTokens": max_tokens or 1024,
            },
        }
        if system_prompt:
            payload["systemInstruction"] = {"parts": [{"text": system_prompt}]}
        return self._text(await self._generate(payload, model))

    async def complete_structured(
        self,
        prompt: str,
        json_schema: str | dict[str, Any] | None,
        *,
        system_prompt: str | None = None,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "temperature": temperature
                if temperature is not None
                else (self._temperature if self._temperature is not None else 0.2),
                "maxOutputTokens": max_tokens or 4096,
            },
        }
        if system_prompt:
            payload["systemInstruction"] = {"parts": [{"text": system_prompt}]}
        return extract_json(self._text(await self._generate(payload, model)))
