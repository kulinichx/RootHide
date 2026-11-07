"""Hosted Jetsam navigation contracts and production callback boundary tests.

The native test uses Foundation and the actual settings getter/setter and
preference store. Navigation and Preferences controllers are counted doubles:
this does not execute private Preferences selection code or UIKit on iOS.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import ROOT, extract, source


SETTINGS = "Application/Dopamine/UI/Settings/DOSettingsController.m"


class JetsamNavigationContracts(unittest.TestCase):
    def test_values_are_bound_to_the_original_specifier_without_parent_lookup(self):
        text = source(SETTINGS)
        block = text.split("PSSpecifier *jetsamSpecifier =", 1)[1].split(
            "[specifiers addObject:jetsamSpecifier];", 1)[0]
        self.assertIn(
            "[jetsamSpecifier setValues:[self jetsamOptionNumbers] "
            "titles:[self jetsamOptionTitles]];", block)
        self.assertNotIn("valuesDataSource", block)
        self.assertNotIn("titlesDataSource", block)
        self.assertIn('setProperty:@6 forKey:@"default"', block)
        self.assertIn("setJetsamMultiplier:specifier:", block)
        self.assertIn("readJetsamMultiplier:", block)

    def test_native_preferences_owner_is_bound_before_the_navigation_push(self):
        body = extract(source(SETTINGS), "- (BOOL)pushJetsamController:")
        self.assertIn("isKindOfClass:DOPSJetsamListItemsController.class", body)
        self.assertIn("!self.navigationController", body)
        push = body.index("pushViewController:items animated:animated")
        self.assertLess(body.index("[items setParentController:self]"), push)
        self.assertLess(
            body.index("[items setRootController:[self rootController] ?: self]"), push)
        for token in ("contentOffset", "contentInset", ".frame", "jbclient_",
                      "setJetsamMultiplier:", "reloadSpecifiers"):
            self.assertNotIn(token, body)

    def test_both_push_selectors_keep_other_controllers_on_the_original_path(self):
        text = source(SETTINGS)
        normal = extract(text, "- (void)pushController:(id)controller\n")
        animated = extract(text, "- (void)pushController:(id)controller animate:")
        self.assertIn("pushJetsamController:controller animated:YES", normal)
        self.assertIn("[super pushController:controller]", normal)
        self.assertIn("pushJetsamController:controller animated:animated", animated)
        self.assertIn("[super pushController:controller animate:animated]", animated)

    def test_navigation_binding_does_not_replace_verified_runtime_persistence(self):
        setter = extract(source(SETTINGS), "- (void)setJetsamMultiplier:")
        self.assertLess(
            setter.index("jbclient_platform_jbsettings_set_double_verified("),
            setter.index("setPreferenceValue:value forKey:"))
        getter = extract(source(SETTINGS), "- (id)readJetsamMultiplier:")
        self.assertIn("jbclient_jbsettings_get_double_checked(", getter)
        self.assertIn("return @(-1);", getter)

    def test_ci_runs_the_production_navigation_boundary_regression(self):
        self.assertIn("python3 tests/test_rc9_jetsam_navigation.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#import "DOPreferenceManager.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static NSString *DOLocalizedString(NSString *key) { return key; }
enum { JBCLIENT_SETTINGS_ERROR_READBACK_MISMATCH = -4 };

@interface DOPreferenceManager (NavigationTest)
- (void)loadPreferences;
@end

@interface PSSpecifier : NSObject
@property(nonatomic, weak) id target;
@property(nonatomic, strong) NSArray *values;
@property(nonatomic, strong) NSArray *titles;
@property(nonatomic, strong) NSMutableDictionary *properties;
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
- (id)propertyForKey:(NSString *)key;
@end
@implementation PSSpecifier
- (instancetype)init {
    self = [super init];
    if (self) _properties = [NSMutableDictionary new];
    return self;
}
- (void)setValues:(NSArray *)values titles:(NSArray *)titles {
    self.values = values; self.titles = titles;
}
- (id)propertyForKey:(NSString *)key { return self.properties[key]; }
@end

@class TestNavigation;
@interface UIViewController : NSObject
@property(nonatomic, strong) TestNavigation *navigationController;
@end
@implementation UIViewController
@end

@interface PSListController : UIViewController
@property(nonatomic, weak) id parentController;
@property(nonatomic, strong) id rootController;
@property(nonatomic, strong) PSSpecifier *specifier;
@property(nonatomic) NSUInteger inheritedPushes;
@property(nonatomic) BOOL inheritedAnimated;
@property(nonatomic, strong) id inheritedController;
- (void)pushController:(id)controller;
- (void)pushController:(id)controller animate:(BOOL)animated;
@end
@implementation PSListController
- (void)pushController:(id)controller {
    self.inheritedPushes++; self.inheritedAnimated = YES;
    self.inheritedController = controller;
}
- (void)pushController:(id)controller animate:(BOOL)animated {
    self.inheritedPushes++; self.inheritedAnimated = animated;
    self.inheritedController = controller;
}
@end

@interface DOPSJetsamListItemsController : PSListController
@end
@implementation DOPSJetsamListItemsController
@end

// Check the objects at the push boundary, before any simulated selection.
@interface TestNavigation : NSObject
@property(nonatomic, weak) id expectedOwner;
@property(nonatomic, strong) id expectedRoot;
@property(nonatomic, strong) id topViewController;
@property(nonatomic) NSUInteger pushes;
@property(nonatomic) BOOL animated;
- (void)pushViewController:(DOPSJetsamListItemsController *)items animated:(BOOL)animated;
@end
@implementation TestNavigation
- (void)pushViewController:(DOPSJetsamListItemsController *)items animated:(BOOL)animated {
    assert(items.parentController == self.expectedOwner);
    assert(items.rootController == self.expectedRoot);
    assert(items.specifier.target == self.expectedOwner);
    self.topViewController = items;
    self.animated = animated;
    self.pushes++;
}
@end

@interface DOEnvironmentManager : NSObject
@property(nonatomic) BOOL isJailbroken;
+ (instancetype)sharedManager;
@end
@implementation DOEnvironmentManager
+ (instancetype)sharedManager {
    static DOEnvironmentManager *manager;
    if (!manager) manager = [DOEnvironmentManager new];
    return manager;
}
@end

static double liveValue;
static int applyError, readError, liveWrites, liveReads;
static int jbclient_jbsettings_get_double_checked(const char *key, double *value) {
    assert(!strcmp(key, "jetsamMultiplier") && value);
    liveReads++;
    if (readError) return readError;
    *value = liveValue;
    return 0;
}
static int jbclient_platform_jbsettings_set_double_verified(
    const char *key, double value, double *actual) {
    assert(!strcmp(key, "jetsamMultiplier") && actual);
    liveWrites++;
    if (applyError) return applyError;
    liveValue = value;
    *actual = value;
    return 0;
}

@interface DOSettingsController : PSListController
@property(nonatomic) NSUInteger errorCount;
- (NSArray *)jetsamOptionNumbers;
- (NSArray *)jetsamOptionTitles;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (id)readJetsamMultiplier:(PSSpecifier *)specifier;
- (void)setJetsamMultiplier:(id)value specifier:(PSSpecifier *)specifier;
- (BOOL)pushJetsamController:(UIViewController *)controller animated:(BOOL)animated;
- (void)presentJetsamErrorWithTitle:(NSString *)title message:(NSString *)message;
@end
@implementation DOSettingsController
- (void)presentJetsamErrorWithTitle:(NSString *)title message:(NSString *)message {
    assert(title.length && message.length);
    self.errorCount++;
}
'''


NATIVE_MAIN = r'''
static DOPSJetsamListItemsController *open_items(
    DOSettingsController *owner, PSSpecifier *specifier, BOOL explicitAnimation) {
    DOPSJetsamListItemsController *items = [DOPSJetsamListItemsController new];
    items.specifier = specifier;
    // Simulate a child arriving with the outer page as its previous owner.
    // This is a boundary input, not a claim about private Preferences internals.
    items.parentController = owner.navigationController.topViewController;
    if (explicitAnimation) [owner pushController:items animate:NO];
    else [owner pushController:items];
    assert(owner.navigationController.topViewController == items);
    assert(owner.navigationController.animated == !explicitAnimation);
    assert(owner.inheritedPushes == 0);
    return items;
}

// A stand-in for the private selection callback. The getter/setter below are
// production code, but this dispatch does not prove UIKit's actual callback path.
static void choose(DOPSJetsamListItemsController *items, NSNumber *option) {
    DOSettingsController *owner = items.parentController;
    assert([owner isKindOfClass:DOSettingsController.class]);
    assert([items.specifier.values containsObject:option]);
    [owner setJetsamMultiplier:option specifier:items.specifier];
}

int main(void) { @autoreleasepool {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"rc9-jetsam-navigation-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    assert([files createDirectoryAtPath:directory withIntermediateDirectories:NO
        attributes:nil error:&error]);
    @try {
        NSString *path = [directory stringByAppendingPathComponent:@"preferences.plist"];
        DOPreferenceManager *store = [DOPreferenceManager sharedManager];
        [store setValue:path forKey:@"preferencesPath"];
        [store loadPreferences];
        assert([store setPreferenceValue:@YES forKey:@"unrelated" error:&error]);

        DOSettingsController *owner = [DOSettingsController new];
        TestNavigation *navigation = [TestNavigation new];
        owner.navigationController = navigation;
        navigation.expectedOwner = owner;
        NSObject *host = [NSObject new];
        NSObject *existingRoot = [NSObject new];
        PSSpecifier *specifier = [PSSpecifier new];
        specifier.target = owner;
        specifier.properties[@"key"] = @"jetsamMultiplier";
        specifier.properties[@"default"] = @6;
        // Use the same production specifier binding statement as the settings page.
        BIND_JETSAM_VALUES
        assert(([specifier.values isEqual:@[@2, @3, @4, @5, @6, @7, @8]]));
        assert(specifier.titles.count == specifier.values.count);

        for (NSUInteger running = 0; running < 2; running++) {
            [DOEnvironmentManager sharedManager].isJailbroken = running != 0;
            for (NSUInteger hasRoot = 0; hasRoot < 2; hasRoot++) {
                owner.rootController = hasRoot ? existingRoot : nil;
                navigation.expectedRoot = hasRoot ? existingRoot : owner;
                for (NSUInteger animated = 0; animated < 2; animated++) {
                    for (NSNumber *option in specifier.values) {
                        navigation.topViewController = host;
                        DOPSJetsamListItemsController *items =
                            open_items(owner, specifier, animated != 0);
                        int writesBefore = liveWrites;
                        NSUInteger errorsBefore = owner.errorCount;
                        choose(items, option);
                        assert(owner.errorCount == errorsBefore);
                        assert(liveWrites == writesBefore + (running ? 1 : 0));
                        assert([[owner readJetsamMultiplier:specifier] isEqual:option]);
                        assert([[store preferenceValueForKey:@"jetsamMultiplier"] isEqual:option]);

                        DOPreferenceManager *reopened = [DOPreferenceManager new];
                        [reopened setValue:path forKey:@"preferencesPath"];
                        [reopened loadPreferences];
                        assert([[reopened preferenceValueForKey:@"jetsamMultiplier"] isEqual:option]);
                        assert([[reopened preferenceValueForKey:@"unrelated"] isEqual:@YES]);
                        navigation.topViewController = host;
                        items = open_items(owner, specifier, animated != 0);
                        assert([[(DOSettingsController *)items.parentController
                            readJetsamMultiplier:items.specifier] isEqual:option]);
                    }
                }
            }
        }

        [DOEnvironmentManager sharedManager].isJailbroken = YES;
        owner.rootController = nil;
        navigation.expectedRoot = owner;
        navigation.topViewController = host;
        DOPSJetsamListItemsController *items = open_items(owner, specifier, NO);
        NSUInteger errorsBefore = owner.errorCount;
        applyError = -7;
        choose(items, @4);
        assert(owner.errorCount == errorsBefore + 1);
        assert([[store preferenceValueForKey:@"jetsamMultiplier"] isEqual:@8]);
        applyError = 0;

        readError = -9;
        assert([[owner readJetsamMultiplier:specifier] isEqual:@(-1)]);
        readError = 0;
        liveValue = 0;
        assert([[owner readJetsamMultiplier:specifier] isEqual:@6]);
        liveValue = NAN;
        assert([[owner readJetsamMultiplier:specifier] isEqual:@(-1)]);
        liveValue = 4;

        // An applied runtime value and failed file write remain distinct.
        [store setValue:directory forKey:@"preferencesPath"];
        errorsBefore = owner.errorCount;
        choose(items, @5);
        assert(owner.errorCount == errorsBefore + 1 && liveValue == 2.5);
        assert([[store preferenceValueForKey:@"jetsamMultiplier"] isEqual:@8]);
        [store setValue:path forKey:@"preferencesPath"];

        PSListController *other = [PSListController new];
        id oldParent = other.parentController;
        NSUInteger nativePushes = navigation.pushes;
        [owner pushController:other];
        assert(owner.inheritedPushes == 1 && owner.inheritedController == other);
        assert(owner.inheritedAnimated && other.parentController == oldParent);
        [owner pushController:other animate:NO];
        assert(owner.inheritedPushes == 2 && !owner.inheritedAnimated);
        assert(navigation.pushes == nativePushes);
        owner.navigationController = nil;
        [owner pushController:items];
        assert(owner.inheritedPushes == 3);
        assert(navigation.pushes == nativePushes);

        assert(liveReads > 0);
        puts("PASS: production Jetsam push binds the real Preferences owner before "
             "navigation, both push APIs and root cases, seven production choices, "
             "actual getter/setter and Foundation persistence/reopen, failed writes "
             "and reads, unrelated-controller fallback; navigation/IPC/selection "
             "are doubles, no private Preferences or UIKit execution");
    }
    @finally {
        [files removeItemAtPath:directory error:NULL];
    }
} return 0; }
'''


def native_tests():
    if sys.platform != "darwin" or not shutil.which("clang"):
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    settings = source(SETTINGS)
    methods = "\n".join(extract(settings, anchor) for anchor in (
        "- (NSArray *)jetsamOptionNumbers",
        "- (NSArray *)jetsamOptionTitles",
        "- (BOOL)pushJetsamController:",
        "- (void)pushController:(id)controller\n",
        "- (void)pushController:(id)controller animate:",
        "- (id)readPreferenceValue:",
        "- (id)readJetsamMultiplier:",
        "- (void)setJetsamMultiplier:",
    ))
    binding = "[jetsamSpecifier setValues:[self jetsamOptionNumbers] titles:[self jetsamOptionTitles]];"
    if binding not in settings:
        raise AssertionError("Production inline Jetsam binding is missing")
    main = NATIVE_MAIN.replace("BIND_JETSAM_VALUES",
                               binding.replace("jetsamSpecifier", "specifier").replace("self ", "owner "))
    with tempfile.TemporaryDirectory(prefix="rc9-jetsam-navigation-") as directory:
        path = Path(directory) / "jetsam_navigation.m"
        binary = Path(directory) / "jetsam_navigation"
        path.write_text("\n".join((NATIVE_PREFIX, methods, "@end", main)), encoding="utf-8")
        preferences = ROOT / "Application/Dopamine/Jailbreak"
        subprocess.run([
            shutil.which("clang"), "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
            "-O1", "-g", "-fsanitize=address,undefined", "-framework", "Foundation",
            "-I", str(preferences), str(preferences / "DOPreferenceManager.m"),
            str(path), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(JetsamNavigationContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
