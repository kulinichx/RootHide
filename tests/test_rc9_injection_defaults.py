"""Check fresh-install blacklist mode and preservation of optional whitelist state.

--native executes the production initializer and mode selector with Foundation
and real temporary plists. Root-path mapping and per-process decisions are
mocked; this is not an iOS injection or package-manager acceptance test.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


JAILBREAKER = "Application/Dopamine/Jailbreak/DOJailbreaker.m"
BLACKLIST = "BaseBin/libjailbreak/src/roothider/blacklist.m"


def without_comments(text):
    pattern = r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*[\s\S]*?\*/'
    return re.sub(pattern, lambda match: match.group(1) or "", text)


class InjectionDefaultContracts(unittest.TestCase):
    def test_initializer_does_not_create_or_remove_user_mode_file(self):
        body = extract(source(JAILBREAKER), "static void initializeRootHideWhitelistDefaults(")
        body = without_comments(body)
        self.assertNotIn('"cn.zqbb.inject.plist"', body)
        for token in ("removeItemAtPath:", "unlink(", "rename("):
            self.assertNotIn(token, body)
        for filename in ("cn.zqbb.inject.system.plist",
                         "cn.zqbb.inject.wantsblacklist.plist",
                         "cn.zqbb.jetsam.addend.plist"):
            self.assertIn(filename, body)

    def test_user_mode_file_is_the_selector_not_manager_installation(self):
        body = extract(source(BLACKLIST), "bool isBlacklistedPath(")
        self.assertIn('cn.zqbb.inject.plist', body)
        self.assertIn("if(access(injectPlistPath, F_OK) == 0)", body)
        self.assertTrue(body.rstrip().endswith("return isBlacklistedPath_orig(path);\n}"))
        self.assertNotIn("cn.zqbb.inject.manager", body)
        self.assertNotIn("inject.system.plist, F_OK", body)

    def test_bootstrap_does_not_install_optional_inject_manager(self):
        text = source("Application/Dopamine/Jailbreak/DOBootstrapper.m")
        active = text.split("@implementation DOBootstrapper(roothide)", 1)[1]
        body = extract(without_comments(active), "- (NSError *)finalizeBootstrap")
        self.assertIn('@"roothideapp.deb"', body)
        self.assertIn('@"com.roothide.manager"', body)
        self.assertNotIn("cn.zqbb.inject.manager", body)

    def test_native_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_injection_defaults.py --native",
                      source(".github/workflows/roothide.yml"))


class VerboseLogContracts(unittest.TestCase):
    def test_switch_is_pre_jailbreak_only_and_defaults_to_off(self):
        settings = source("Application/Dopamine/UI/Settings/DOSettingsController.m")
        self.assertRegex(settings, r"if \(!envManager\.isJailbroken\) \{\s*"
                         r"PSSpecifier \*verboseLogSpecifier")
        start = settings.index("PSSpecifier *verboseLogSpecifier")
        block = settings[start:settings.index("[specifiers addObject:verboseLogSpecifier];", start)]
        self.assertIn('@"verboseLogsEnabled"', block)
        self.assertIn('[verboseLogSpecifier setProperty:@NO forKey:@"default"]', block)
        reader = extract(source("Application/Dopamine/UI/DOUIManager.m"), "- (BOOL)isDebug")
        self.assertIn("debug == nil ? NO : [debug boolValue]", reader)

    def test_preference_selects_debug_view_and_records_before_display_filter(self):
        button = source("Application/Dopamine/UI/DOJailbreakButton.m")
        self.assertRegex(button, r"if \(\[\[DOUIManager sharedInstance\] isDebug\]\)"
                         r"\s*self\.logView = \[\[DODebugLogView alloc\] init\]")
        ui = source("Application/Dopamine/UI/DOUIManager.m")
        body = extract(ui, "- (void)sendLog:(NSString*)log debug:(BOOL)debug update:")
        self.assertLess(body.index("[self.logRecord addObject:log]"),
                        body.index("if (debug && !isDebug)"))
        self.assertIn("componentsJoinedByString:", extract(ui, "- (void)shareLogRecordFromView:"))


PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *testRoot;
static const char *injectPlistPath, *injectSystemPlistPath;
static bool systemAllowed, executableAllowed;
static NSString *testRootPath(NSString *path) {
    return [testRoot stringByAppendingString:path];
}
static const char *testCStringPath(const char *path) {
    return testRootPath([NSString stringWithUTF8String:path]).fileSystemRepresentation;
}
static bool isBlacklistedPath_orig(const char *path) {
    return path && !strcmp(path, "/app/Blacklisted");
}
static bool zqbb_isWhiteListForSystem(const char *path, const char *systemPath) {
    assert(path && systemPath); return systemAllowed;
}
static bool zqbb_isBlacklistedExec(const char *path, const char *userPath) {
    assert(path && userPath); return !executableAllowed;
}
#define JBROOT_PATH(path) testRootPath(path)
'''

SWITCH_PATH_TYPE = r'''
#undef JBROOT_PATH
#define JBROOT_PATH(path) testCStringPath(path)
'''

MAIN = r'''
static NSString *configPath(NSString *name) {
    return [testRootPath(@"/var/mobile/Library/RootHide") stringByAppendingPathComponent:name];
}
static void cleanConfiguration(void) {
    NSString *path = testRootPath(@"/var/mobile/Library/RootHide");
    if ([NSFileManager.defaultManager fileExistsAtPath:path])
        assert([NSFileManager.defaultManager removeItemAtPath:path error:nil]);
    assert([NSFileManager.defaultManager createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:nil error:nil]);
}
int main(void) {
    @autoreleasepool {
        testRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rc9-injection-defaults-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert([NSFileManager.defaultManager createDirectoryAtPath:testRoot
            withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *mode = configPath(@"cn.zqbb.inject.plist");
        NSString *system = configPath(@"cn.zqbb.inject.system.plist");
        NSString *blacklist = configPath(@"cn.zqbb.inject.wantsblacklist.plist");
        NSString *jetsam = configPath(@"cn.zqbb.jetsam.addend.plist");
        NSString *marker = configPath(@".rc9-system-whitelist-migration-v1");

        initializeRootHideWhitelistDefaults();
        assert([NSFileManager.defaultManager fileExistsAtPath:system]);
        assert([NSFileManager.defaultManager fileExistsAtPath:blacklist]);
        assert([NSFileManager.defaultManager fileExistsAtPath:jetsam]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:mode]);
        assert(!isBlacklistedPath(NULL));
        assert(!isBlacklistedPath("/app/Allowed"));
        assert(isBlacklistedPath("/app/Blacklisted"));
        initializeRootHideWhitelistDefaults();
        assert(![NSFileManager.defaultManager fileExistsAtPath:mode]);

        assert([@{} writeToFile:mode atomically:YES]);
        NSData *emptyMode = [NSData dataWithContentsOfFile:mode];
        initializeRootHideWhitelistDefaults();
        assert([[NSData dataWithContentsOfFile:mode] isEqual:emptyMode]);
        assert(isBlacklistedPath("/app/Allowed"));
        assert(!isBlacklistedPath("/sbin/launchd"));
        systemAllowed = true;
        assert(!isBlacklistedPath("/system/Allowed"));
        systemAllowed = false; executableAllowed = true;
        assert(!isBlacklistedPath("/app/Allowed"));
        executableAllowed = false;

        NSDictionary *choices = @{@"Allowed": @YES, @"Disabled": @NO};
        assert([choices writeToFile:mode atomically:YES]);
        NSData *savedMode = [NSData dataWithContentsOfFile:mode];
        initializeRootHideWhitelistDefaults();
        assert([[NSData dataWithContentsOfFile:mode] isEqual:savedMode]);

        NSData *invalid = [@"not a plist" dataUsingEncoding:NSUTF8StringEncoding];
        assert([invalid writeToFile:mode atomically:YES]);
        initializeRootHideWhitelistDefaults();
        assert([[NSData dataWithContentsOfFile:mode] isEqual:invalid]);
        assert(isBlacklistedPath("/app/Allowed")); /* Existence, not plist validity, selects mode. */

        cleanConfiguration();
        NSDictionary *systemChoices = @{ @"/SpringBoard": @NO,
            @"/usr/libexec/dasd": @NO, @"/custom": @YES };
        NSDictionary *blacklistChoices = @{@"WeChat": @NO};
        NSDictionary *jetsamChoices = @{@"/SpringBoard": @256};
        assert([systemChoices writeToFile:system atomically:YES]);
        assert([blacklistChoices writeToFile:blacklist atomically:YES]);
        assert([jetsamChoices writeToFile:jetsam atomically:YES]);
        assert([choices writeToFile:mode atomically:YES]);
        savedMode = [NSData dataWithContentsOfFile:mode];
        initializeRootHideWhitelistDefaults();
        NSDictionary *merged = [NSDictionary dictionaryWithContentsOfFile:system];
        assert([merged[@"/SpringBoard"] isEqual:@NO]);
        assert([merged[@"/usr/libexec/dasd"] isEqual:@NO]);
        assert([merged[@"/custom"] isEqual:@YES]);
        assert([merged[@"/lockdownd"] isEqual:@YES]);
        assert([merged[@"/MobileStorageMounter"] isEqual:@YES]);
        assert([[NSDictionary dictionaryWithContentsOfFile:blacklist] isEqual:blacklistChoices]);
        assert([[NSDictionary dictionaryWithContentsOfFile:jetsam] isEqual:jetsamChoices]);
        assert([[NSData dataWithContentsOfFile:mode] isEqual:savedMode]);
        assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
        NSMutableDictionary *userEdited = [merged mutableCopy];
        [userEdited removeObjectForKey:@"/lockdownd"];
        assert([userEdited writeToFile:system atomically:YES]);
        initializeRootHideWhitelistDefaults();
        assert(![NSDictionary dictionaryWithContentsOfFile:system][@"/lockdownd"]);

        cleanConfiguration();
        assert([invalid writeToFile:system atomically:YES]);
        initializeRootHideWhitelistDefaults();
        assert([[NSData dataWithContentsOfFile:system] isEqual:invalid]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:marker]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:mode]);
        assert(!isBlacklistedPath("/app/Allowed"));
        assert(isBlacklistedPath("/app/Blacklisted"));

        free((void *)injectPlistPath); free((void *)injectSystemPlistPath);
        assert([NSFileManager.defaultManager removeItemAtPath:testRoot error:nil]);
        puts("PASS: production initializer defaults to blacklist and preserves existing whitelist, explicit NO and corrupt user data");
    }
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    jailbreaker = source(JAILBREAKER)
    code = "\n".join((
        PREFIX,
        *(extract(jailbreaker, anchor) for anchor in (
            "static NSArray<NSString *> *rc9RequiredSystemWhitelistItems(",
            "static void rc9MigrateSystemWhitelist(",
            "static void initializeRootHideWhitelistDefaults(",
        )),
        SWITCH_PATH_TYPE,
        extract(source(BLACKLIST), "bool isBlacklistedPath("),
        MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-injection-defaults-") as tmp:
        path = Path(tmp) / "defaults.m"
        binary = Path(tmp) / "defaults-test"
        path.write_text(code, encoding="utf-8")
        subprocess.run([compiler, "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                        "-Werror", "-Wno-unused-parameter", "-O1", "-g",
                        "-fsanitize=address,undefined", "-framework", "Foundation",
                        str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    suite = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(case)
        for case in (InjectionDefaultContracts, VerboseLogContracts))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
