"""Daily low-power schedule contracts and macOS Foundation/mock regressions.

--native compiles the actual scheduler. It is not iOS device validation.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


ROOT = Path(__file__).resolve().parents[1]
HEADER = "BaseBin/roothidehooks/RCLowPowerSchedule.h"
RUNTIME = "BaseBin/roothidehooks/lowpowerschedule.m"
CONTROLLER = "Application/Dopamine/UI/Settings/DOLowPowerScheduleController.m"


class LowPowerScheduleContracts(unittest.TestCase):
    def test_springboard_not_app_lifetime_runs_schedule(self):
        self.assertIn("rcLowPowerScheduleStart();",
                      extract(source("BaseBin/roothidehooks/springboard.x"), "void sbInit(void)"))
        text = source(RUNTIME)
        self.assertIn("jbclient_get_jbroot()", text)
        self.assertIn('NSClassFromString(@"PCPersistentTimer")', text)
        self.assertIn("[timer setDisableSystemWaking:NO]", text)
        self.assertIn("[timer setEarlyFireConstantInterval:0.0]", text)
        self.assertIn("[timer setMinimumEarlyFireProportion:0.0]", text)
        self.assertIn("[timer isValid]", text)
        self.assertNotIn("NSTimer", text)
        self.assertNotIn("sleep(", text)
        self.assertNotIn("dispatch_source_create", text)

    def test_private_calls_are_guarded_and_exceptions_contained(self):
        api = extract(source(RUNTIME), "static BOOL rcLowPowerAPIsAvailable")
        for selector in ("sharedInstance", "setPowerMode:fromSource:",
                         "initWithFireDate:serviceIdentifier:target:selector:userInfo:",
                         "setDisableSystemWaking:", "setUserVisible:",
                         "setMinimumEarlyFireProportion:", "setEarlyFireConstantInterval:",
                         "scheduleInRunLoop:", "invalidate", "isValid"):
            self.assertIn(f"@selector({selector})", api)
        self.assertIn(')), "Bc", "q@")', api)
        refresh = extract(source(RUNTIME), "- (void)refresh\n")
        self.assertIn("@try", refresh)
        self.assertIn("@catch", refresh)
        self.assertLess(refresh.index("rcLowPowerAPIsAvailable()"),
                        refresh.index("setPowerMode:"))
        self.assertLess(refresh.index("armForDate:next"), refresh.index("setPowerMode:"))

    def test_defaults_are_disabled_midnight_to_six_and_inputs_strict(self):
        defaults = extract(source(HEADER), "static inline NSDictionary *rcLowPowerDefaultConfiguration")
        for value in ('@"Enabled": @NO', '@"StartMinute": @0', '@"EndMinute": @360'):
            self.assertIn(value, defaults)
        validation = extract(source(HEADER), "static inline BOOL rcLowPowerConfigurationValid")
        self.assertIn("CFBooleanGetTypeID()", validation)
        self.assertIn("initWithUUIDString:", validation)
        self.assertIn("rcLowPowerMinuteValid", validation)
        self.assertIn('![configuration[@"StartMinute"] isEqual:configuration[@"EndMinute"]]', validation)

    def test_calendar_handles_local_time_without_fixed_daily_seconds(self):
        text = source(HEADER)
        event = extract(text, "static inline NSDate *rcLowPowerDateForMinute")
        event += extract(text, "static inline NSDictionary *rcLowPowerEvent")
        for token in ("NSCalendarMatchNextTime", "NSCalendarMatchFirst",
                      "dateFromComponents:", "dateByAddingUnit:", "matchingComponents:"):
            self.assertIn(token, event)
        self.assertNotIn("86400", event)
        self.assertIn("NSTimeZone.localTimeZone", text)
        runtime = source(RUNTIME)
        self.assertIn("NSSystemClockDidChangeNotification", runtime)
        self.assertIn("NSSystemTimeZoneDidChangeNotification", runtime)

    def test_disable_and_manual_override_do_not_force_state_repeatedly(self):
        refresh = extract(source(RUNTIME), "- (void)refresh\n")
        disabled = extract(refresh, 'if (![configuration[@"Enabled"] boolValue])')
        self.assertIn('publishStatus:@"disabled"', disabled)
        self.assertNotIn("setPowerMode", disabled)
        self.assertIn("if (![self.lastHandled isEqual:event])", refresh)
        self.assertIn('saved[@"LastHandled"]', refresh)
        self.assertIn("self.retryCount < 4", refresh)
        self.assertIn("self.retryAfter", refresh)
        self.assertNotIn("toggle", refresh.replace("// Idempotent set, never toggle.", ""))

    def test_shared_storage_atomic_bounded_and_not_global_preferences(self):
        header = source(HEADER)
        self.assertIn("NSDataWritingAtomic", header)
        self.assertIn("NSDataWritingFileProtectionNone", header)
        self.assertIn("NSFilePosixPermissions: @0600", header)
        self.assertIn("> 16384", header)
        self.assertNotIn("CFPreferencesSet", header)
        environment = source("Application/Dopamine/Jailbreak/DOEnvironmentManager.m")
        save = extract(environment, "- (BOOL)saveLowPowerScheduleEnabled:")
        self.assertIn("!self.isJailbroken", save)
        self.assertIn("rcLowPowerConfigurationValid(configuration)", save)
        self.assertIn("runUnsandboxed:", save)
        self.assertIn("if (success) notify_post(RC_LOW_POWER_CHANGED)", save)
        self.assertNotIn("runAsRoot:", save)

    def test_settings_page_is_wired_and_waits_for_runtime_ack(self):
        settings = source("Application/Dopamine/UI/Settings/DOSettingsController.m")
        self.assertIn('@"lowPowerSchedulePressed"', settings)
        self.assertIn("pushViewController:[DOLowPowerScheduleController new]", settings)
        project = source("Application/Dopamine.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("DOLowPowerScheduleController.m in Sources"), 2)
        ui = source(CONTROLLER)
        for token in ("UIDatePickerModeTime", "UIDatePickerStyleCompact", "UISwitch",
                      "start == end", "self.hasChanges", "notify_cancel(self.statusToken)",
                      "RC_LOW_POWER_QUERY", "LowPowerSchedule_Waiting"):
            self.assertIn(token, ui)
        self.assertIn('status[@"Revision"] isEqual:self.savedConfiguration[@"Revision"]', ui)
        self.assertNotIn("setPowerMode:", ui)

    def test_all_new_localization_keys_exist_in_english_and_simplified_chinese(self):
        keys = set(re.findall(r'@"(LowPowerSchedule_\w+)"', source(CONTROLLER)))
        keys.add("LowPowerSchedule_Title")
        for language in ("en", "zh-CN", "zh-Hans"):
            text = source(f"Application/Dopamine/{language}.lproj/Localizable.strings")
            for key in keys:
                self.assertEqual(len(re.findall(rf'^"{key}"\s*=', text, re.M)), 1, (language, key))

    def test_native_regression_is_in_existing_ci(self):
        self.assertIn("python3 tests/test_rc9_low_power_schedule.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

static NSString *testRoot, *missingClass;
static NSDate *testNow;
static NSUInteger powerCalls;
static long long powerMode;
static BOOL acceptsPower = YES, throwsPower, timerFails;
static const char *jbclient_get_jbroot(void) { return testRoot.UTF8String; }
static NSDate *rcLowPowerTestNow(void) { return testNow; }
static Class testClass(NSString *name) {
    return [missingClass isEqual:name] ? Nil : NSClassFromString(name);
}

@interface _PMLowPowerMode : NSObject
+ (instancetype)sharedInstance;
- (bool)setPowerMode:(long long)mode fromSource:(id)source;
@end
@implementation _PMLowPowerMode
+ (instancetype)sharedInstance { static id instance; if (!instance) instance = [self new]; return instance; }
- (bool)setPowerMode:(long long)mode fromSource:(id)source {
    (void)source;
    powerCalls++;
    if (throwsPower) [NSException raise:@"MockPowerError" format:@"boundary exception"];
    if (acceptsPower) powerMode = mode;
    return acceptsPower;
}
@end

@interface PCPersistentTimer : NSObject
@property(nonatomic, strong) NSDate *date;
@property(nonatomic, strong) id target;
@property(nonatomic) bool disableSystemWaking;
@property(nonatomic) bool userVisible;
@property(nonatomic) double minimumEarlyFireProportion;
@property(nonatomic) double earlyFireConstantInterval;
@property(nonatomic) bool valid;
- (instancetype)initWithFireDate:(id)date serviceIdentifier:(id)identifier
    target:(id)target selector:(SEL)selector userInfo:(id)userInfo;
- (void)scheduleInRunLoop:(id)runLoop;
- (void)invalidate;
- (bool)isValid;
@end
@implementation PCPersistentTimer
- (instancetype)initWithFireDate:(id)date serviceIdentifier:(id)identifier
    target:(id)target selector:(SEL)selector userInfo:(id)userInfo {
    (void)identifier; (void)selector; (void)userInfo;
    if ((self = [super init])) { self.date = date; self.target = target; }
    return self;
}
- (void)scheduleInRunLoop:(id)runLoop { (void)runLoop; self.valid = !timerFails; }
- (void)invalidate { self.valid = NO; self.target = nil; }
- (bool)isValid { return self.valid; }
@end

#define RC_LOW_POWER_TEST 1
#define NSClassFromString testClass
#include "lowpowerschedule.m"
#undef NSClassFromString

static NSDate *date(NSString *value) {
    NSDate *result = [[NSISO8601DateFormatter new] dateFromString:value];
    assert(result); return result;
}
static NSDictionary *configuration(BOOL enabled, NSInteger start, NSInteger end) {
    return @{@"Version": @1, @"Enabled": @(enabled), @"StartMinute": @(start),
        @"EndMinute": @(end), @"Revision": NSUUID.UUID.UUIDString};
}
static void save(NSDictionary *value) {
    assert(rcLowPowerWriteDictionary(value, rcLowPowerConfigurationPath(testRoot), nil));
}
static void statusIs(NSString *state) {
    assert([rcLowPowerReadDictionary(rcLowPowerStatusPath(testRoot))[@"State"] isEqual:state]);
}
static void checkEvent(NSDictionary *plan, NSString *instant, BOOL next,
                       NSString *expected, BOOL mode, NSCalendar *calendar) {
    NSDictionary *event = rcLowPowerEvent(plan, date(instant), calendar, next);
    assert([event[@"Date"] isEqual:date(expected)]);
    assert([event[@"PowerMode"] boolValue] == mode);
}
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    testRoot = [temporary stringByAppendingPathComponent:@".jbroot-12345678"];
    [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    testNow = date(@"2026-11-04T01:00:00Z");
    assert(rcLowPowerConfigurationValid(rcLowPowerDefaultConfiguration()));
    assert(![rcLowPowerDefaultConfiguration()[@"Enabled"] boolValue]);
    assert(!rcLowPowerConfigurationPath(nil));
    assert(!rcLowPowerConfigurationPath(@""));
    assert(!rcLowPowerConfigurationPath(@"relative"));
    assert(!rcLowPowerConfigurationPath(@"/"));
    assert(!rcLowPowerMinuteValid(@YES));
    assert(!rcLowPowerMinuteValid(@"12"));
    assert(!rcLowPowerMinuteValid(@(-1)));
    assert(!rcLowPowerMinuteValid(@1440));
    assert(!rcLowPowerMinuteValid(@1.5));
    assert(!rcLowPowerConfigurationValid(@[]));
    assert(!rcLowPowerConfigurationValid(configuration(YES, 5, 5)));
    NSMutableDictionary *bad = [configuration(YES, 0, 360) mutableCopy];
    bad[@"Enabled"] = @1; assert(!rcLowPowerConfigurationValid(bad));
    bad[@"Enabled"] = @YES; bad[@"Revision"] = @"x"; assert(!rcLowPowerConfigurationValid(bad));
    bad[@"Revision"] = NSUUID.UUID.UUIDString; bad[@"Version"] = @YES;
    assert(!rcLowPowerConfigurationValid(bad));
    NSCalendar *calendar = rcLowPowerLocalCalendar();
    for (NSArray *pair in @[@[@0, @360], @[@1380, @360], @[@360, @1080], @[@145, @777]]) {
        NSInteger start = [pair[0] integerValue], end = [pair[1] integerValue];
        NSDictionary *plan = configuration(YES, start, end);
        for (NSInteger minute = 0; minute < 1440; minute++) {
            NSDate *now = [date(@"2026-11-04T00:00:00Z") dateByAddingTimeInterval:minute * 60];
            NSDictionary *event = rcLowPowerEvent(plan, now, calendar, NO);
            BOOL expected = start < end ? (minute >= start && minute < end) :
                                         (minute >= start || minute < end);
            assert([event[@"PowerMode"] boolValue] == expected);
            assert([event[@"Date"] compare:now] != NSOrderedDescending);
            assert([rcLowPowerEvent(plan, now, calendar, YES)[@"Date"] compare:now] == NSOrderedDescending);
        }
    }
    NSDictionary *plan = configuration(YES, 0, 360);
    checkEvent(plan, @"2026-11-04T00:00:00Z", NO, @"2026-11-04T00:00:00Z", YES, calendar);
    checkEvent(plan, @"2026-11-04T06:00:00Z", NO, @"2026-11-04T06:00:00Z", NO, calendar);
    checkEvent(plan, @"2026-11-04T06:00:00Z", YES, @"2026-11-05T00:00:00Z", YES, calendar);
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"];
    NSDictionary *dst = configuration(YES, 150, 360);
    checkEvent(dst, @"2026-03-08T06:59:00Z", YES, @"2026-03-08T07:00:00Z", YES, calendar);
    checkEvent(dst, @"2026-03-08T07:01:00Z", NO, @"2026-03-08T07:00:00Z", YES, calendar);
    dst = configuration(YES, 90, 180);
    checkEvent(dst, @"2026-11-01T05:29:00Z", YES, @"2026-11-01T05:30:00Z", YES, calendar);
    checkEvent(dst, @"2026-11-01T06:35:00Z", NO, @"2026-11-01T05:30:00Z", YES, calendar);
    checkEvent(dst, @"2026-11-01T05:35:00Z", YES, @"2026-11-01T08:00:00Z", NO, calendar);

    assert(rcLowPowerAPIsAvailable());
    for (NSString *name in @[@"_PMLowPowerMode", @"PCPersistentTimer"]) {
        missingClass = name; assert(!rcLowPowerAPIsAvailable());
    }
    missingClass = nil;
    Method method = class_getInstanceMethod(_PMLowPowerMode.class, @selector(setPowerMode:fromSource:));
    assert(!rcLowPowerMethodMatches(method, "v", "q@"));
    assert(!rcLowPowerMethodMatches(method, "Bc", "@@"));
    assert(!rcLowPowerMethodMatches(method, "Bc", "q"));
    assert(!rcLowPowerMethodMatches(NULL, "Bc", "q@"));
    RCLowPowerScheduler *scheduler = [RCLowPowerScheduler new];
    [scheduler refresh]; statusIs(@"disabled"); assert(powerCalls == 0 && !scheduler.timer);
    save(plan); [scheduler refresh];
    statusIs(@"scheduled"); assert(powerCalls == 1 && powerMode == 1);
    PCPersistentTimer *timer = (id)scheduler.timer;
    assert(!timer.disableSystemWaking && timer.userVisible);
    assert(timer.minimumEarlyFireProportion == 0 && timer.earlyFireConstantInterval == 0);
    assert([timer.date isEqual:date(@"2026-11-04T06:00:00Z")]);
    [scheduler refresh]; assert(powerCalls == 1);
    powerMode = 0; // Manual override survives refresh and a new scheduler instance.
    [scheduler.timer invalidate];
    scheduler = [RCLowPowerScheduler new];
    [scheduler refresh]; assert(powerCalls == 1 && powerMode == 0);
    testNow = date(@"2026-11-04T06:00:00Z");
    [scheduler refresh]; assert(powerCalls == 2 && powerMode == 0);
    testNow = date(@"2026-11-05T01:00:00Z"); // Only catch up the latest event.
    [scheduler refresh]; assert(powerCalls == 3 && powerMode == 1);
    timer = (id)scheduler.timer;
    save(configuration(NO, 0, 360));
    [scheduler refresh]; statusIs(@"disabled");
    assert(powerCalls == 3 && powerMode == 1 && !scheduler.timer && !timer.valid);
    [scheduler timerFired:timer]; assert(powerCalls == 3 && !scheduler.timer);

    save(configuration(YES, 0, 360));
    timerFails = YES; [scheduler refresh]; statusIs(@"timerFailed");
    assert(powerCalls == 3 && !scheduler.timer);
    timerFails = NO;
    missingClass = @"PCPersistentTimer"; [scheduler refresh]; statusIs(@"unsupported");
    assert(powerCalls == 3 && !scheduler.timer); missingClass = nil;
    acceptsPower = NO;
    [scheduler refresh]; statusIs(@"applyFailed"); assert(powerCalls == 4);
    for (int count = 0; count < 10; count++) [scheduler refresh];
    assert(powerCalls == 4); // UI status queries cannot spend the retry budget.
    for (int count = 1; count <= 3; count++) {
        testNow = [testNow dateByAddingTimeInterval:60 * count];
        [scheduler refresh];
    }
    assert(powerCalls == 7);
    testNow = [testNow dateByAddingTimeInterval:900];
    [scheduler refresh]; assert(powerCalls == 7);
    assert([((PCPersistentTimer *)scheduler.timer).date isEqual:date(@"2026-11-05T06:00:00Z")]);
    acceptsPower = YES;
    testNow = date(@"2026-11-05T06:00:00Z"); [scheduler refresh];
    statusIs(@"scheduled"); assert(powerCalls == 8 && powerMode == 0);
    throwsPower = YES; save(configuration(YES, 0, 360));
    [scheduler refresh]; statusIs(@"runtimeFailed"); assert(!scheduler.timer);
    throwsPower = NO;
    save(@{@"Enabled": @YES}); [scheduler refresh]; statusIs(@"invalidConfiguration");
    assert(!scheduler.timer);
    assert([@"not a plist" writeToFile:rcLowPowerConfigurationPath(testRoot)
        atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    [scheduler refresh]; statusIs(@"invalidConfiguration"); assert(!scheduler.timer);

    testRoot = [temporary stringByAppendingPathComponent:@".jbroot-87654321"];
    save(configuration(YES, 1380, 360)); testNow = date(@"2026-11-05T23:00:00Z");
    [scheduler refresh]; statusIs(@"scheduled"); assert(powerMode == 1);
    [scheduler.timer invalidate]; scheduler.timer = nil;
    NSString *blocker = [temporary stringByAppendingPathComponent:@"blocker"];
    assert([@"x" writeToFile:blocker atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!rcLowPowerWriteDictionary(plan, [blocker stringByAppendingPathComponent:@"plan"], nil));
    assert(!rcLowPowerWriteDictionary(plan, nil, nil));
    assert([fm removeItemAtPath:temporary error:nil]);
    puts("PASS: actual daily schedule, all local minutes, DST, validation, atomic storage, ABI guards, mocked wake timers/power, manual override, respring, disable, retry bounds and failure containment");
} return 0; }
'''


def native_tests():
    clang = shutil.which("clang")
    if sys.platform != "darwin" or not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    with tempfile.TemporaryDirectory(prefix="rc9-low-power-") as directory:
        path = Path(directory) / "schedule.m"
        binary = Path(directory) / "schedule"
        path.write_text(NATIVE, encoding="utf-8")
        subprocess.run([
            clang, "-fobjc-arc", "-fblocks", "-framework", "Foundation",
            "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
            "-O1", "-g", "-fsanitize=address,undefined",
            "-I", str(ROOT / "BaseBin/roothidehooks"), str(path), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(LowPowerScheduleContracts),
    )
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.native:
        native_tests()
    else:
        print("Source checks only; --native runs the real scheduler with macOS boundary mocks, not iOS.")
