"""Dal 本地推理服务共用的鉴权与输入边界。"""

from __future__ import annotations

from dataclasses import dataclass
import hmac
import json
import math
import os
import re
from typing import Any, Mapping


AUTH_ENV_NAME = "MUSE_LOCAL_AUTH_TOKEN"
AUTH_HEADER_NAME = "X-Muse-Local-Token"

MAX_WS_FRAME_BYTES = 1 * 1024 * 1024
MAX_HTTP_AUDIO_BYTES = 60 * 1024 * 1024
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_AUDIO_BYTES = 30 * 60 * 16_000 * 2
MIN_PCM_BYTES = 100
MAX_LLM_CONTENT_CHARS = 200_000

_THINK_BLOCK_RE = re.compile(r"<think\b[^>]*>.*?</think\s*>\s*", re.IGNORECASE | re.DOTALL)
_OPEN_THINK_RE = re.compile(r"<think\b[^>]*>", re.IGNORECASE)


class MissingAuthToken(RuntimeError):
    """本地服务未收到父进程提供的会话 token。"""


class RequestValidationError(ValueError):
    """可安全返回给 HTTP 调用方的校验错误。"""

    def __init__(self, status_code: int, message: str):
        super().__init__(message)
        self.status_code = status_code


class WebSocketValidationError(ValueError):
    """可安全返回给 WebSocket 调用方的校验错误。"""

    def __init__(self, close_code: int, message: str):
        super().__init__(message)
        self.close_code = close_code


def strip_thinking_content(text: str) -> str:
    """移除模型思考标签；未闭合标签后的内容全部视为不可交付正文。"""

    if not isinstance(text, str) or not text:
        return ""
    cleaned = _THINK_BLOCK_RE.sub("", text)
    unclosed = _OPEN_THINK_RE.search(cleaned)
    if unclosed:
        cleaned = cleaned[:unclosed.start()]
    return cleaned.strip()


@dataclass(frozen=True)
class WebSocketAudioDecision:
    accepted_bytes: int
    cumulative_bytes: int
    overflowed: bool


def load_required_token(environment: Mapping[str, str] | None = None) -> str:
    """读取当前进程 token；缺失时拒绝启动服务。"""

    source = os.environ if environment is None else environment
    token = source.get(AUTH_ENV_NAME)
    if not isinstance(token, str) or not token.strip():
        raise MissingAuthToken(f"缺少必需环境变量 {AUTH_ENV_NAME}")
    return token


def is_authorized(provided: str | None, expected: str) -> bool:
    """以恒定时间比较 token，同时安全处理非 ASCII 输入。"""

    if not provided or not expected:
        return False
    try:
        provided_bytes = provided.encode("utf-8")
        expected_bytes = expected.encode("utf-8")
    except (AttributeError, UnicodeEncodeError):
        return False
    return hmac.compare_digest(provided_bytes, expected_bytes)


def _header(headers: Mapping[str, Any], name: str) -> str | None:
    value = headers.get(name)
    if value is None:
        value = headers.get(name.lower())
    if value is None:
        for key, candidate in headers.items():
            if str(key).lower() == name.lower():
                value = candidate
                break
    return value if isinstance(value, str) else None


def _validate_loopback_headers(headers: Mapping[str, Any], *, websocket: bool) -> None:
    error_type = WebSocketValidationError if websocket else RequestValidationError
    error_code = 4003 if websocket else 403

    if _header(headers, "origin") is not None:
        raise error_type(error_code, "拒绝跨源请求")

    raw_host = (_header(headers, "host") or "").strip().lower()
    valid_host = (
        raw_host in {"127.0.0.1", "localhost"}
        or raw_host.startswith("127.0.0.1:")
        or raw_host.startswith("localhost:")
    )
    if not valid_host:
        raise error_type(error_code, "Host 必须是本机回环地址")


def validate_http_headers(headers: Mapping[str, Any], expected_token: str) -> None:
    if not is_authorized(_header(headers, AUTH_HEADER_NAME), expected_token):
        raise RequestValidationError(401, "未授权的本地服务请求")
    _validate_loopback_headers(headers, websocket=False)


def validate_websocket_headers(headers: Mapping[str, Any], expected_token: str) -> None:
    if not is_authorized(_header(headers, AUTH_HEADER_NAME), expected_token):
        raise WebSocketValidationError(4003, "未授权的 WebSocket 请求")
    _validate_loopback_headers(headers, websocket=True)


def validate_pcm_body(
    content_type: str | None,
    body: bytes,
    *,
    body_length: int | None = None,
) -> str:
    """校验 16-bit PCM 请求，返回 ready 或 too_short。"""

    media_type = (content_type or "").split(";", 1)[0].strip().lower()
    if media_type != "application/octet-stream":
        raise RequestValidationError(415, "Content-Type 必须是 application/octet-stream")

    measured_length = len(body)
    declared_length = measured_length if body_length is None else body_length
    if declared_length < 0:
        raise RequestValidationError(400, "无效的请求长度")
    effective_length = max(measured_length, declared_length)
    if effective_length > MAX_HTTP_AUDIO_BYTES:
        raise RequestValidationError(413, "音频请求超过 60 MB 上限")
    if measured_length % 2 != 0 or declared_length % 2 != 0:
        raise RequestValidationError(400, "PCM 音频字节数必须为偶数")
    if measured_length < MIN_PCM_BYTES:
        return "too_short"
    return "ready"


def decode_and_validate_llm_body(
    body: bytes,
    *,
    body_length: int | None = None,
) -> dict[str, Any]:
    """在解析 JSON 前执行硬上限，再统一校验 LLM 参数。"""

    measured_length = len(body)
    declared_length = measured_length if body_length is None else body_length
    if declared_length < 0:
        raise RequestValidationError(400, "无效的请求长度")
    if max(measured_length, declared_length) > MAX_JSON_BYTES:
        raise RequestValidationError(413, "JSON 请求超过 2 MB 上限")

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise RequestValidationError(400, "请求必须是有效 JSON") from None
    if not isinstance(payload, dict):
        raise RequestValidationError(400, "JSON 根节点必须是对象")

    messages = payload.get("messages")
    if not isinstance(messages, list) or not messages:
        raise RequestValidationError(400, "messages 必须是非空数组")

    total_content_chars = 0
    for message in messages:
        if not isinstance(message, dict):
            raise RequestValidationError(400, "每条 message 必须是对象")
        role = message.get("role")
        content = message.get("content")
        if not isinstance(role, str) or not isinstance(content, str):
            raise RequestValidationError(400, "message 的 role 和 content 必须是字符串")
        total_content_chars += len(content)
        if total_content_chars > MAX_LLM_CONTENT_CHARS:
            raise RequestValidationError(400, "messages content 总长度超过 200000 字符")

    if "temperature" in payload:
        temperature = payload["temperature"]
        if (
            isinstance(temperature, bool)
            or not isinstance(temperature, (int, float))
            or not math.isfinite(temperature)
            or not 0 <= temperature <= 2
        ):
            raise RequestValidationError(400, "temperature 必须在 0 到 2 之间")

    if "max_tokens" in payload:
        max_tokens = payload["max_tokens"]
        if (
            isinstance(max_tokens, bool)
            or not isinstance(max_tokens, int)
            or not 1 <= max_tokens <= 8192
        ):
            raise RequestValidationError(400, "max_tokens 必须在 1 到 8192 之间")

    if "think" in payload and not isinstance(payload["think"], bool):
        raise RequestValidationError(400, "think 必须是布尔值")

    return payload


async def read_body_limited(request: Any, *, maximum_bytes: int) -> bytes:
    """流式读取请求体，避免框架在校验前无界缓冲。"""

    content_length = _header(request.headers, "content-length")
    if content_length is not None:
        try:
            declared_length = int(content_length)
        except ValueError:
            raise RequestValidationError(400, "无效的 Content-Length") from None
        if declared_length < 0:
            raise RequestValidationError(400, "无效的 Content-Length")
        if declared_length > maximum_bytes:
            raise RequestValidationError(413, "请求体超过大小上限")

    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > maximum_bytes:
            raise RequestValidationError(413, "请求体超过大小上限")
        chunks.append(chunk)
    return b"".join(chunks)


def validate_websocket_audio_frame(
    frame_length: int,
    *,
    cumulative_bytes: int,
) -> WebSocketAudioDecision:
    """校验单帧，并将超出 30 分钟的尾部安全截断。"""

    if frame_length < 0 or cumulative_bytes < 0:
        raise WebSocketValidationError(1003, "无效的音频帧长度")
    if frame_length % 2 != 0:
        raise WebSocketValidationError(1003, "PCM 音频帧字节数必须为偶数")
    if frame_length > MAX_WS_FRAME_BYTES:
        raise WebSocketValidationError(1009, "音频帧超过 1 MB 上限")

    bounded_cumulative = min(cumulative_bytes, MAX_AUDIO_BYTES)
    remaining = MAX_AUDIO_BYTES - bounded_cumulative
    accepted_bytes = min(frame_length, remaining)
    return WebSocketAudioDecision(
        accepted_bytes=accepted_bytes,
        cumulative_bytes=bounded_cumulative + accepted_bytes,
        overflowed=frame_length > accepted_bytes,
    )
