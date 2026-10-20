#!/usr/bin/env python3
"""SenseVoice streaming ASR WebSocket server for Dal."""

import argparse
import asyncio
import os
import struct
import sys
import socket
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

_SHARED_SECURITY_DIR = Path(__file__).resolve().parent.parent / "local-service-shared"
if str(_SHARED_SECURITY_DIR) not in sys.path:
    sys.path.insert(0, str(_SHARED_SECURITY_DIR))

from local_service_security import (
    AUTH_ENV_NAME,
    MAX_AUDIO_BYTES,
    MAX_JSON_BYTES,
    MAX_WS_FRAME_BYTES,
    MissingAuthToken,
    RequestValidationError,
    WebSocketValidationError,
    decode_and_validate_llm_body,
    load_required_token,
    read_body_limited,
    validate_http_headers,
    validate_websocket_audio_frame,
    validate_websocket_headers,
    strip_thinking_content,
)
from sensevoice_model import load_model, StreamingSenseVoice

app = FastAPI()

_auth_token = os.environ.get(AUTH_ENV_NAME, "")
_SENSEVOICE_MODEL_FILES = frozenset({
    "model.pt",
    "config.yaml",
    "am.mvn",
    "chn_jpn_yue_eng_ko_spectok.bpe.model",
    "configuration.json",
})


def _validated_local_model_dir(raw_path: str) -> Path:
    """只接受固定清单的绝对本地模型目录，不触发任何在线解析。"""

    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        raise ValueError("model directory must be an absolute path")
    if path.is_symlink():
        raise ValueError("model directory must not be a symbolic link")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValueError("model directory is unavailable") from error
    if not resolved.is_dir() or resolved.is_symlink():
        raise ValueError("model directory must be a real directory")

    files = set()
    for entry in resolved.rglob("*"):
        if entry.is_symlink():
            raise ValueError("model directory contains a symbolic link")
        if entry.is_dir():
            continue
        if not entry.is_file():
            raise ValueError("model directory contains an unsupported file")
        relative = entry.relative_to(resolved).as_posix()
        files.add(relative)
    if files != _SENSEVOICE_MODEL_FILES:
        raise ValueError("model directory does not match the pinned manifest")
    return resolved


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


# Global model (loaded once at startup)
_model: StreamingSenseVoice | None = None

# REPAIR_PLAN B3: 全局单模型不支持并发会话——同一时刻只服务一个 WebSocket，
# 否则新连接的 model.reset() 会清掉进行中会话的流式状态
_session_busy = False


def get_model():
    assert _model is not None, "Model not loaded"
    return _model


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
        model = get_model()
        # Reset model state for new session
        model.reset()
    except Exception as e:
        # 初始化失败必须释放占用位，否则后续连接全被误拒
        _session_busy = False
        print(f"[sensevoice] session init error: {e}", flush=True)
        await ws.close(code=1011, reason="model not ready")
        return

    # Accumulate all audio for final full inference
    all_samples: list[int] = []
    # REPAIR_PLAN J10：final 缓冲 30 分钟封顶（对齐 Swift 侧 B8/J10）。超限即清空并
    # 停止累积——流式结果已实时下发，final 走下方流式兜尾分支，不做半截全量推理
    # （半截 final 会覆盖完整的流式文本，比不做更糟）。
    total_overflowed = False

    try:
        while True:
            data = await ws.receive_bytes()

            if len(data) == 0:
                # Empty frame = end of audio signal
                # Full inference on complete audio for best accuracy
                if all_samples:
                    final_text = model.full_inference(all_samples)
                    if final_text:
                        await ws.send_json({
                            "type": "transcript",
                            "text": final_text,
                            "is_final": True,
                        })
                else:
                    for result in model.streaming_inference([], is_last=True):
                        await ws.send_json({
                            "type": "transcript",
                            "text": result.get("text", ""),
                            "is_final": True,
                        })
                await ws.send_json({"type": "completed"})
                break

            try:
                cumulative_bytes = (
                    MAX_AUDIO_BYTES if total_overflowed else len(all_samples) * 2
                )
                frame = validate_websocket_audio_frame(
                    len(data), cumulative_bytes=cumulative_bytes
                )
            except WebSocketValidationError as error:
                await ws.close(code=error.close_code, reason=str(error))
                return

            # Convert PCM16 little-endian bytes to int16-range float list
            sample_count = len(data) // 2
            samples = list(struct.unpack(f"<{sample_count}h", data))
            # 超限后停止 final 累积，但仍允许当前流式推理兜底。
            if not total_overflowed:
                if frame.overflowed:
                    total_overflowed = True
                    all_samples.clear()
                    print("[sensevoice] audio buffer over limit; "
                          "final full inference disabled for this session", flush=True)
                else:
                    all_samples.extend(samples[:frame.accepted_bytes // 2])

            # Run streaming inference (fast partial results)
            for result in model.streaming_inference(samples, is_last=False):
                text = result.get("text", "")
                if text:
                    await ws.send_json({
                        "type": "transcript",
                        "text": text,
                        "is_final": False,
                    })

    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"[sensevoice] session error: {e}", flush=True)
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        _session_busy = False


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _model is not None, "llm_loaded": _llm is not None}


# --- LLM (Qwen3 via llama.cpp) ---

_llm = None
_llm_lock = asyncio.Lock()


def _load_llm(model_path: str):
    """Load LLM model lazily on first request."""
    global _llm
    if _llm is not None:
        return _llm
    from llama_cpp import Llama
    print(f"Loading LLM from {model_path}...", flush=True)
    _llm = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=-1,  # Use Metal (all layers on GPU)
        verbose=False,
    )
    print("LLM loaded.", flush=True)
    return _llm


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """OpenAI-compatible chat completions endpoint."""
    try:
        body = await read_body_limited(request, maximum_bytes=MAX_JSON_BYTES)
        payload = decode_and_validate_llm_body(body)
    except RequestValidationError as error:
        return JSONResponse({"error": str(error)}, status_code=error.status_code)

    if _llm is None and not _llm_model_path:
        return JSONResponse({"error": "LLM not configured"}, status_code=503)

    messages = payload["messages"]
    temperature = payload.get("temperature", 0.7)
    max_tokens = payload.get("max_tokens", 1024)
    thinking_enabled = payload.get("think", False)

    # Lazy load LLM on first request
    async with _llm_lock:
        llm = await asyncio.get_event_loop().run_in_executor(
            None, _load_llm, _llm_model_path
        )

    # Qwen3 通过用户消息前缀切换思考模式；请求字段由 Dal 的模型配置开关传入。
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

    # Run inference in thread pool to not block event loop
    def _generate():
        result = llm.create_chat_completion(
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        # 思考块不属于可交付正文；未闭合时连同后续内容一起截断。
        if result.get("choices"):
            text = result["choices"][0]["message"]["content"]
            text = strip_thinking_content(text)
            result["choices"][0]["message"]["content"] = text
        # 仅回报实际采用的模式，不返回或记录思考内容；测试连接据此严格核对开关。
        result["muse_thinking_mode"] = "enabled" if thinking_enabled else "disabled"
        return result

    result = await asyncio.get_event_loop().run_in_executor(None, _generate)
    return result


_llm_model_path = ""


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    try:
        configure_auth_token()
    except MissingAuthToken as error:
        raise SystemExit(str(error)) from None

    # FunASR/ModelScope must never turn a missing local artifact into a network
    # download. The Swift side verifies hashes; these flags provide a second
    # process-level offline boundary.
    for variable in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "MODELSCOPE_OFFLINE"):
        os.environ[variable] = "1"

    parser = argparse.ArgumentParser(description="SenseVoice ASR Server")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    parser.add_argument("--hotwords-file", default="")
    parser.add_argument("--beam-size", type=int, default=3)
    parser.add_argument("--context-score", type=float, default=6.0)
    parser.add_argument("--device", default="auto", help="auto, cpu, or mps")
    parser.add_argument("--language", default="auto", help="auto, zh, en, ja, ko, yue")
    parser.add_argument("--textnorm", action="store_true", default=True, help="Enable ITN (punctuation + number formatting)")
    parser.add_argument("--no-textnorm", dest="textnorm", action="store_false")
    parser.add_argument("--padding", type=int, default=8, help="Encoder context padding frames (higher = more accurate, slower)")
    parser.add_argument("--chunk-size", type=int, default=10, help="Encoder chunk size in LFR frames (~60ms each)")
    parser.add_argument("--llm-model", default="", help="Path to GGUF LLM model for local chat completions")
    args = parser.parse_args()

    try:
        args.model_dir = str(_validated_local_model_dir(args.model_dir))
    except ValueError as error:
        raise SystemExit(f"拒绝加载本地 SenseVoice 模型：{error}") from None

    global _model

    # Load hotwords from file
    # Each line is a hotword phrase. Multi-word English phrases are split into
    # individual words to avoid BPE space-prefix issues (e.g. "▁coding" not in vocab).
    # Chinese phrases are kept as-is since each character is already a token.
    hotwords = None
    if args.hotwords_file and Path(args.hotwords_file).exists():
        raw_lines = Path(args.hotwords_file).read_text().strip().splitlines()
        hotwords = []
        for line in raw_lines:
            line = line.strip()
            if not line:
                continue
            # Split on spaces: "Vibe coding" → ["Vibe", "coding"]
            # Chinese "语音识别" has no spaces, stays as one entry
            words = line.split()
            hotwords.extend(words)
        # Deduplicate while preserving order
        seen = set()
        hotwords = [w for w in hotwords if w not in seen and not seen.add(w)]
        if hotwords:
            print(f"Loaded {len(hotwords)} hotwords", flush=True)

    # Load model
    print(f"Loading model from {args.model_dir}...", flush=True)
    _model = load_model(
        model_dir=args.model_dir,
        contexts=hotwords,
        beam_size=args.beam_size,
        context_score=args.context_score,
        device=args.device,
        language=args.language,
        textnorm=args.textnorm,
        padding=args.padding,
        chunk_size=args.chunk_size,
    )
    print("Model loaded.", flush=True)

    # Configure LLM (lazy-loaded on first request)
    global _llm_model_path
    if args.llm_model and Path(args.llm_model).exists():
        _llm_model_path = args.llm_model
        print(f"LLM configured: {args.llm_model} (lazy load on first request)", flush=True)

    # Find port
    port = args.port if args.port != 0 else find_free_port()

    # Print PORT line so Swift process can discover it
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
