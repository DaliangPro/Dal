"""只用隔离假应用测试身份边界，禁止操作实际 /Applications。"""

import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import app_identity as identity

SPEC = importlib.util.spec_from_file_location(
    "dal_installer", Path(__file__).with_name("install-app.py"))
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="dal-identity-")).resolve()
        self.home = self.root / "home"
        (self.home / ".Trash").mkdir(parents=True)

    def tearDown(self):
        # 按项目要求只归档本次测试数据，不永久删除。
        self.root.rename(Path.home() / ".Trash" / self.root.name)

    def app(self, name, bundle=identity.BUNDLE_ID, brand="Dal", signed=True):
        app = self.root / name
        (app / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", app / "Contents/MacOS/Dal")
        (app / "Contents/MacOS/Dal").chmod(0o755)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleIdentifier": bundle,
                "CFBundleName": brand,
                "CFBundleDisplayName": brand,
                "CFBundleExecutable": "Dal",
                "CFBundleVersion": "1",
                "CFBundlePackageType": "APPL",
            }, stream)
        if signed:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                           check=True, capture_output=True)
        return app

    def snapshot(self, app):
        return {str(p.relative_to(app)): p.read_bytes()
                for p in app.rglob("*") if p.is_file() and not p.is_symlink()}

    def test_wrong_missing_and_meta_ids_are_untouched(self):
        for index, bundle in enumerate(["com.meta.endo", "com.facebook.hatch",
                                        "example.unrelated", ""]):
            app = self.app(f"foreign-{index}.app", bundle=bundle)
            before = self.snapshot(app)
            with self.assertRaises(ValueError):
                identity.preflight(app)
            self.assertEqual(self.snapshot(app), before)

    def test_missing_metadata_and_file_instead_of_app_are_rejected(self):
        app = self.root / "empty.app"
        app.mkdir()
        with self.assertRaises(ValueError):
            identity.preflight(app)
        file = self.root / "file.app"
        file.write_text("保留")
        with self.assertRaises(ValueError):
            identity.preflight(file)
        self.assertEqual(file.read_text(), "保留")

    def test_cannot_override_expected_identity_to_meta(self):
        app = self.app("Meta.app", bundle="com.meta.endo")
        with self.assertRaises(ValueError):
            identity.preflight(app, "com.meta.endo")

    def test_symlink_bundle_and_ancestor_are_rejected(self):
        app = self.app("real.app")
        link = self.root / "linked.app"
        link.symlink_to(app)
        with self.assertRaises(ValueError):
            identity.preflight(link)
        directory = self.root / "redirect"
        directory.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            identity.preflight(directory / "real.app")

    def test_valid_identifier_with_wrong_signer_is_not_installable(self):
        app = self.app("Dal.app")
        # 真实有效 ad-hoc 签名通过完整性检查，但不满足维护者证书身份。
        identity.owned_bundle(app)
        with self.assertRaises(ValueError):
            identity.owned_bundle(app, trusted=True)

    def test_tampered_signature_is_rejected(self):
        app = self.app("Dal.app")
        (app / "Contents/Info.plist").write_bytes(
            (app / "Contents/Info.plist").read_bytes() + b"\n")
        with self.assertRaises(ValueError):
            identity.preflight(app)

    def test_old_product_name_cannot_be_installed(self):
        app = self.app("Dal.app", brand="Muse")
        with self.assertRaisesRegex(ValueError, "必须为 Dal"):
            identity.owned_bundle(app, branded=True)

    def test_install_and_rollback_use_only_owned_destination(self):
        source = self.app("candidate.app")
        target = self.app("Dal.app")
        before = self.snapshot(target)
        real_verify = identity.verify_signature

        def integrity_only(path, requirement=None):
            # 测试不访问钥匙串，保留真实严格完整性检查，仅替换信任根。
            real_verify(path)

        with patch.object(identity, "verify_signature", side_effect=integrity_only), \
                patch.object(Path, "home", return_value=self.home):
            installer.install(source, target, launch=False)
            self.assertEqual(identity.metadata(target)["CFBundleName"], "Dal")
            backups = list((self.home / ".Trash").glob("*.app.disabled"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(self.snapshot(backups[0]), before)

            # 复制后验签失败不得停止或替换已安装的应用。
            before = self.snapshot(target)
            def fail_stage(path, requirement=None):
                if ".noindex" in str(path):
                    raise ValueError("模拟候选复制损坏")
                real_verify(path)
            with patch.object(identity, "verify_signature", side_effect=fail_stage):
                with self.assertRaises(ValueError):
                    installer.install(source, target, launch=False)
            self.assertEqual(self.snapshot(target), before)

    def test_meta_destination_is_never_stopped_or_moved(self):
        source = self.app("candidate.app")
        target = self.app("Dal.app", bundle="com.meta.endo")
        before = self.snapshot(target)
        with patch.object(identity, "verify_signature"), \
                patch.object(installer, "stop_owned") as stop:
            with self.assertRaises(ValueError):
                installer.install(source, target, launch=False)
            stop.assert_not_called()
        self.assertEqual(self.snapshot(target), before)

    def test_post_swap_failure_restores_previous_signed_bundle(self):
        source = self.app("candidate.app")
        target = self.app("Dal.app")
        before = self.snapshot(target)
        real_owned = installer.owned_bundle
        real_verify = identity.verify_signature
        rejected = False

        def fail_final(path, **kwargs):
            nonlocal rejected
            if path == target and kwargs.get("branded") and not rejected:
                rejected = True
                raise ValueError("模拟正式路径最终验证失败")
            return real_owned(path, **kwargs)

        with patch.object(identity, "verify_signature",
                          side_effect=lambda path, requirement=None: real_verify(path)), \
                patch.object(installer, "owned_bundle", side_effect=fail_final):
            with self.assertRaisesRegex(ValueError, "模拟正式路径"):
                installer.install(source, target, launch=False)
        self.assertTrue(rejected)
        self.assertEqual(self.snapshot(target), before)


if __name__ == "__main__":
    unittest.main()
