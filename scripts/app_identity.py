#!/usr/bin/env python3
"""Dal 安装边界：只接受本项目明确身份，缺失信息时停止。"""

import argparse
from pathlib import Path
import plistlib
import subprocess

BUNDLE_ID = "pro.daliang.muse"
ALLOWED_IDS = {BUNDLE_ID, BUNDLE_ID + ".preview", BUNDLE_ID + ".interactive-test"}
# 沿用原有本机证书的公开指纹，改名不得新建证书或重置权限。
LOCAL_CERT_SHA1 = "1edbb315dd21c2d07b63ef37b57d26fdfbb44033"
INSTALL_REQUIREMENT = (
    f'identifier "{BUNDLE_ID}" and certificate leaf = H"{LOCAL_CERT_SHA1}"'
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(path):
    path = Path(path)
    # macOS 自带的 /var 与 /tmp 是固定系统别名；其余路径组件仍逐一拒绝链接。
    if str(path).startswith(("/var/", "/tmp/")):
        path = Path("/private" + str(path))
    require(path.is_absolute(), "应用路径必须为绝对路径")
    require(".." not in path.parts, "应用路径不能包含上级跳转")
    for part in (path, *path.parents):
        require(not part.is_symlink(), f"拒绝符号链接路径：{part}")
    require(path.suffix == ".app", "目标必须是明确的 .app 包")
    return path


def metadata(path):
    path = safe_path(path)
    info_path = path / "Contents/Info.plist"
    require(not (path / "Contents").is_symlink(), "Contents 不能是符号链接")
    require(info_path.is_file() and not info_path.is_symlink(), "应用身份缺失")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    require(isinstance(info, dict), "应用身份格式错误")
    return info


def verify_signature(path, requirement=None):
    command = ["/usr/bin/codesign", "--verify", "--deep", "--strict"]
    if requirement:
        command += ["-R", "=" + requirement]
    result = subprocess.run(command + [str(path)], capture_output=True)
    require(result.returncode == 0, "应用签名无效或不属于可信的 Dal 开发者")


def owned_bundle(path, expected_id=BUNDLE_ID, *, trusted=False, branded=False):
    require(expected_id in ALLOWED_IDS, "禁止将其他应用身份作为部署目标")
    info = metadata(path)
    require(info.get("CFBundleIdentifier") == expected_id, "目标不属于 Dal，拒绝修改")
    if branded:
        for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
            require(info.get(key) == "Dal", f"{key} 必须为 Dal，禁止恢复旧产品名")
    verify_signature(path, INSTALL_REQUIREMENT if trusted else None)
    return info


def preflight(path, expected_id=BUNDLE_ID):
    require(expected_id in ALLOWED_IDS, "禁止将其他应用身份作为部署目标")
    path = safe_path(path)
    if path.exists():
        owned_bundle(path, expected_id)
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--bundle-id", default=BUNDLE_ID)
    args = parser.parse_args()
    try:
        preflight(args.path, args.bundle_id)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Dal 身份检查失败：{error}\n")
