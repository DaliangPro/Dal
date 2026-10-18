"""发布入口的隔离回归；模拟 GitHub，不创建真实发布或安装软件。"""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("publish_release", Path(__file__).with_name("publish-release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class PublishReleaseTests(unittest.TestCase):
    def test_version_rejects_paths_and_leading_zeroes(self):
        for value in ("../2.1.2", "2.1", "02.1.2", "2.1.2;whoami", "2.1.2\n"):
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                release.version_parts(value)
        self.assertGreater(release.version_parts("2.1.10"), release.version_parts("2.1.9"))

    def test_ci_ignores_another_commit_and_waits_for_the_right_one(self):
        pending = dict(databaseId=1, headSha="abc", status="in_progress", conclusion="")
        success = dict(pending, status="completed", conclusion="success")
        other = dict(success, headSha="other")
        with patch.object(release, "gh", side_effect=[json.dumps([other]), json.dumps([pending]), json.dumps([success])]), \
                patch.object(release.time, "sleep") as sleep:
            self.assertEqual(release.wait_ci("abc", "push"), 1)
            self.assertEqual(sleep.call_count, 2)

    def test_failed_cancelled_and_timed_out_ci_never_pass(self):
        for result in ("failure", "cancelled", "timed_out", "skipped"):
            record = dict(databaseId=1, headSha="abc", status="completed", conclusion=result)
            with self.subTest(result=result), patch.object(release, "gh", return_value=json.dumps([record])), \
                    self.assertRaises(release.ReleaseError):
                release.wait_ci("abc", "push")

    def test_missing_ci_times_out_without_treating_no_checks_as_success(self):
        with patch.object(release, "gh", return_value="[]"), \
                patch.object(release.time, "monotonic", side_effect=[0, 3000]), \
                self.assertRaises(release.ReleaseError):
            release.wait_ci("abc", "push")

    def test_merge_waits_then_pins_pr_head(self):
        pr = dict(state="OPEN", isDraft=False, baseRefName="main", headRefOid="abc", isCrossRepository=False)
        calls = []

        def gh(*args):
            calls.append(args)
            return json.dumps(pr)

        with patch.object(release, "gh", side_effect=gh), \
                patch.object(release, "wait_ci", side_effect=lambda *args: calls.append(("ci", *args))):
            release.merge_checked_pr(13)
        self.assertEqual(calls[1], ("ci", "abc", "pull_request"))
        self.assertEqual(calls[2][-2:], ("--match-head-commit", "abc"))

    def test_failed_ci_prevents_merge(self):
        pr = dict(state="OPEN", isDraft=False, baseRefName="main", headRefOid="abc", isCrossRepository=False)
        with patch.object(release, "gh", return_value=json.dumps(pr)) as gh, \
                patch.object(release, "wait_ci", side_effect=release.ReleaseError("CI 失败")), \
                self.assertRaises(release.ReleaseError):
            release.merge_checked_pr(13)
        self.assertEqual(gh.call_count, 1)

    def test_tampered_download_stops_before_mount(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / "Muse-v2.1.2.dmg").write_bytes(b"changed")
            (path / "SHA256SUMS.txt").write_text("0" * 64 + "  Muse-v2.1.2.dmg\n")
            with patch.object(release, "verify_dmg") as verify, self.assertRaises(release.ReleaseError):
                release.verify_assets(path, "2.1.2", "abc")
            verify.assert_not_called()

    def test_remote_checksum_pair_cannot_replace_the_local_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            image = path / "Muse-v2.1.2.dmg"
            image.write_bytes(b"another valid-looking image")
            (path / "SHA256SUMS.txt").write_text(release.sha256(image) + "  Muse-v2.1.2.dmg\n")
            with patch.object(release, "verify_dmg") as verify, self.assertRaises(release.ReleaseError):
                release.verify_assets(path, "2.1.2", "abc", "0" * 64)
            verify.assert_not_called()

    def state(self):
        return dict(version="2.1.2", commit="abc", marker="owned", sha256="digest", build="1")

    def draft(self):
        return dict(target_commitish="abc", draft=True, prerelease=False, body="owned", assets=[
            {"name": "Muse-v2.1.2.dmg"}, {"name": "SHA256SUMS.txt"}])

    def test_create_verify_ci_then_publish_in_that_order(self):
        calls = []
        with patch.object(release, "release_for", side_effect=[None, self.draft()]), \
                patch.object(release, "gh", side_effect=lambda *args: calls.append(args[:2])), \
                patch.object(release, "verify_uploaded", side_effect=lambda *args: calls.append(("verify",))), \
                patch.object(release, "api", return_value={"object": {"sha": "abc"}}), \
                patch.object(release, "wait_ci", side_effect=lambda *args: calls.append(("ci",))):
            release.publish_draft(self.state(), Path("/fixture"), Path("/notes"))
        self.assertEqual(calls, [("release", "create"), ("verify",), ("ci",), ("release", "edit")])

    def test_resume_owned_draft_does_not_upload_again(self):
        with patch.object(release, "release_for", return_value=self.draft()), \
                patch.object(release, "gh") as gh, patch.object(release, "verify_uploaded"), \
                patch.object(release, "api", return_value={"object": {"sha": "abc"}}), \
                patch.object(release, "wait_ci"):
            release.publish_draft(self.state(), Path("/fixture"), Path("/notes"))
        self.assertEqual(gh.call_count, 1)
        self.assertEqual(gh.call_args.args[:2], ("release", "edit"))

    def test_interrupted_upload_only_adds_missing_asset_without_overwriting(self):
        partial = dict(self.draft(), assets=[{"name": "Muse-v2.1.2.dmg"}])
        with patch.object(release, "release_for", side_effect=[partial, self.draft()]), \
                patch.object(release, "gh") as gh, patch.object(release, "verify_uploaded"), \
                patch.object(release, "api", return_value={"object": {"sha": "abc"}}), \
                patch.object(release, "wait_ci"):
            release.publish_draft(self.state(), Path("/fixture"), Path("/notes"))
        self.assertEqual(gh.call_args_list[0].args,
                         ("release", "upload", "v2.1.2", "/fixture/SHA256SUMS.txt"))
        self.assertEqual(gh.call_args_list[1].args[:2], ("release", "edit"))

    def test_unowned_or_wrong_source_draft_is_never_modified(self):
        for draft in (dict(self.draft(), body="someone else"), dict(self.draft(), target_commitish="other")):
            with patch.object(release, "release_for", return_value=draft), \
                    patch.object(release, "gh") as gh, self.assertRaises(release.ReleaseError):
                release.publish_draft(self.state(), Path("/fixture"), Path("/notes"))
            gh.assert_not_called()

    def test_asset_failure_main_drift_or_ci_failure_prevents_publication(self):
        for failure in ("asset", "drift", "ci"):
            with self.subTest(failure=failure), patch.object(release, "release_for", return_value=self.draft()), \
                    patch.object(release, "gh") as gh, \
                    patch.object(release, "verify_uploaded", side_effect=(
                        release.ReleaseError("附件不匹配") if failure == "asset" else None)), \
                    patch.object(release, "api", return_value={"object": {"sha": "other" if failure == "drift" else "abc"}}), \
                    patch.object(release, "wait_ci", side_effect=release.ReleaseError("CI 失败")), \
                    self.assertRaises(release.ReleaseError):
                release.publish_draft(self.state(), Path("/fixture"), Path("/notes"))
            gh.assert_not_called()

    def test_already_public_is_verified_but_not_republished(self):
        with patch.object(release, "release_for", return_value=dict(self.draft(), draft=False)), \
                patch.object(release, "gh") as gh, patch.object(release, "verify_uploaded") as verify, \
                patch.object(release, "api", return_value={"object": {"sha": "abc"}}), \
                patch.object(release, "wait_ci"):
            release.publish_draft(self.state(), Path("/fixture"), Path("/notes"))
        verify.assert_called_once()
        gh.assert_not_called()

    def candidate(self, directory):
        image = directory / "Muse-v2.1.2.dmg"
        image.write_bytes(b"verified local image")
        digest = release.sha256(image)
        (directory / "SHA256SUMS.txt").write_text(f"{digest}  {image.name}\n")
        assets = [dict(name=path.name, size=path.stat().st_size, digest=f"sha256:{release.sha256(path)}")
                  for path in (image, directory / "SHA256SUMS.txt")]
        return dict(self.draft(), target_commitish="a" * 40, assets=assets), digest

    def test_matching_server_fingerprints_skip_download_and_remount(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            draft, digest = self.candidate(path)
            with patch.object(release, "command", return_value=""), \
                    patch.object(release, "download_verified") as download, \
                    patch.object(release, "verify_dmg") as mount:
                release.verify_uploaded(draft, path, "2.1.2", "a" * 40, digest, "1")
            download.assert_not_called()
            mount.assert_not_called()
            self.assertEqual(sorted(item.name for item in path.iterdir()),
                             ["Muse-v2.1.2.dmg", "SHA256SUMS.txt"])

    def test_missing_or_abnormal_metadata_falls_back_with_local_fingerprint(self):
        for name in ("Muse-v2.1.2.dmg", "SHA256SUMS.txt"):
            for change in ({"digest": None}, {"digest": "malformed"},
                           {"digest": "sha256:" + "0" * 64}, {"size": 0}):
                with self.subTest(name=name, change=change), tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp)
                    draft, digest = self.candidate(path)
                    next(item for item in draft["assets"] if item["name"] == name).update(change)
                    with patch.object(release, "command", return_value=""), \
                            patch.object(release, "download_verified", return_value="a" * 40) as download:
                        release.verify_uploaded(draft, path, "2.1.2", "a" * 40, digest, "1")
                    download.assert_called_once()
                    args = download.call_args.args
                    self.assertEqual(args[1].parent, path)
                    self.assertEqual(args[2:], ("2.1.2", digest, "1"))

    def test_fallback_rejects_actual_bytes_different_from_local_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            draft, digest = self.candidate(path)
            draft["assets"][0].pop("digest")

            def download(*args):
                destination = Path(args[-1])
                image = destination / "Muse-v2.1.2.dmg"
                image.write_bytes(b"wrong uploaded image")
                (destination / "SHA256SUMS.txt").write_text(f"{release.sha256(image)}  {image.name}\n")

            with patch.object(release, "command", return_value=""), \
                    patch.object(release, "gh", side_effect=download), \
                    patch.object(release, "verify_dmg") as mount, self.assertRaises(release.ReleaseError):
                release.verify_uploaded(draft, path, "2.1.2", "a" * 40, digest, "1")
            mount.assert_not_called()

    def test_fallback_with_correct_bytes_still_checks_signature_and_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            draft, digest = self.candidate(path)
            draft["assets"][0]["digest"] = None

            def download(*args):
                destination = Path(args[-1])
                for name in ("Muse-v2.1.2.dmg", "SHA256SUMS.txt"):
                    (destination / name).write_bytes((path / name).read_bytes())

            with patch.object(release, "command", return_value=""), \
                    patch.object(release, "gh", side_effect=download) as gh, \
                    patch.object(release, "verify_dmg") as mount:
                release.verify_uploaded(draft, path, "2.1.2", "a" * 40, digest, "1")
            gh.assert_called_once()
            mount.assert_called_once()
            self.assertEqual(mount.call_args.args[1:], ("2.1.2", "a" * 40, "1"))

    def test_unknown_duplicate_assets_or_source_drift_fail_before_download(self):
        for failure in ("unknown", "duplicate", "source", "tag"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                draft, digest = self.candidate(path)
                if failure == "unknown":
                    draft["assets"].append({"name": "unexpected.zip"})
                elif failure == "duplicate":
                    draft["assets"].append(draft["assets"][0])
                elif failure == "source":
                    draft["target_commitish"] = "b" * 40
                refs = "b" * 40 + "\trefs/tags/v2.1.2" if failure == "tag" else ""
                with patch.object(release, "command", return_value=refs), \
                        patch.object(release, "download_verified") as download, \
                        self.assertRaises(release.ReleaseError):
                    release.verify_uploaded(draft, path, "2.1.2", "a" * 40, digest, "1")
                download.assert_not_called()

    def test_public_resume_uses_original_candidate_after_main_has_advanced(self):
        from argparse import Namespace
        args = Namespace(version="2.1.2", verify_existing=False, build="1", merge_pr=None)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args.notes = args.smoke_record = root / "notes.md"
            args.notes.write_text("实际验收记录")
            output = root / "dist/manual-release/2.1.2/candidate"
            output.mkdir(parents=True)
            public, digest = self.candidate(output)
            public["draft"] = False
            (output / "state.json").write_text(json.dumps(dict(
                version=args.version, commit="a" * 40, build="1", sha256=digest)))
            with patch.object(release, "ROOT", root), \
                    patch.object(release, "clean_checkout", return_value="b" * 40), \
                    patch.object(release, "release_for", return_value=public), \
                    patch.object(release, "api", return_value={"sha": "a" * 40}), \
                    patch.object(release, "verify_dmg") as mount, \
                    patch.object(release, "download_verified") as download, \
                    patch.object(release, "sync_manifest") as sync:
                release.perform(args)
            download.assert_not_called()
            mount.assert_called_once_with(output / "Muse-v2.1.2.dmg", "2.1.2", "a" * 40, "1")
            sync.assert_called_once_with("2.1.2")

    def test_manifest_noop_keeps_automatic_updates_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "updates.json"
            original = '{"latest":"2.1.2","releases":[]}'
            path.write_text(original)
            with patch.object(release, "ROOT", root), patch.object(release, "clean_checkout"), \
                    patch.object(release, "gh") as gh:
                release.sync_manifest("2.1.2")
            gh.assert_not_called()
            self.assertEqual(path.read_text(), original)

    def test_read_api_network_errors_are_not_absent_releases(self):
        result = Mock(returncode=1, stderr="network unavailable")
        with patch.object(release.subprocess, "run", return_value=result), self.assertRaises(release.ReleaseError):
            release.release_for("v2.1.2")

    def test_draft_without_tag_is_verified_using_the_pinned_source(self):
        commit = "a" * 40
        draft = dict(self.draft(), target_commitish=commit, assets=[
            {"name": "Muse-v2.1.2.dmg"}, {"name": "SHA256SUMS.txt"}])
        with tempfile.TemporaryDirectory() as tmp, patch.object(release, "gh"), \
                patch.object(release, "command", return_value=""), \
                patch.object(release, "verify_assets") as verify, patch.object(release, "api") as api:
            self.assertEqual(release.download_verified(draft, Path(tmp) / "remote", "2.1.2"), commit)
        api.assert_not_called()
        self.assertEqual(verify.call_args.args[2], commit)

    def test_existing_tag_for_another_commit_blocks_draft(self):
        draft = dict(self.draft(), target_commitish="a" * 40, assets=[
            {"name": "Muse-v2.1.2.dmg"}, {"name": "SHA256SUMS.txt"}])
        with tempfile.TemporaryDirectory() as tmp, patch.object(release, "gh"), \
                patch.object(release, "command", return_value="b" * 40 + "\trefs/tags/v2.1.2"), \
                patch.object(release, "verify_assets") as verify, self.assertRaises(release.ReleaseError):
            release.download_verified(draft, Path(tmp) / "remote", "2.1.2")
        verify.assert_not_called()

    def test_mount_is_detached_when_bundle_validation_fails(self):
        import plistlib
        commands = []

        def command(*args):
            commands.append(args[:2])
            if args[1] == "attach":
                return plistlib.dumps({"system-entities": [{"mount-point": "/nonexistent-muse-fixture"}]}).decode()
            return ""

        with patch.object(release, "command", side_effect=command), self.assertRaises(OSError):
            release.verify_dmg(Path("/fixture.dmg"), "2.1.2", "a" * 40)
        self.assertEqual(commands[-1], ("hdiutil", "detach"))

    def test_existing_version_verification_never_merges_or_publishes(self):
        from argparse import Namespace
        args = Namespace(version="2.1.1", verify_existing=True)
        with patch.object(release, "release_for", return_value=dict(self.draft(), draft=False)), \
                patch.object(release, "download_verified", return_value="a" * 40) as verify, \
                patch.object(release, "clean_checkout") as checkout, \
                patch.object(release, "publish_draft") as publish, \
                patch.object(release, "sync_manifest") as sync:
            release.perform(args)
        verify.assert_called_once()
        checkout.assert_not_called()
        publish.assert_not_called()
        sync.assert_not_called()

    def test_missing_smoke_record_stops_before_any_repository_write(self):
        from argparse import Namespace
        args = Namespace(version="2.1.2", verify_existing=False, notes=None, smoke_record=None)
        with patch.object(release, "clean_checkout") as checkout, self.assertRaises(release.ReleaseError):
            release.perform(args)
        checkout.assert_not_called()


if __name__ == "__main__":
    unittest.main()
