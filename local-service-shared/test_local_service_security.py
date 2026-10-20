import asyncio
import json
import unittest

from local_service_security import (
    AUTH_ENV_NAME,
    MAX_AUDIO_BYTES,
    MAX_HTTP_AUDIO_BYTES,
    MAX_JSON_BYTES,
    MAX_WS_FRAME_BYTES,
    MissingAuthToken,
    RequestValidationError,
    WebSocketValidationError,
    decode_and_validate_llm_body,
    is_authorized,
    load_required_token,
    read_body_limited,
    validate_http_headers,
    validate_pcm_body,
    validate_websocket_headers,
    validate_websocket_audio_frame,
    strip_thinking_content,
)


class _ChunkedRequest:
    def __init__(self, chunks, content_length=None):
        self._chunks = chunks
        self.headers = {}
        if content_length is not None:
            self.headers["content-length"] = str(content_length)

    async def stream(self):
        for chunk in self._chunks:
            yield chunk


class LocalServiceSecurityTests(unittest.TestCase):
    def test_startup_requires_non_empty_token(self):
        with self.assertRaises(MissingAuthToken):
            load_required_token({})
        with self.assertRaises(MissingAuthToken):
            load_required_token({AUTH_ENV_NAME: "  "})
        self.assertEqual(load_required_token({AUTH_ENV_NAME: "secret"}), "secret")

    def test_thinking_cleanup_drops_closed_blocks_and_truncates_unclosed_blocks(self):
        self.assertEqual(
            strip_thinking_content("<think>内部推理</think>\n最终正文"),
            "最终正文",
        )
        self.assertEqual(
            strip_thinking_content("前缀<think>内部推理尚未结束"),
            "前缀",
        )
        self.assertEqual(strip_thinking_content("<think>\n"), "")

    def test_authorization_rejects_missing_and_wrong_tokens(self):
        self.assertFalse(is_authorized(None, "expected"))
        self.assertFalse(is_authorized("", ""))
        self.assertFalse(is_authorized("wrong", "expected"))
        self.assertFalse(is_authorized("错误", "expected"))
        self.assertTrue(is_authorized("expected", "expected"))

        valid_base = {"host": "127.0.0.1:8765"}
        for provided in (None, "wrong"):
            headers = dict(valid_base)
            if provided is not None:
                headers["x-dal-local-token"] = provided
            with self.subTest(provided=provided):
                with self.assertRaises(RequestValidationError) as http_error:
                    validate_http_headers(headers, "expected")
                self.assertEqual(http_error.exception.status_code, 401)
                with self.assertRaises(WebSocketValidationError) as ws_error:
                    validate_websocket_headers(headers, "expected")
                self.assertEqual(ws_error.exception.close_code, 4003)

        authorized = {
            "host": "localhost:8765",
            "x-dal-local-token": "expected",
        }
        validate_http_headers(authorized, "expected")
        validate_websocket_headers(authorized, "expected")

    def test_origin_and_non_loopback_host_remain_rejected(self):
        with self.assertRaises(RequestValidationError) as origin_error:
            validate_http_headers(
                {
                    "host": "127.0.0.1:8765",
                    "origin": "https://example.com",
                    "x-dal-local-token": "expected",
                },
                "expected",
            )
        self.assertEqual(origin_error.exception.status_code, 403)

        with self.assertRaises(WebSocketValidationError) as host_error:
            validate_websocket_headers(
                {
                    "host": "example.com:8765",
                    "x-dal-local-token": "expected",
                },
                "expected",
            )
        self.assertEqual(host_error.exception.close_code, 4003)

    def test_pcm_requires_octet_stream_even_length_and_sixty_megabyte_limit(self):
        with self.assertRaises(RequestValidationError) as content_type_error:
            validate_pcm_body("application/json", b"\x00\x00")
        self.assertEqual(content_type_error.exception.status_code, 415)

        with self.assertRaises(RequestValidationError) as odd_error:
            validate_pcm_body("application/octet-stream", b"\x00")
        self.assertEqual(odd_error.exception.status_code, 400)

        with self.assertRaises(RequestValidationError) as large_error:
            validate_pcm_body(
                "application/octet-stream",
                b"\x00\x00",
                body_length=MAX_HTTP_AUDIO_BYTES + 2,
            )
        self.assertEqual(large_error.exception.status_code, 413)
        self.assertEqual(validate_pcm_body("application/octet-stream", b""), "too_short")
        self.assertEqual(
            validate_pcm_body("application/octet-stream", b"\x00\x00" * 50),
            "ready",
        )

    def test_llm_body_limits_and_parameter_validation(self):
        valid = {
            "messages": [{"role": "user", "content": "hello"}],
            "temperature": 0.7,
            "max_tokens": 128,
            "think": True,
        }
        self.assertEqual(
            decode_and_validate_llm_body(json.dumps(valid).encode("utf-8")),
            valid,
        )

        invalid_payloads = [
            {},
            {"messages": []},
            {"messages": [{"role": 1, "content": "hello"}]},
            {"messages": [{"role": "user", "content": 1}]},
            {"messages": [{"role": "user", "content": "x" * 200_001}]},
            {"messages": [{"role": "user", "content": "x"}], "temperature": True},
            {"messages": [{"role": "user", "content": "x"}], "temperature": 2.1},
            {"messages": [{"role": "user", "content": "x"}], "max_tokens": True},
            {"messages": [{"role": "user", "content": "x"}], "max_tokens": 0},
            {"messages": [{"role": "user", "content": "x"}], "max_tokens": 8193},
            {"messages": [{"role": "user", "content": "x"}], "think": 1},
            {"messages": [{"role": "user", "content": "x"}], "think": "true"},
        ]
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(RequestValidationError) as error:
                    decode_and_validate_llm_body(json.dumps(payload).encode("utf-8"))
                self.assertEqual(error.exception.status_code, 400)

        with self.assertRaises(RequestValidationError) as malformed_error:
            decode_and_validate_llm_body(b"not-json")
        self.assertEqual(malformed_error.exception.status_code, 400)

        with self.assertRaises(RequestValidationError) as size_error:
            decode_and_validate_llm_body(b"{}", body_length=MAX_JSON_BYTES + 1)
        self.assertEqual(size_error.exception.status_code, 413)

        for boundary_payload in [
            {"messages": [{"role": "user", "content": "x" * 200_000}]},
            {"messages": [{"role": "user", "content": "x"}], "temperature": 0},
            {"messages": [{"role": "user", "content": "x"}], "temperature": 2},
            {"messages": [{"role": "user", "content": "x"}], "max_tokens": 1},
            {"messages": [{"role": "user", "content": "x"}], "max_tokens": 8192},
        ]:
            with self.subTest(boundary_payload=boundary_payload):
                encoded = json.dumps(boundary_payload).encode("utf-8")
                self.assertEqual(decode_and_validate_llm_body(encoded), boundary_payload)

        for non_object in ([], "text", 1, None):
            with self.subTest(non_object=non_object):
                with self.assertRaises(RequestValidationError) as object_error:
                    decode_and_validate_llm_body(json.dumps(non_object).encode("utf-8"))
                self.assertEqual(object_error.exception.status_code, 400)

    def test_streaming_body_reader_stops_at_hard_limit(self):
        body = asyncio.run(
            read_body_limited(_ChunkedRequest([b"12", b"34"]), maximum_bytes=4)
        )
        self.assertEqual(body, b"1234")

        with self.assertRaises(RequestValidationError) as chunked_error:
            asyncio.run(
                read_body_limited(_ChunkedRequest([b"123", b"45"]), maximum_bytes=4)
            )
        self.assertEqual(chunked_error.exception.status_code, 413)

        with self.assertRaises(RequestValidationError) as declared_error:
            asyncio.run(
                read_body_limited(
                    _ChunkedRequest([], content_length=5),
                    maximum_bytes=4,
                )
            )
        self.assertEqual(declared_error.exception.status_code, 413)

    def test_websocket_frame_and_session_audio_limits(self):
        decision = validate_websocket_audio_frame(2, cumulative_bytes=0)
        self.assertEqual(decision.accepted_bytes, 2)
        self.assertEqual(decision.cumulative_bytes, 2)
        self.assertFalse(decision.overflowed)

        with self.assertRaises(WebSocketValidationError) as odd_error:
            validate_websocket_audio_frame(1, cumulative_bytes=0)
        self.assertEqual(odd_error.exception.close_code, 1003)

        with self.assertRaises(WebSocketValidationError) as frame_error:
            validate_websocket_audio_frame(MAX_WS_FRAME_BYTES + 2, cumulative_bytes=0)
        self.assertEqual(frame_error.exception.close_code, 1009)

        overflow = validate_websocket_audio_frame(
            4,
            cumulative_bytes=MAX_AUDIO_BYTES - 2,
        )
        self.assertEqual(overflow.accepted_bytes, 2)
        self.assertEqual(overflow.cumulative_bytes, MAX_AUDIO_BYTES)
        self.assertTrue(overflow.overflowed)


if __name__ == "__main__":
    unittest.main()
