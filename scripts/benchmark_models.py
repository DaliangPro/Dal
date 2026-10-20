#!/usr/bin/env python3
"""Benchmark ARK models for Dal smart direct (typo correction) use case."""

import json
import os
import sys
import time
import urllib.request
import urllib.error
import ssl

API_KEY = os.environ.get("ARK_API_KEY")
if not API_KEY:
    sys.exit("Error: please set ARK_API_KEY environment variable")
BASE_URL = "https://ark.cn-beijing.volces.com/api/coding/v3"

MODELS = [
    "doubao-seed-2.0-lite",
    "doubao-seed-2.0-pro",
    "doubao-seed-2.0-code",
    "doubao-seed-code",
    "kimi-k2.5",
    "glm-4.7",
    "deepseek-v3.2",
    "minimax-m2.5",
]

PROMPT = """你是一个语音转写纠错助手。请修正以下语音识别文本中的错别字和标点符号。
规则:
1. 只修正明显的同音/近音错别字
2. 补充或修正标点符号，使句子通顺
3. 不要改变原文的意思、语气和用词风格
4. 不要添加、删除或重组任何内容
5. 直接返回修正后的文本，不要任何解释

{text}"""

TESTS = [
    {
        "label": "短句17字",
        "input": "我今天去了一个很漂亮的地放哪里的风景真的很好看",
        "expected": "我今天去了一个很漂亮的地方，那里的风景真的很好看。",
    },
    {
        "label": "中句40字",
        "input": "昨天我和朋友去了一个新开的参观吃饭感觉味道还不错就是价格有点贵我觉的下次可以在去试试",
        "expected": "昨天我和朋友去了一个新开的餐馆吃饭，感觉味道还不错，就是价格有点贵。我觉得下次可以再去试试。",
    },
    {
        "label": "长句80字",
        "input": "今天开会的时候领导说我们下个季度的木标是要把销售额提高百分之二十我觉的这个木标还是有点高的不过如果大家一起努力的话应该还是有可能完成的我们需要从几个方面来入手",
        "expected": "今天开会的时候，领导说我们下个季度的目标是要把销售额提高百分之二十。我觉得这个目标还是有点高的，不过如果大家一起努力的话，应该还是有可能完成的。我们需要从几个方面来入手。",
    },
]


def call_model(model: str, text: str) -> tuple[str, int, str]:
    """Returns (content, elapsed_ms, error)."""
    prompt = PROMPT.replace("{text}", text)
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "thinking": {"type": "disabled"},
    }).encode()

    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )

    ctx = ssl.create_default_context()
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=60, context=ctx) as resp:
            data = json.loads(resp.read())
            elapsed = int((time.monotonic() - start) * 1000)
            content = data["choices"][0]["message"]["content"]
            return content, elapsed, ""
    except urllib.error.HTTPError as e:
        elapsed = int((time.monotonic() - start) * 1000)
        try:
            err_body = json.loads(e.read())
            msg = err_body.get("error", {}).get("message", str(e))
        except Exception:
            msg = str(e)
        return "", elapsed, f"HTTP {e.code}: {msg}"
    except Exception as e:
        elapsed = int((time.monotonic() - start) * 1000)
        return "", elapsed, str(e)


def main():
    print("=" * 70)
    print("  Dal Smart Direct Mode - Model Benchmark")
    print(f"  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Base URL: {BASE_URL}")
    print("=" * 70)

    results = []

    for model in MODELS:
        print(f"\n{'━' * 50}")
        print(f"  {model}")
        print(f"{'━' * 50}")

        times = []
        for test in TESTS:
            content, ms, err = call_model(model, test["input"])
            if err:
                print(f"  [{test['label']}] {ms}ms => FAILED: {err}")
            else:
                times.append(ms)
                print(f"  [{test['label']}] {ms}ms")
                print(f"    Output:   {content}")
                print(f"    Expected: {test['expected']}")

        if times:
            avg = sum(times) // len(times)
            print(f"  ── avg: {avg}ms ({len(times)}/3 passed)")
            results.append((model, avg, len(times)))
        else:
            print("  ── ALL FAILED")
            results.append((model, -1, 0))

    print(f"\n\n{'=' * 70}")
    print("  SUMMARY (sorted by speed)")
    print(f"{'=' * 70}")
    print(f"  {'Model':<25} {'Avg Time':>10}  {'Tests':>6}")
    print(f"  {'-' * 45}")

    for model, avg, passed in sorted(results, key=lambda x: (x[1] < 0, x[1])):
        time_str = f"{avg}ms" if avg >= 0 else "FAILED"
        print(f"  {model:<25} {time_str:>10}  {passed}/3")

    print(f"{'=' * 70}")


if __name__ == "__main__":
    main()
