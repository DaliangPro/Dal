#!/usr/bin/env python3
"""先验证完整候选，再替换 Dal；旧名迁移只接受同一签名的本项目应用。"""

import argparse
from pathlib import Path
import os
import subprocess
import time
import uuid

from app_identity import BUNDLE_ID, metadata, owned_bundle, require, safe_path


def run(*args):
    subprocess.run(args, check=True)


def matching_pids(app, executable):
    expected = str(app / "Contents/MacOS" / executable)
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    result = []
    for row in output.splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and (
            fields[1] == expected or fields[1].startswith(expected + " ")
        ):
            result.append(int(fields[0]))
    return result


def stop_owned(app):
    info = owned_bundle(app, trusted=True)
    executable = info.get("CFBundleExecutable")
    require(executable in ("Dal", "Muse"), "未知的应用可执行文件")
    # 精确路径和再次身份验证后只终止对应 PID，不按 Muse 名称批量退出。
    for pid in matching_pids(app, executable):
        owned_bundle(app, trusted=True)
        os.kill(pid, 15)
    for _ in range(100):
        if not matching_pids(app, executable):
            return
        time.sleep(0.1)
    raise ValueError("应用未退出，保留现有安装")


def install(candidate, destination, *, migrate_legacy=False, launch=True):
    candidate = safe_path(candidate)
    destination = safe_path(destination)
    require(candidate != destination, "候选不能与安装目标相同")
    require(destination.name == "Dal.app", "正式安装文件名必须为 Dal.app")
    owned_bundle(candidate, trusted=True, branded=True)
    if destination.exists():
        owned_bundle(destination, trusted=True)

    # 只检查这两个历史正式路径，身份不匹配直接跳过，绝不注销或移动。
    legacy_apps = []
    if migrate_legacy:
        require(destination == Path("/Applications/Dal.app"), "旧名迁移只适用于正式安装")
        for legacy in (Path("/Applications/Muse.app"), Path("/Applications/Muse 输入法.app")):
            if not legacy.exists() and not legacy.is_symlink():
                continue
            try:
                info = metadata(legacy)
            except (ValueError, OSError):
                continue
            if info.get("CFBundleIdentifier") != BUNDLE_ID:
                continue
            owned_bundle(legacy, trusted=True)
            legacy_apps.append(legacy)

    transaction = uuid.uuid4().hex
    stage_root = destination.parent / f".Dal-install-{transaction}.noindex"
    stage_root.mkdir(mode=0o700)
    stage = stage_root / "Dal.app"
    run("/usr/bin/ditto", str(candidate), str(stage))
    owned_bundle(stage, trusted=True, branded=True)
    backup = stage_root / "previous.app.disabled"
    installed = False
    try:
        if destination.exists():
            stop_owned(destination)
        for legacy in legacy_apps:
            stop_owned(legacy)
        if destination.exists():
            owned_bundle(destination, trusted=True)
            destination.rename(backup)
        require(not destination.exists() and not destination.is_symlink(), "目标被其他进程占用")
        stage.rename(destination)
        installed = True
        owned_bundle(destination, trusted=True, branded=True)
        if launch:
            run("/usr/bin/open", str(destination))
            for _ in range(50):
                if matching_pids(destination, "Dal"):
                    break
                time.sleep(0.2)
            require(len(matching_pids(destination, "Dal")) == 1, "Dal 未正常启动")
    except Exception:
        if installed:
            # 回滚前仍验证自己拥有目标，拒绝移动被外部替换的应用。
            owned_bundle(destination, trusted=True, branded=True)
            stop_owned(destination)
            destination.rename(stage_root / "failed.app.disabled")
        if backup.exists():
            backup.rename(destination)
            if launch:
                run("/usr/bin/open", str(destination))
        else:
            for legacy in legacy_apps:
                if launch:
                    run("/usr/bin/open", str(legacy))
        raise

    trash = Path.home() / ".Trash"
    require(trash.is_dir() and not trash.is_symlink(), "废纸篓不可用，保留备份")
    for index, legacy in enumerate(legacy_apps):
        owned_bundle(legacy, trusted=True)
        unregister = subprocess.run([
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            "LaunchServices.framework/Support/lsregister", "-u", str(legacy)
        ], check=False, capture_output=True)
        if unregister.returncode:
            print("旧应用索引未确认注销；仍将已验明身份的旧包禁用归档。")
        # 归档禁用扩展名，防止启动台重新收录旧版本。
        legacy.rename(trash / f"Dal-legacy-{transaction}-{index}.app.disabled")
    if backup.exists():
        backup.rename(trash / f"Dal-backup-{transaction}.app.disabled")
    stage_root.rmdir()  # 仅移除本次创建且已为空的事务目录。
    print(f"Dal 安装及身份验证通过：{destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--destination", type=Path, default=Path("/Applications/Dal.app"))
    parser.add_argument("--migrate-legacy", action="store_true")
    parser.add_argument("--no-launch", action="store_true")
    args = parser.parse_args()
    try:
        install(args.candidate, args.destination, migrate_legacy=args.migrate_legacy,
                launch=not args.no_launch)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Dal 安装停止：{error}\n")
