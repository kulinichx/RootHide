"""Pinned ZQBB companion links; --native runs the real Sileo scheme reader.

Foundation reads real temporary plists. Root mapping and jailbreak state are
test boundaries; UIKit, Sileo routing and package installation are not executed.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


ENVIRONMENT = "Application/Dopamine/Jailbreak/DOEnvironmentManager"
SETTINGS = "Application/Dopamine/UI/Settings/DOSettingsController.m"
SCHEME_ANCHOR = "- (NSString *)sileoURLScheme"
# Extracted from w2599/Dopamine 7e14aa6155ce867e9052a88a8c17c632f4c30d77.
UPSTREAM_SCHEME_SHA256 = "813c3faf48f5c6f9bde1f2e987ef895a163d84b20813b6fe83ea2313cba2019d"


class CompanionToolContracts(unittest.TestCase):
    def test_scheme_reader_matches_pinned_zqbb_source(self):
        body = extract(source(ENVIRONMENT + ".m"), SCHEME_ANCHOR)
        self.assertEqual(hashlib.sha256(body.encode("utf-8")).hexdigest(),
                         UPSTREAM_SCHEME_SHA256)
        self.assertIn(SCHEME_ANCHOR + ";", source(ENVIRONMENT + ".h"))

    def test_tool_rows_are_jailbreak_only_and_use_existing_row_height(self):
        specifiers = extract(source(SETTINGS), "- (id)specifiers")
        jailbroken = extract(specifiers, "if (envManager.isJailbroken) {")
        start = jailbroken.index("for (NSDictionary *tool in @[")
        end = jailbroken.index("PSSpecifier *refreshAppsSpecifier", start)
        tools = jailbroken[start:end]
        for title, action in (
            ("Install Whitelist App", "installWhitelistAppPressed"),
            ("Install Mount App", "installMountAppPressed"),
        ):
            self.assertIn(f'@{{@"title": @"{title}", @"action": @"{action}"}}', tools)
        self.assertIn('[toolSpecifier setProperty:buttonHeight forKey:@"height"]', tools)
        self.assertIn('[toolSpecifier setProperty:DOButtonCell.class forKey:@"cellClass"]', tools)
        self.assertEqual(specifiers.count('@"Install Whitelist App"'), 1)
        self.assertEqual(specifiers.count('@"Install Mount App"'), 1)
        self.assertNotIn("pushViewController:", tools)

    def test_actions_only_route_to_pinned_package_identifiers(self):
        settings = source(SETTINGS)
        for action, identifier in (
            ("installWhitelistAppPressed", "cn.zqbb.inject.manager"),
            ("installMountAppPressed", "cn.zqbb.hello.mnt"),
        ):
            body = extract(settings, f"- (void){action}")
            self.assertEqual(body.split("{", 1)[1].strip(),
                             f'[self openSileoPackage:@"{identifier}"];\n}}')
        open_package = extract(settings, "- (void)openSileoPackage:")
        self.assertLess(open_package.index("if (!environment.isJailbroken) return;"),
                        open_package.index("openURL:url"))
        self.assertIn('@"%@://package/%@"', open_package)
        self.assertIn("environment.sileoURLScheme", open_package)
        self.assertIn("if (success) return;", open_package)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", open_package)
        self.assertIn('DOLocalizedString(@"Sileo_Open_Failed")', open_package)
        for forbidden in ("exec_cmd", "writeToFile:", "runAsRoot:",
                          "cn.zqbb.inject.plist", "startAccessingSecurityScopedResource"):
            self.assertNotIn(forbidden, open_package)

    def test_scheme_lookup_is_read_only_and_has_no_background_work(self):
        body = extract(source(ENVIRONMENT + ".m"), SCHEME_ANCHOR)
        for forbidden in ("writeToFile:", "exec_cmd", "NSTimer", "dispatch_async",
                          "runAsRoot:", "cn.zqbb.inject.plist", "addObserver"):
            self.assertNotIn(forbidden, body)

    def test_titles_and_failure_message_are_localized_without_duplicate_keys(self):
        for locale in ("en", "zh-Hans", "zh-CN"):
            text = source(f"Application/Dopamine/{locale}.lproj/Localizable.strings")
            for key in ("Install Whitelist App", "Install Mount App",
                        "Sileo_Open_Failed", "Log_Error", "Button_OK"):
                pattern = rf'^\s*"{re.escape(key)}"\s*=\s*"[^"]+"\s*;'
                self.assertEqual(len(re.findall(pattern, text, re.MULTILINE)), 1,
                                 (locale, key))

    def test_native_scheme_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_companion_tools.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

static NSString *testRoot;
#define JBROOT_PATH(path) [testRoot stringByAppendingString:(path)]

@interface DOEnvironmentManager : NSObject
@property (nonatomic) BOOL isJailbroken;
- (NSString *)sileoURLScheme;
@end

@implementation DOEnvironmentManager
'''

NATIVE_MAIN = r'''
@end

static NSString *infoPath(void) {
    return JBROOT_PATH(@"/Applications/Sileo.app/Info.plist");
}

static void saveInfo(id value) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
                                    format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    assert(data && !error);
    assert([data writeToFile:infoPath() atomically:YES]);
}

static void expectScheme(DOEnvironmentManager *manager, NSString *expected) {
    NSData *before = [NSData dataWithContentsOfFile:infoPath()];
    assert([[manager sileoURLScheme] isEqualToString:expected]);
    NSData *after = [NSData dataWithContentsOfFile:infoPath()];
    assert(before ? [before isEqualToData:after] : after == nil);
}

int main(void) { @autoreleasepool {
    testRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    DOEnvironmentManager *manager = [DOEnvironmentManager new];
    expectScheme(manager, @"sileo");
    manager.isJailbroken = YES;
    expectScheme(manager, @"sileo");

    assert([NSFileManager.defaultManager createDirectoryAtPath:[infoPath() stringByDeletingLastPathComponent]
                                withIntermediateDirectories:YES attributes:nil error:nil]);
    saveInfo(@{@"CFBundleURLTypes": @[@{@"CFBundleURLSchemes": @[@"sileo-roothide-1234"]}]});
    manager.isJailbroken = NO;
    expectScheme(manager, @"sileo");
    manager.isJailbroken = YES;
    expectScheme(manager, @"sileo-roothide-1234");

    saveInfo(@{});
    expectScheme(manager, @"sileo");
    saveInfo(@{@"CFBundleURLTypes": @"invalid"});
    expectScheme(manager, @"sileo");
    saveInfo(@{@"CFBundleURLTypes": @[@"invalid", @42,
        @{@"CFBundleURLSchemes": @"invalid"},
        @{@"CFBundleURLSchemes": @[@42, @"", @"bad scheme", @"sileo-second"]}]});
    expectScheme(manager, @"sileo-second");

    saveInfo(@{@"CFBundleURLTypes": @[@{@"CFBundleURLSchemes":
        @[@"bad scheme", @"bad/scheme", @"bad://host", @""]}]});
    expectScheme(manager, @"sileo");
    saveInfo(@{@"CFBundleURLTypes": @[@{@"CFBundleURLSchemes": @[@"sileo-first", @"sileo-second"]}]});
    expectScheme(manager, @"sileo-first");
    saveInfo(@{@"CFBundleURLTypes": @[]});
    expectScheme(manager, @"sileo");
    saveInfo(@[]);
    expectScheme(manager, @"sileo");
    assert([@"not a plist" writeToFile:infoPath() atomically:YES
                             encoding:NSUTF8StringEncoding error:nil]);
    expectScheme(manager, @"sileo");
    assert([NSFileManager.defaultManager removeItemAtPath:infoPath() error:nil]);
    expectScheme(manager, @"sileo");
    assert([NSFileManager.defaultManager removeItemAtPath:testRoot error:nil]);
    testRoot = nil;
    assert([[manager sileoURLScheme] isEqualToString:@"sileo"]);
    puts("PASS: production Sileo scheme reader, rewritten scheme, malformed/missing plists, jailbreak gate and read-only behavior");
} return 0; }
'''


def native_tests():
    clang = shutil.which("clang")
    if sys.platform != "darwin" or not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    code = "\n".join((NATIVE_PREFIX,
                      extract(source(ENVIRONMENT + ".m"), SCHEME_ANCHOR),
                      NATIVE_MAIN))
    with tempfile.TemporaryDirectory(prefix="rc9-companion-tools-") as directory:
        path = Path(directory) / "companion_tools.m"
        binary = Path(directory) / "companion_tools"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run([
                clang, "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                "-Wall", "-Wextra", "-Werror", "-O1", "-g",
                "-fsanitize=address,undefined", str(path), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, timeout=30,
                                    capture_output=True, text=True)
            print(result.stdout, end="")
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            if not diagnostic:
                diagnostic = f"native command exited with status {error.returncode}"
            escaped = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Companion tool native regression::{escaped[:3000]}")
            sys.stderr.write(diagnostic)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(CompanionToolContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; --native requires macOS Foundation.")
