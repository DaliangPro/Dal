#!/usr/bin/env python3
"""Muse 单人维护发布入口：固定源码、CI、签名、草稿复验、公开及清单同步。"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
REPO = "DaliangPro/Muse"
VERSION = re.compile(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})")


class ReleaseError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def version_parts(value):
    require(bool(VERSION.fullmatch(value)), "版本号必须是数字格式，例如 2.1.2")
    return tuple(map(int, value.split(".")))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(*args, env=None, capture=True):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, check=False)
    if result.returncode:
        # 不输出认证命令环境或凭据；详细构建输出由非捕获模式直接展示。
        raise ReleaseError(f"步骤失败（退出码 {result.returncode}）：{' '.join(args[:3])}")
    return result.stdout.strip() if capture else ""


def gh(*args):
    return command("gh", *args, "--repo", REPO)


def api(path):
    return json.loads(command("gh", "api", f"repos/{REPO}/{path}"))


def release_for(tag):
    # 404 才表示不存在，认证/网络故障不能被当成可创建新版本。
    result = subprocess.run(["gh", "api", f"repos/{REPO}/releases/tags/{tag}"],
                            cwd=ROOT, text=True, capture_output=True, check=False)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise ReleaseError("无法读取 GitHub Release；请检查登录和网络后重试")
    return json.loads(result.stdout)


def wait_ci(commit, event, timeout=2700):
    deadline = time.monotonic() + timeout
    previous = None
    while True:
        branch = ("--branch", "main") if event == "push" else ()
        runs = json.loads(gh("run", "list", "--workflow", "ci.yml", "--commit", commit,
                             "--event", event, *branch, "--limit", "20", "--json",
                             "databaseId,status,conclusion,headSha"))
        runs = [run for run in runs if run["headSha"] == commit]
        current = runs[0] if runs else None
        if current != previous:
            print(f"等待同一源码的 CI：{commit[:7]}，{current or '等待启动'}", flush=True)
            previous = current
        if current and current["status"] == "completed":
            require(current["conclusion"] == "success", "CI 未通过；修复并推送后重新执行，不会合并或公开")
            return current["databaseId"]
        require(time.monotonic() < deadline, "等待 CI 超时；可用相同命令继续，不会跳过检查")
        time.sleep(15)


def clean_checkout():
    require(not command("git", "status", "--porcelain", "--untracked-files=no"),
            "存在未提交修改，请先提交；发布不能包含未审阅的代码")
    require(command("git", "branch", "--show-current") == "main", "请在 main 分支运行发布入口")
    require(command("git", "remote", "get-url", "origin") in (
        "https://github.com/DaliangPro/Muse.git", "git@github.com:DaliangPro/Muse.git"),
        "origin 不是 Muse 正式仓库")
    command("git", "fetch", "origin", "main")
    command("git", "merge", "--ff-only", "origin/main")
    require(command("git", "rev-parse", "HEAD") == command("git", "rev-parse", "origin/main"),
            "本机 main 含未推送提交，请先通过 PR 合并")
    return command("git", "rev-parse", "HEAD")


def merge_checked_pr(number):
    pr = json.loads(gh("pr", "view", str(number), "--json",
                       "state,isDraft,baseRefName,headRefOid,isCrossRepository"))
    require(pr["state"] == "OPEN" and not pr["isDraft"], "PR 必须是已准备好的未合并 PR")
    require(pr["baseRefName"] == "main" and not pr["isCrossRepository"], "只合并本仓库指向 main 的 PR")
    wait_ci(pr["headRefOid"], "pull_request")
    gh("pr", "merge", str(number), "--squash", "--match-head-commit", pr["headRefOid"])


def verify_dmg(path, version, commit, build=None):
    command("hdiutil", "verify", str(path))
    attached = command("hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(path))
    import plistlib
    mounts = [item["mount-point"] for item in plistlib.loads(attached.encode())["system-entities"]
              if "mount-point" in item]
    require(len(mounts) == 1, "安装镜像的挂载点不唯一")
    try:
        app = Path(mounts[0]) / "Muse.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(info["CFBundleIdentifier"] == "pro.daliang.muse", "安装包 Bundle 不匹配")
        require(info["CFBundleShortVersionString"] == version, "安装包版本不匹配")
        require(info["MuseSourceCommit"] == commit, "安装包源码与固定提交不一致")
        if build is not None:
            require(str(info["CFBundleVersion"]) == build, "安装包 Build 不匹配")
        command("codesign", "--verify", "--deep", "--strict", str(app))
        signature = subprocess.run(["codesign", "-dvvv", str(app)],
                                   capture_output=True, text=True, check=True)
        require("Authority=Muse Local\n" in signature.stderr, "安装包必须复用 Muse Local 签名")
        require(not (app / "Contents/MacOS/sensevoice-server-dist").exists(),
                "默认分发包不能混入本地服务")
        require(not (app / "Contents/MacOS/qwen3-asr-server-dist").exists(),
                "默认分发包不能混入本地服务")
    finally:
        command("hdiutil", "detach", mounts[0])


def verify_assets(directory, version, commit, expected_hash=None, build=None):
    name = f"Muse-v{version}.dmg"
    image = directory / name
    digest = sha256(image)
    require((directory / "SHA256SUMS.txt").read_text().strip() == f"{digest}  {name}",
            "下载文件与 SHA256 清单不一致")
    if expected_hash:
        require(digest == expected_hash, "GitHub 下载文件与本机发布制品不同")
    verify_dmg(image, version, commit, build)
    return digest


def download_verified(release, directory, version, expected_hash=None, build=None):
    directory.mkdir(parents=True, exist_ok=False)
    expected = {f"Muse-v{version}.dmg", "SHA256SUMS.txt"}
    require({item["name"] for item in release["assets"]} == expected, "Release 附件不完整或含未知文件")
    gh("release", "download", f"v{version}", "--dir", str(directory))
    if release["draft"]:
        # GitHub 草稿可能尚未建立标签，先按固定的完整提交校验；若标签已经存在，
        # 必须确认它也指向同一源码，避免公开时沿用另一个提交的旧标签。
        commit = release["target_commitish"]
        require(bool(re.fullmatch(r"[0-9a-f]{40}", commit)), "草稿来源没有固定到完整提交")
        refs = command("git", "ls-remote", "--tags", "origin",
                       f"refs/tags/v{version}", f"refs/tags/v{version}^{{}}")
        if refs:
            tag_commit = refs.splitlines()[-1].split()[0]
            require(tag_commit == commit, "已有同名标签指向另一源码，拒绝公开")
    else:
        commit = api(f"commits/v{version}")["sha"]
    require(release["target_commitish"] == commit, "Release 目标没有固定为完整源码提交")
    verify_assets(directory, version, commit, expected_hash, build)
    return commit


def publish_draft(state, output, notes_file):
    tag = f"v{state['version']}"
    existing = release_for(tag)
    if existing:
        require(existing["target_commitish"] == state["commit"], "同名 Release 指向另一提交，拒绝覆盖")
        require(not existing["prerelease"], "拒绝把预发布版本误作正式版本")
        if existing["draft"]:
            require(state["marker"] in existing["body"], "已有草稿不属于本次发布，拒绝覆盖")
    else:
        gh("release", "create", tag, str(output / f"Muse-v{state['version']}.dmg"),
           str(output / "SHA256SUMS.txt"), "--draft", "--target", state["commit"],
           "--title", f"Muse v{state['version']}", "--notes-file", str(notes_file))
        existing = release_for(tag)
        require(existing is not None, "创建草稿后无法读取，可用相同命令续跑")
    # 续跑也重新下载并比较本机指纹，验证失败留下草稿，绝不公开或覆盖附件。
    download_verified(existing, output / f"download-{uuid.uuid4().hex[:8]}",
                      state["version"], state["sha256"], state["build"])
    require(api("git/ref/heads/main")["object"]["sha"] == state["commit"],
            "main 已更新，草稿保留；请检查新改动后重新准备候选")
    wait_ci(state["commit"], "push")
    if existing["draft"]:
        gh("release", "edit", tag, "--draft=false", "--latest")
    print(f"发布已公开：https://github.com/{REPO}/releases/tag/{tag}", flush=True)


def sync_manifest(version):
    # 已公开后才更新清单；固定文件留空 releases，绝不启用自动更新。
    clean_checkout()
    path = ROOT / "updates.json"
    manifest = json.loads(path.read_text())
    if version_parts(manifest["latest"]) >= version_parts(version):
        return
    branch = f"codex/release-manifest-{version}"
    prs = json.loads(gh("pr", "list", "--head", branch, "--state", "open", "--json", "number"))
    if prs:
        number = prs[0]["number"]
    else:
        # 失败重试可复用已经提交的清单分支，不强推，不重复创建。
        refs = command("git", "for-each-ref", "--format=%(refname:short)", f"refs/heads/{branch}")
        command("git", "switch", branch) if refs else command("git", "switch", "-c", branch)
        try:
            manifest["latest"] = version
            path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            command("git", "add", "updates.json")
            if command("git", "diff", "--cached", "--name-only"):
                command("git", "commit", "-m", f"更新: 同步已发布版本 {version}")
            command("git", "push", "-u", "origin", branch)
            url = gh("pr", "create", "--base", "main", "--head", branch,
                     "--title", f"更新: 同步已发布版本 {version}", "--body",
                     f"GitHub v{version} 安装包下载及签名复验通过，更新已发布版本基线；自动更新保持关闭。")
            print(f"清单 PR 已创建：{url}", flush=True)
            number = int(url.rstrip("/").split("/")[-1])
        finally:
            # 不丢弃改动；若提交失败，保留原分支和现场供修复。
            if not command("git", "status", "--porcelain", "--untracked-files=no"):
                command("git", "switch", "main")
    merge_checked_pr(number)
    clean_checkout()


def perform(args):
    version_parts(args.version)
    if args.verify_existing:
        release = release_for(f"v{args.version}")
        require(release and not release["draft"] and not release["prerelease"], "该版本尚未正式公开")
        path = ROOT / "dist/manual-release" / f"verify-{uuid.uuid4().hex[:8]}"
        commit = download_verified(release, path, args.version)
        print(f"已验证公开版本 {args.version}，源码 {commit}；未修改 GitHub 或安装版。")
        return
    require(args.notes and args.smoke_record, "发布需提供 --notes 和 --smoke-record；不会虚构真机验收")
    notes = args.notes.resolve()
    smoke = args.smoke_record.resolve()
    require(notes.is_file() and smoke.is_file(), "发布说明或真机验收记录不存在")
    require(notes.read_text().strip() and smoke.read_text().strip(), "发布说明或验收记录为空")
    require(args.build.isdigit() and int(args.build) > 0, "Build 必须为正整数")
    clean_checkout()
    if args.merge_pr:
        merge_checked_pr(args.merge_pr)
    commit = clean_checkout()
    work = ROOT / "dist/manual-release" / args.version
    output = work / "candidate"
    state_file = output / "state.json"
    existing = release_for(f"v{args.version}")
    if existing and not existing["draft"]:
        require(not existing["prerelease"], "同名版本是预发布版本")
        download_verified(existing, output / f"public-{uuid.uuid4().hex[:8]}", args.version)
        sync_manifest(args.version)
        return
    releases = json.loads(gh("release", "list", "--limit", "1000", "--json", "tagName,isDraft,isPrerelease"))
    versions = [version_parts(item["tagName"][1:]) for item in releases
                if not item["isDraft"] and not item["isPrerelease"]
                and item["tagName"].startswith("v") and VERSION.fullmatch(item["tagName"][1:])]
    require(not versions or version_parts(args.version) > max(versions), "新版本必须高于已公开的最高版本")
    identity = command("security", "find-identity", "-v", "-p", "codesigning")
    require('"Muse Local"' in identity, "当前机器没有 Muse Local 签名证书；不会导出私钥或更换身份")
    ci_id = wait_ci(commit, "push")
    if state_file.exists():
        state = json.loads(state_file.read_text())
        require(state["commit"] == commit and state["version"] == args.version
                and state["build"] == args.build and state["notes_sha256"] == sha256(notes)
                and state["smoke_sha256"] == sha256(smoke), "候选源码或说明已变更，拒绝覆盖已有候选")
        verify_assets(output, args.version, commit, state["sha256"], args.build)
    else:
        require(existing is None, "GitHub 已有草稿但本机缺少发布记录，拒绝接管")
        require(not output.exists(), "候选目录损坏，拒绝覆盖；请保留现场后检查")
        work.mkdir(parents=True, exist_ok=True)
        attempt = work / f"build-{uuid.uuid4().hex[:8]}"
        attempt.mkdir()
        # 只允许选定的本机签名路线；构建脚本保持干净源码和严格签名要求。
        env = {key: value for key, value in os.environ.items() if not key.startswith("MUSE_")}
        env.update(APP_VERSION=args.version, APP_BUILD=args.build,
                   ARTIFACT_KIND="cloud", ALLOW_LOCAL_SIGNING="1", CODESIGN_IDENTITY="Muse Local",
                   DIST_DIR=str(attempt), DMG_NAME=f"Muse-v{args.version}.dmg")
        print("构建并严格验证 Muse Local 安装包……", flush=True)
        command("bash", "scripts/build-dmg.sh", env=env, capture=False)
        image = attempt / f"Muse-v{args.version}.dmg"
        digest = sha256(image)
        (attempt / "SHA256SUMS.txt").write_text(f"{digest}  {image.name}\n")
        verify_assets(attempt, args.version, commit, digest, args.build)
        require(command("git", "rev-parse", "HEAD") == commit, "构建期间源码发生变化")
        state = dict(version=args.version, build=args.build, commit=commit, ci_run=ci_id,
                     sha256=digest, notes_sha256=sha256(notes), smoke_sha256=sha256(smoke),
                     marker=f"<!-- muse-manual-release:{uuid.uuid4()} -->")
        # 整个候选目录原子晋升；即使进程中断也不会留下只有一半文件的候选。
        (attempt / "state.json").write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
        attempt.rename(output)
    publication_notes = output / "release-notes.md"
    publication_notes.write_text(notes.read_text() + "\n\n"
        "发布方式：Muse Local 签名，未进行 Apple 公证；自动更新关闭，不捆绑本地 ASR 服务及模型。\n\n"
        f"源码：{commit}\n\nCI：https://github.com/{REPO}/actions/runs/{ci_id}\n\n"
        f"SHA256：`{state['sha256']}`\n\n{state['marker']}\n")
    publish_draft(state, output, publication_notes)
    sync_manifest(args.version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="新版本，例如 2.1.2")
    parser.add_argument("--build", default="1")
    parser.add_argument("--notes", type=Path, help="发布说明文件")
    parser.add_argument("--smoke-record", type=Path, help="已完成的真机验收记录（不替代现场验证）")
    parser.add_argument("--merge-pr", type=int, help="先等待该 PR 的 CI，通过后再合并")
    parser.add_argument("--verify-existing", action="store_true", help="只下载复验已有公开版本，不发版")
    args = parser.parse_args()
    try:
        # 锁文件常驻 git 内部目录，不入库；退出或中断会自动释放，不留假死锁。
        git_dir = Path(command("git", "rev-parse", "--absolute-git-dir"))
        with (git_dir / "muse-manual-release.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            perform(args)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"发布未继续：{error}。已有公开版本和草稿不删除。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
