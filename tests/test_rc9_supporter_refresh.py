"""Idempotent license self-healing; not Security, UIKit, or device testing.

The macOS harness executes production helpers with Foundation containers and
counted persistence/verifier boundaries. It does not replace the app verifier.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_release_contracts import LICENSE, body
from test_rc9_services import extract, source


class SupporterRefreshContracts(unittest.TestCase):
    def test_equal_nonempty_state_does_not_rewrite_the_file(self):
        setter = body(LICENSE, "DORHSupporterSetPersistentString")
        same = extract(setter, "if ([state[key] isEqual:value])")
        self.assertIn("return YES;", same)
        self.assertLess(setter.index(same),
                        setter.index("DORHSupporterWritePersistentState(state)"))
        self.assertNotIn("state[key] == nil", setter)

    def test_defaults_sync_is_only_needed_for_a_changed_verified_license(self):
        current = body(LICENSE, "DORHSupporterCurrentLicenseInfo")
        changed = extract(
            current, "if (![[defaults stringForKey:DORHSupporterLicenseDefaultsKey]")
        self.assertIn("isEqualToString:license", changed)
        self.assertIn("[defaults setObject:license", changed)
        self.assertIn("[defaults synchronize];", changed)
        self.assertEqual(current.count("synchronize]"), 1)
        self.assertLess(current.index("if (!info)"), current.index(changed))

    def test_each_refresh_still_checks_removal_and_verifies_the_candidate(self):
        current = body(LICENSE, "DORHSupporterCurrentLicenseInfo")
        self.assertLess(current.index("DORHSupporterLicenseTombstoned()"),
                        current.index("DORHSupporterVerifyLicenseCode("))
        for cache in ("dispatch_once", "cachedLicense", "cachedVerified", "NSTimer"):
            self.assertNotIn(cache, current)

    def test_ci_runs_native_counted_self_healing_regression(self):
        self.assertIn("python3 tests/test_rc9_supporter_refresh.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

static NSString *const DORHSupporterPersistentLicenseCodeKey = @"LicenseCode";
static NSString *const DORHSupporterPersistentLicenseRemovedKey = @"LicenseRemoved";
static NSString *const DORHSupporterLicenseDefaultsKey = @"DORHSupporter.LicenseCode";
static NSMutableDictionary *persistentState;
static NSUInteger fileWrites, verifications;
static BOOL failWrites;

@interface RC9TestDefaults : NSObject
@property(nonatomic, strong) NSMutableDictionary *values;
@property(nonatomic) NSUInteger sets, removals, synchronizations;
+ (instancetype)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (BOOL)synchronize;
@end

static RC9TestDefaults *testDefaults;

@implementation RC9TestDefaults
+ (instancetype)standardUserDefaults { return testDefaults; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (NSString *)stringForKey:(NSString *)key {
    id value = self.values[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}
- (void)setObject:(id)value forKey:(NSString *)key {
    self.sets++;
    self.values[key] = value;
}
- (void)removeObjectForKey:(NSString *)key {
    self.removals++;
    [self.values removeObjectForKey:key];
}
- (BOOL)synchronize { self.synchronizations++; return YES; }
@end

#define NSUserDefaults RC9TestDefaults

static NSMutableDictionary<NSString *, id> *DORHSupporterReadPersistentState(void)
{
    return [persistentState mutableCopy];
}

static BOOL DORHSupporterWritePersistentState(NSDictionary<NSString *, id> *state)
{
    fileWrites++;
    if (failWrites) return NO;
    persistentState = [state mutableCopy];
    return YES;
}

static NSDictionary *DORHSupporterVerifyLicenseCode(NSString *code, NSError **error)
{
    (void)error;
    verifications++;
    return [code hasPrefix:@"verified-"] ? @{@"sid": code} : nil;
}
'''

NATIVE_MAIN = r'''
static void reset(NSDictionary *state, id defaultsLicense)
{
    persistentState = [state mutableCopy];
    testDefaults = [RC9TestDefaults new];
    testDefaults.values = [@{@"unrelated": @"keep"} mutableCopy];
    if (defaultsLicense)
        testDefaults.values[DORHSupporterLicenseDefaultsKey] = defaultsLicense;
    fileWrites = verifications = 0;
    failWrites = NO;
}

static void assertOtherState(void)
{
    assert([persistentState[@"DeviceCode"] isEqual:@"same-device"]);
    assert(([persistentState[@"unrelated"] isEqual:@[@1, @2]]));
    assert([testDefaults.values[@"unrelated"] isEqual:@"keep"]);
}

int main(void)
{
    @autoreleasepool {
        NSDictionary *identity = @{
            @"DeviceCode": @"same-device", @"unrelated": @[@1, @2]
        };
        NSMutableDictionary *licensed = [identity mutableCopy];
        licensed[@"LicenseCode"] = @"verified-A";
        licensed[@"LicenseRemoved"] = @NO;

        reset(licensed, @"verified-A");
        for (NSUInteger i = 0; i < 1000; i++)
            assert(DORHSupporterCurrentLicenseInfo());
        assert(verifications == 1000);
        assert(fileWrites == 0 && testDefaults.sets == 0);
        assert(testDefaults.synchronizations == 0);
        assertOtherState();

        reset(licensed, nil);
        assert(DORHSupporterCurrentLicenseInfo());
        assert(DORHSupporterCurrentLicenseInfo());
        assert(verifications == 2 && fileWrites == 0);
        assert(testDefaults.sets == 1 && testDefaults.synchronizations == 1);
        assertOtherState();

        reset(identity, @"verified-B");
        assert(DORHSupporterCurrentLicenseInfo());
        assert(DORHSupporterCurrentLicenseInfo());
        assert(verifications == 2 && fileWrites == 1);
        assert(testDefaults.sets == 0 && testDefaults.synchronizations == 0);
        assert([persistentState[@"LicenseCode"] isEqual:@"verified-B"]);
        assertOtherState();

        reset(licensed, @"verified-B");
        assert([DORHSupporterCurrentLicenseInfo()[@"sid"] isEqual:@"verified-A"]);
        assert(fileWrites == 0 && testDefaults.sets == 1);
        assert(testDefaults.synchronizations == 1);
        assert([testDefaults stringForKey:DORHSupporterLicenseDefaultsKey]
            && [[testDefaults stringForKey:DORHSupporterLicenseDefaultsKey]
                isEqual:@"verified-A"]);
        assertOtherState();

        NSMutableDictionary *invalid = [identity mutableCopy];
        invalid[@"LicenseCode"] = @"invalid";
        reset(invalid, @"verified-B");
        assert(DORHSupporterCurrentLicenseInfo());
        assert(verifications == 2 && fileWrites == 1);
        assert(testDefaults.sets == 0 && testDefaults.synchronizations == 0);
        assertOtherState();

        reset(invalid, @"invalid-default");
        assert(!DORHSupporterCurrentLicenseInfo());
        assert(verifications == 2 && fileWrites == 0);
        assert(testDefaults.sets == 0 && testDefaults.synchronizations == 0);
        assertOtherState();

        NSMutableDictionary *removed = [licensed mutableCopy];
        removed[@"LicenseRemoved"] = @YES;
        reset(removed, @"verified-B");
        assert(!DORHSupporterCurrentLicenseInfo());
        assert(!DORHSupporterCurrentLicenseInfo());
        assert(verifications == 0 && fileWrites == 0);
        assert(testDefaults.removals == 1 && testDefaults.synchronizations == 1);
        assert([persistentState[@"LicenseRemoved"] boolValue]);
        assertOtherState();

        reset(identity, @"verified-B");
        failWrites = YES;
        assert(DORHSupporterCurrentLicenseInfo());
        assert(DORHSupporterCurrentLicenseInfo());
        assert(fileWrites == 2 && !persistentState[@"LicenseCode"]);
        failWrites = NO;
        assert(DORHSupporterCurrentLicenseInfo());
        assert(DORHSupporterCurrentLicenseInfo());
        assert(fileWrites == 3 && verifications == 4);
        assert(testDefaults.synchronizations == 0);
        assertOtherState();

        reset(identity, nil);
        assert(!DORHSupporterCurrentLicenseInfo());
        assert(verifications == 0 && fileWrites == 0);
        assert(DORHSupporterSetPersistentString(@"missing", nil));
        assert(fileWrites == 1);
        assert(DORHSupporterSetPersistentString(@"test", @"value"));
        assert(fileWrites == 2);
        assert(DORHSupporterSetPersistentString(@"test", @"value"));
        assert(fileWrites == 2);
        failWrites = YES;
        assert(!DORHSupporterSetPersistentString(@"test", @"changed"));
        assert(fileWrites == 3 && [persistentState[@"test"] isEqual:@"value"]);
        failWrites = NO;
        assert(DORHSupporterSetPersistentString(@"test", @""));
        assert(fileWrites == 4 && !persistentState[@"test"]);
        assert(DORHSupporterSetPersistentString(@"test", nil));
        assert(fileWrites == 5);
        persistentState[@"test"] = @42;
        assert(DORHSupporterSetPersistentString(@"test", @"42"));
        assert(fileWrites == 6 && [persistentState[@"test"] isKindOfClass:NSString.class]);
        assertOtherState();

        puts("PASS: production license self-healing skips unchanged writes; "
             "verification, tombstones, migration and failed-write retries preserved. "
             "Persistence/verifier boundaries substituted; not Security or UIKit.");
    }
    return 0;
}
'''


def native_tests():
    if sys.platform != "darwin":
        raise SystemExit("--native requires macOS Foundation; no native tests were run")
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang")
    helpers = "\n".join(body(LICENSE, name) for name in (
        "DORHSupporterPersistentString",
        "DORHSupporterSetPersistentString",
        "DORHSupporterLicenseTombstoned",
        "DORHSupporterPurgeDefaultsLicense",
        "DORHSupporterCurrentLicenseInfo",
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-supporter-refresh-") as directory:
        path = Path(directory) / "refresh.m"
        binary = Path(directory) / "refresh-test"
        path.write_text("\n".join((NATIVE_PREFIX, helpers, NATIVE_MAIN)),
                        encoding="utf-8")
        subprocess.run([compiler, "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-O1", "-g", "-fsanitize=address,undefined",
                        "-framework", "Foundation", str(path), "-o", str(binary)],
                       check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SupporterRefreshContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.native:
        native_tests()
    else:
        print("Source contracts only; native Foundation regression requires macOS.")
