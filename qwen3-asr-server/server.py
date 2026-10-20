#!/usr/bin/env python3
"""Qwen3-ASR WebSocket server for Dal.

Same WebSocket protocol as the SenseVoice server so the Swift client
(SenseVoiceWSClient) can connect without changes.

Protocol:
  - Client sends binary PCM16-LE audio frames (16kHz mono)
  - Client sends empty frame to signal end-of-audio
  - Server sends JSON: {"type": "transcript", "text": "...", "is_final": bool}
  - Server sends JSON: {"type": "completed"} when done
"""

import argparse
import asyncio
import os
import socket
import struct
import sys
import time
from pathlib import Path

import numpy as np
import uvicorn
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

_SHARED_SECURITY_DIR = Path(__file__).resolve().parent.parent / "local-service-shared"
if str(_SHARED_SECURITY_DIR) not in sys.path:
    sys.path.insert(0, str(_SHARED_SECURITY_DIR))

from local_service_security import (
    AUTH_ENV_NAME,
    MAX_HTTP_AUDIO_BYTES,
    MAX_JSON_BYTES,
    MAX_WS_FRAME_BYTES,
    MissingAuthToken,
    RequestValidationError,
    WebSocketValidationError,
    decode_and_validate_llm_body,
    load_required_token,
    read_body_limited,
    validate_http_headers,
    validate_pcm_body,
    validate_websocket_audio_frame,
    validate_websocket_headers,
    strip_thinking_content,
)

import re
import threading


class CancelToken:
    """Cooperative cancellation for thread-pool tasks."""
    __slots__ = ("_cancelled", "_lock")

    def __init__(self):
        self._cancelled = False
        self._lock = threading.Lock()

    def cancel(self):
        with self._lock:
            self._cancelled = True

    @property
    def is_cancelled(self) -> bool:
        with self._lock:
            return self._cancelled

app = FastAPI()

_auth_token = os.environ.get(AUTH_ENV_NAME, "")


def configure_auth_token(environment=None):
    """读取本进程会话 token；校验失败时保留原有有效值。"""
    token = load_required_token(os.environ if environment is None else environment)
    global _auth_token
    _auth_token = token
    return token


@app.middleware("http")
async def _reject_non_local(request: Request, call_next):
    # Host/Origin 与会话 token 统一校验，错误信息不得包含 token。
    try:
        validate_http_headers(request.headers, _auth_token)
    except RequestValidationError as error:
        return JSONResponse({"error": str(error)}, status_code=error.status_code)
    return await call_next(request)


_session = None
_model_path = None
_hotword_context = ""  # Hotwords as context string for transcribe()
_inference_lock = threading.Lock()  # Prevent concurrent Metal GPU access (thread-level)

SAMPLE_RATE = 16000
PARTIAL_INTERVAL_SEC = 1.5  # Run partial transcribe every N seconds of new audio
MAX_PARTIAL_AUDIO_SEC = 45  # Only use last N seconds for partial (full audio for final)
# REPAIR_PLAN J10：final 缓冲封顶（对齐 Swift 侧 B8/J10 的 30 分钟）。qwen3 无独立
# 流式兜底，超限后停止累积、保留前 30 分钟供 final，避免超长会话内存无界增长。
MAX_TOTAL_AUDIO_SEC = 30 * 60


def get_session():
    """Lazy-load the Qwen3-ASR Session (holds the model)."""
    global _session
    if _model_path is None:
        raise RuntimeError("ASR model is not configured")
    if _session is None:
        from mlx_qwen3_asr import Session
        _session = Session(_model_path)
    return _session


_session_busy = False


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    # HTTP middleware 不覆盖 WS，鉴权及 Host/Origin 必须在 accept 前完成。
    try:
        validate_websocket_headers(ws.headers, _auth_token)
    except WebSocketValidationError as error:
        await ws.close(code=error.close_code, reason=str(error))
        return
    global _session_busy
    if _session_busy:
        await ws.close(code=4001, reason="another session is active")
        return
    _session_busy = True
    try:
        await ws.accept()
    except Exception:
        _session_busy = False
        raise

    try:
        sess = get_session()
    except Exception as e:
        # 初始化失败必须释放占用位，否则后续连接全被误拒
        _session_busy = False
        print(f"[qwen3-asr] session init error: {e}", flush=True)
        await ws.close(code=1011, reason="model not ready")
        return
    all_samples: list[int] = []
    partial_threshold = int(PARTIAL_INTERVAL_SEC * SAMPLE_RATE)
    max_partial_samples = MAX_PARTIAL_AUDIO_SEC * SAMPLE_RATE
    max_total_samples = MAX_TOTAL_AUDIO_SEC * SAMPLE_RATE
    total_overflow_logged = False
    last_partial_at = 0  # sample count at last partial
    inflight_partial = None  # track running partial task
    cancel_token = CancelToken()  # shared cancellation for in-flight partials

    try:
        while True:
            data = await ws.receive_bytes()

            if len(data) == 0:
                # ── End of audio: final transcribe with punctuation ──
                cancel_token.cancel()  # signal any in-flight partial to bail out
                if inflight_partial and not inflight_partial.done():
                    inflight_partial.cancel()

                if all_samples:
                    text = await _transcribe(sess, all_samples, strip_punct=False)
                    if text:
                        await ws.send_json({
                            "type": "transcript",
                            "text": text,
                            "is_final": True,
                        })
                await ws.send_json({"type": "completed"})
                break

            try:
                validate_websocket_audio_frame(
                    len(data), cumulative_bytes=len(all_samples) * 2
                )
            except WebSocketValidationError as error:
                await ws.close(code=error.close_code, reason=str(error))
                return

            # Accumulate PCM16 samples
            sample_count = len(data) // 2
            samples = list(struct.unpack(f"<{sample_count}h", data))
            # 只追加上限以内的样本，单个大帧也不能突破 30 分钟边界。
            remaining = max_total_samples - len(all_samples)
            if remaining > 0:
                all_samples.extend(samples[:remaining])
            if len(samples) > remaining:
                if not total_overflow_logged:
                    print("[qwen3-asr] audio buffer over limit; keeping first "
                          f"{MAX_TOTAL_AUDIO_SEC // 60} min for final", flush=True)
                total_overflow_logged = True

            # Periodic partial: transcribe without punctuation
            new_audio = len(all_samples) - last_partial_at
            if new_audio >= partial_threshold:
                if inflight_partial is None or inflight_partial.done():
                    last_partial_at = len(all_samples)
                    # Cap partial audio to last N seconds to avoid O(total) re-processing
                    if len(all_samples) > max_partial_samples:
                        samples_snapshot = list(all_samples[-max_partial_samples:])
                    else:
                        samples_snapshot = list(all_samples)
                    inflight_partial = asyncio.ensure_future(
                        _send_partial(ws, sess, samples_snapshot, cancel_token)
                    )

    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"[qwen3-asr] session error: {e}", flush=True)
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        _session_busy = False


async def _send_partial(ws: WebSocket, sess, samples: list[int],
                        cancel_token: CancelToken | None = None):
    """Run transcribe on accumulated audio (no punctuation) and send as partial."""
    try:
        text = await _transcribe(sess, samples, strip_punct=True,
                                 cancel_token=cancel_token)
        if text:
            await ws.send_json({
                "type": "transcript",
                "text": text,
                "is_final": False,
            })
    except Exception as e:
        # REPAIR_PLAN J8：不再静默吞掉——持续报错（如 Metal OOM）时用户只见
        # 「无中间结果」，服务端必须留痕可排障。取消走 CancelToken 协作标志
        # 不经异常；客户端停录瞬间的发送失败会落到这里，属正常竞态，偶发单条无害。
        print(f"[qwen3-asr] partial failed: {type(e).__name__}: {e}", flush=True)


# Punctuation characters to strip from partial results
_PUNCT_RE = re.compile('[，。！？、；：""''…,.!?;:]')


async def _transcribe(sess, samples_i16: list[int], strip_punct: bool = False,
                      cancel_token: CancelToken | None = None) -> str:
    """Run offline transcribe on audio samples."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(
        None, _transcribe_sync, sess, samples_i16, strip_punct, cancel_token
    )


def _transcribe_sync(sess, samples_i16: list[int], strip_punct: bool = False,
                      cancel_token: CancelToken | None = None) -> str:
    """Synchronous transcription. Thread-safe via lock.

    Passes np.ndarray directly to Session.transcribe() (AudioInput supports
    np.ndarray natively), avoiding temp-file disk I/O entirely.
    """
    if cancel_token and cancel_token.is_cancelled:
        return ""
    with _inference_lock:
        if cancel_token and cancel_token.is_cancelled:
            return ""
        audio = np.array(samples_i16, dtype=np.float32) / 32768.0
        result = sess.transcribe(audio, context=_hotword_context)
        text = result.text.strip() if result and result.text else ""
        if strip_punct and text:
            text = _PUNCT_RE.sub("", text)
        return text


@app.post("/transcribe")
async def transcribe_http(request: Request):
    """HTTP endpoint for speculative transcription. Accepts raw PCM16-LE audio."""
    if _model_path is None:
        return JSONResponse({"error": "ASR model is not configured"}, status_code=503)
    try:
        body = await read_body_limited(request, maximum_bytes=MAX_HTTP_AUDIO_BYTES)
        validation = validate_pcm_body(
            request.headers.get("content-type"), body
        )
    except RequestValidationError as error:
        return JSONResponse({"error": str(error)}, status_code=error.status_code)

    if validation == "too_short":
        return {"text": "", "reason": "audio_too_short"}

    sample_count = len(body) // 2
    samples = list(struct.unpack(f"<{sample_count}h", body))

    text = await _transcribe(get_session(), samples, strip_punct=False)
    return {"text": text}


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _model_path is not None, "llm_loaded": _llm is not None}


# --- LLM (Qwen3 via llama.cpp, optional) ---

_llm = None
_llm_lock = asyncio.Lock()
_llm_model_path = ""
_llm_disabled = False  # When True, refuse to load LLM (user clicked stop)


@app.post("/llm/unload")
async def llm_unload():
    """Unload the LLM model and prevent re-loading until /llm/load is called."""
    global _llm, _llm_disabled
    async with _llm_lock:
        _llm_disabled = True
        if _llm is not None:
            del _llm
            _llm = None
            import gc; gc.collect()
            print("LLM unloaded and disabled.", flush=True)
            return {"status": "unloaded"}
        return {"status": "disabled"}


@app.post("/llm/load")
async def llm_load():
    """Re-enable LLM loading (after user clicks start)."""
    global _llm_disabled
    _llm_disabled = False
    print("LLM re-enabled.", flush=True)
    return {"status": "enabled"}


def _load_llm(model_path: str):
    global _llm
    if _llm is not None:
        return _llm
    if _llm_disabled:
        return None
    from llama_cpp import Llama
    print(f"Loading LLM from {model_path}...", flush=True)
    _llm = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=-1,
        verbose=False,
    )
    print("LLM loaded.", flush=True)
    return _llm


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    try:
        body = await read_body_limited(request, maximum_bytes=MAX_JSON_BYTES)
        payload = decode_and_validate_llm_body(body)
    except RequestValidationError as error:
        return JSONResponse({"error": str(error)}, status_code=error.status_code)

    if _llm_disabled:
        return {"error": "LLM disabled", "choices": [{"message": {"content": ""}}]}
    if _llm is None and not _llm_model_path:
        return JSONResponse({"error": "LLM not configured"}, status_code=503)

    messages = payload["messages"]
    temperature = payload.get("temperature", 0.7)
    max_tokens = payload.get("max_tokens", 1024)
    thinking_enabled = payload.get("think", False)

    async with _llm_lock:
        llm = await asyncio.get_event_loop().run_in_executor(
            None, _load_llm, _llm_model_path
        )
    if llm is None:
        return {"error": "LLM disabled", "choices": [{"message": {"content": ""}}]}

    if messages and messages[-1].get("role") == "user":
        content = messages[-1]["content"]
        for existing_directive in ("/think", "/no_think"):
            if content == existing_directive:
                content = ""
            elif content.startswith(f"{existing_directive}\n"):
                content = content[len(existing_directive) + 1:]
        directive = "/think" if thinking_enabled else "/no_think"
        messages = messages.copy()
        messages[-1] = {**messages[-1], "content": f"{directive}\n{content}"}

    def _generate():
        import re
        # Share _inference_lock with ASR to prevent concurrent Metal GPU access
        with _inference_lock:
            result = llm.create_chat_completion(
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
            )
        if result.get("choices"):
            text = result["choices"][0]["message"]["content"]
            text = strip_thinking_content(text)
            result["choices"][0]["message"]["content"] = text
        result["muse_thinking_mode"] = "enabled" if thinking_enabled else "disabled"
        return result

    result = await asyncio.get_event_loop().run_in_executor(None, _generate)
    return result


# --- Main ---

def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    global _model_path, _llm_model_path, _hotword_context

    try:
        configure_auth_token()
    except MissingAuthToken as error:
        raise SystemExit(str(error)) from None

    # Prevent HF hub from trying to download/update models
    os.environ.setdefault("HF_HUB_OFFLINE", "1")

    parser = argparse.ArgumentParser(description="Qwen3-ASR Server")
    # --model-path 可选：缺省时进入 LLM-only 模式（仅 /v1/chat/completions 可用），
    # 让本地 LLM（Qwen3.5-9B）不必依赖 Qwen3-ASR 模型即可独立运行。
    parser.add_argument("--model-path", default="", help="Path to Qwen3-ASR model directory (omit for LLM-only mode)")
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    parser.add_argument("--hotwords-file", default="", help="Path to hotwords file (one per line)")
    parser.add_argument("--llm-model", default="", help="Path to GGUF LLM model for local chat completions")
    args = parser.parse_args()

    _model_path = args.model_path if (args.model_path and Path(args.model_path).exists()) else None

    # ASR 与 LLM 至少要有一个，否则没有可服务的能力
    if _model_path is None and not (args.llm_model and Path(args.llm_model).exists()):
        sys.exit("Neither ASR model nor LLM model available — nothing to serve")

    # Load hotwords as context string for Qwen3-ASR
    if args.hotwords_file and Path(args.hotwords_file).exists():
        words = [w.strip() for w in Path(args.hotwords_file).read_text().splitlines() if w.strip()]
        if words:
            _hotword_context = "Vocabulary: " + ", ".join(words)
            print(f"Loaded {len(words)} hotwords as context", flush=True)

    # 仅当存在 ASR 模型时预热；否则进入 LLM-only 模式（跳过 ASR 加载）
    if _model_path:
        print(f"Loading Qwen3-ASR model from {_model_path}...", flush=True)
        t0 = time.monotonic()
        sess = get_session()
        # Trigger model load with dummy transcription (np.ndarray, no temp file)
        dummy = np.zeros(SAMPLE_RATE, dtype=np.float32)
        sess.transcribe(dummy)
        elapsed = time.monotonic() - t0
        print(f"Model loaded in {elapsed:.1f}s", flush=True)
    else:
        print("No ASR model provided — running in LLM-only mode", flush=True)

    # Configure LLM (lazy-loaded on first request)
    if args.llm_model and Path(args.llm_model).exists():
        _llm_model_path = args.llm_model
        print(f"LLM configured: {args.llm_model} (lazy load on first request)", flush=True)

    port = args.port if args.port != 0 else find_free_port()
    print(f"PORT:{port}", flush=True)

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=port,
        log_level="warning",
        ws_max_size=MAX_WS_FRAME_BYTES,
    )


if __name__ == "__main__":
    main()
