"""Source regression checks, including preservation of upstream 1.4.1."""
import subprocess
import unittest
from pathlib import Path

import test_blacklist_140 as baseline

COMMIT = "829f592ecb5b09ef3ac069aad6d55d7319680852"
ARCHIVE = Path(__file__).resolve().parent / "source/blacklist"


class Blacklist141Trust(baseline.Blacklist140Trust):
    def upstream(self, name):
        return subprocess.check_output(
            ["git", "-C", str(self.root), "show", f"{COMMIT}:{name}"]
        ).decode("utf-8").replace("\r\n", "\n")

    def test_exact_pinned_upstream_and_version(self):
        actual = subprocess.check_output(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True
        ).strip()
        self.assertEqual(actual, COMMIT)
        self.assertIn("Version: 1.4.1\n", (self.root / "control").read_text())

    def test_only_four_files_change(self):
        changed = subprocess.check_output(
            ["git", "-C", str(self.root), "diff", "--name-only"], text=True
        ).splitlines()
        self.assertEqual(set(changed), {
            "RootHide/AppDelegate.m",
            "RootHide/AppDataCleaner/AppDataCleaner.m",
            "RootHide/en.lproj/Localizable.strings",
            "RootHide/zh_CN.lproj/Localizable.strings",
        })

    def test_upstream_protection_proxy_scanning_and_packaging_untouched(self):
        for name in (
            "RootHide/main.m", "RootHide/BlacklistViewController.m",
            "RootHide/AppInfo.h", "RootHide/AppInfo.m",
            "RootHide/VarCleanController.m", "RootHide/SettingViewController.m",
            "RootHide.xcodeproj/project.pbxproj", "RootHide/VarCleanRules.json",
            "layout/DEBIAN/postinst", "entitlements.plist",
            "nickchan.entitlements", "Makefile", "control",
        ):
            with self.subTest(file=name):
                self.assertEqual(
                    (self.root / name).read_text(encoding="utf-8"), self.upstream(name)
                )

    def test_cleanup_only_fixes_nserror_not_upstream_path_guard(self):
        name = "RootHide/AppDataCleaner/AppDataCleaner.m"
        expected = self.upstream(name).replace(
            "        if([NSFileManager.defaultManager removeItemAtURL:app.containerURL error:&error]) {",
            "        NSError *removalError = nil;\n"
            "        if([NSFileManager.defaultManager removeItemAtURL:app.containerURL error:&removalError]) {",
        ).replace(
            'Localized(@"Failed to remove app data container:\\n%@"),error]',
            'Localized(@"Failed to remove app data container:\\n%@"),removalError]',
        )
        self.assertEqual((self.root / name).read_text(encoding="utf-8"), expected)

    def test_existing_trust_helpers_are_identical(self):
        old = (ARCHIVE / "RootHide/AppDelegate.m").read_text(encoding="utf-8")

        def helpers(text):
            start = text.index("+ (BOOL)ignoreVPNProxyWarning")
            return text[start:text.index("+ (void)showAlert:", start)]

        self.assertEqual(helpers(self.app), helpers(old))

    def test_all_upstream_localizations_preserved(self):
        for path in (self.root / "RootHide").glob("*.lproj/Localizable.strings"):
            name = path.relative_to(self.root).as_posix()
            actual = path.read_text(encoding="utf-8")
            original = self.upstream(name)
            with self.subTest(file=name):
                if path.parent.name in ("en.lproj", "zh_CN.lproj"):
                    self.assertTrue(actual.startswith(original))
                else:
                    self.assertEqual(actual, original)

    def test_other_detection_warnings_remain(self):
        for text in (
            "Legacy rootless jailbreak(s)", "Unknown preboot system",
            "SSH Server has been installed", "Dropbear has been installed",
            "Frida Server has been installed",
        ):
            with self.subTest(warning=text):
                self.assertIn(text, self.app)
        self.assertIn('NSLocalizedString(@"Settings",@"")', self.app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
