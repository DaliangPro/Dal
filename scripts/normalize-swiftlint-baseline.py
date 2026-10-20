#!/usr/bin/env python3
"""将 SwiftLint 导出的本机绝对路径转为可移植的仓库路径，拒绝仓库外条目。"""
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse

root = Path(__file__).resolve().parent.parent
path = Path(sys.argv[1])
entries = json.loads(path.read_text(encoding="utf-8"))
for entry in entries:
    location = entry["violation"]["location"]
    source = location["file"]
    resolved = Path(unquote(urlparse(source).path)) if source.startswith("file:") else Path(source)
    if resolved.is_absolute():
        resolved = resolved.relative_to(root)
    if not resolved.parts or resolved.parts[0] not in ("Muse", "MuseTests") or ".." in resolved.parts:
        raise ValueError("baseline 只允许仓库 Muse/MuseTests 下的文件")
    location["file"] = resolved.as_posix()
path.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
