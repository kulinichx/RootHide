"""Source-level checks for the RootHide Manager 1.4.0 trust migration."""
import sys
import unittest
from pathlib import Path

SOURCE_ROOT = Path(sys.argv.pop(1))


class Blacklist140Trust(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = SOURCE_ROOT
        cls.app = (cls.root / "RootHide/AppDelegate.m").read_text(encoding="utf-8")
        cls.zh = (cls.root / "RootHide/zh_CN.lproj/Localizable.strings").read_text(encoding="utf-8")
        cls.en = (cls.root / "RootHide/en.lproj/Localizable.strings").read_text(encoding="utf-8")

    def test_preferences_are_persisted_in_existing_roothide_config(self):
        self.assertIn('RHTrustedBindMountsKey = @"TrustedBindMountsV1"', self.app)
        self.assertIn('RHIgnoreVPNProxyWarningKey = @"IgnoreVPNProxyWarningV1"', self.app)
        self.assertIn('RootHideConfig.plist', self.app)
        self.assertIn('[self setDefaults:trusted forKey:RHTrustedBindMountsKey]', self.app)
        self.assertIn('[AppDelegate setDefaults:@YES forKey:RHIgnoreVPNProxyWarningKey]', self.app)

    def test_bindfs_warning_can_trust_only_the_selected_mount(self):
        self.assertIn('strcmp(ss[i].f_fstypename,"bindfs")==0', self.app)
        self.assertIn('[AppDelegate isTrustedBindMount:fingerprint]', self.app)
        self.assertIn('[AppDelegate showBindMountTrustPrompt:fingerprint]', self.app)
        self.assertIn('Localized(@"Trust This Mount")', self.app)
        self.assertIn('Localized(@"Keep Warning")', self.app)

    def test_vpn_proxy_warning_preference_and_localizations(self):
        self.assertIn('vpn.boolValue && ![AppDelegate ignoreVPNProxyWarning]', self.app)
        for text in (
            'BindFS Mount Trust',
            'Trust This Mount',
            'Keep Warning',
            'VPN/Proxy Warning',
            "Don't Show VPN/Proxy Warning Again",
        ):
            with self.subTest(text=text):
                self.assertIn(text, self.en)
                self.assertIn(text, self.zh)

    def test_cleanup_error_uses_nserror_without_changing_return_type(self):
        cleaner = (self.root / "RootHide/AppDataCleaner/AppDataCleaner.m").read_text(encoding="utf-8")
        self.assertIn("NSString* clearAppData(RHMInstalledAppInfo* app)", cleaner)
        self.assertNotIn("clearAppData(AppInfo*", cleaner)
        self.assertIn("NSError *removalError = nil;", cleaner)
        self.assertIn("error:&removalError", cleaner)
        self.assertNotIn("error:&error", cleaner)
        self.assertIn("return error;", cleaner)


if __name__ == "__main__":
    unittest.main(verbosity=2)
