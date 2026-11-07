"""Settings client regressions; --native uses Darwin XPC, not launchd IPC/UIKit."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


CLIENT = "BaseBin/libjailbreak/src/jbclient_xpc.c"
HEADER = "BaseBin/libjailbreak/src/jbclient_xpc.h"


class SettingsClientContracts(unittest.TestCase):
    def test_reply_requires_an_explicit_typed_result(self):
        body = extract(source(CLIENT), "static int jbclient_jbsettings_reply_result(")
        self.assertIn("XPC_TYPE_DICTIONARY", body)
        self.assertIn("XPC_TYPE_INT64", body)
        self.assertIn("INT_MIN", body)
        self.assertIn("INT_MAX", body)

    def test_get_initializes_outputs_and_does_not_copy_failure_values(self):
        body = extract(source(CLIENT), "int jbclient_jbsettings_get(")
        self.assertIn("*valueOut = NULL", body)
        self.assertLess(body.index("*valueOut = NULL"), body.index("jbserver_xpc_send("))
        self.assertIn("jbclient_jbsettings_reply_result(xreply)", body)
        self.assertIn("if (result == 0)", body)
        self.assertLess(body.index("if (result == 0)"), body.index("xpc_copy(value)"))
        setter = extract(source(CLIENT), "int jbclient_platform_jbsettings_set(")
        self.assertIn("jbclient_jbsettings_reply_result(xreply)", setter)

    def test_checked_double_and_verified_write_are_public_and_keep_wire_ids(self):
        header = source(HEADER)
        self.assertIn("int jbclient_jbsettings_get_double_checked(", header)
        self.assertIn("int jbclient_platform_jbsettings_set_double_verified(", header)
        verified = extract(source(CLIENT), "int jbclient_platform_jbsettings_set_double_verified(")
        self.assertIn("jbclient_platform_jbsettings_set_double(", verified)
        self.assertIn("jbclient_jbsettings_get_double_checked(", verified)
        self.assertIn("JBCLIENT_SETTINGS_ERROR_READBACK_MISMATCH", verified)
        self.assertIn("JBS_DOMAIN_SYSTEMWIDE, JBS_SYSTEMWIDE_JBSETTINGS_GET", source(CLIENT))
        self.assertIn("JBS_DOMAIN_PLATFORM, JBS_PLATFORM_JBSETTINGS_SET", source(CLIENT))

    def test_ui_does_not_turn_failed_reads_into_the_default_choice(self):
        getter = extract(source("Application/Dopamine/UI/Settings/DOSettingsController.m"),
                         "- (id)readJetsamMultiplier:")
        self.assertIn("jbclient_jbsettings_get_double_checked(", getter)
        self.assertIn("return @(-1);", getter)
        self.assertNotIn("return nil;", getter)
        self.assertNotIn("jbclient_jbsettings_get_double(", getter)

    def test_ui_verifies_live_write_before_checked_persistence(self):
        setter = extract(source("Application/Dopamine/UI/Settings/DOSettingsController.m"),
                         "- (void)setJetsamMultiplier:")
        verify = setter.index("jbclient_platform_jbsettings_set_double_verified(")
        persist = setter.index("setPreferenceValue:value forKey:")
        self.assertLess(verify, persist)
        self.assertIn("error:&saveError", setter)

    def test_ci_runs_real_xpc_and_preference_storage_regressions(self):
        workflow = source(".github/workflows/roothide.yml")
        self.assertIn("python3 tests/test_rc9_settings_client.py --native", workflow)

    def test_failed_storage_does_not_publish_a_false_in_memory_value(self):
        body = extract(source("Application/Dopamine/Jailbreak/DOPreferenceManager.m"),
                       "- (BOOL)setPreferenceValue:")
        write = body.index("writeToFile:_preferencesPath")
        publish = body.index("_preferences = updated")
        self.assertLess(write, publish)
        self.assertIn("NSDataWritingAtomic", body)
        self.assertIn("return NO;", body[write:publish])

    def test_failed_read_is_visible_in_the_existing_footer(self):
        jetsam = source("Application/Dopamine/UI/Settings/PSLists/DOPSJetsamListItemsController.m")
        self.assertIn("jbclient_jbsettings_get_double_checked(", jetsam)
        self.assertIn('DOLocalizedString(@"Jetsam_Read_Failed_Body")', jetsam)
        for language in ("en", "zh-CN", "zh-Hans"):
            strings = source(f"Application/Dopamine/{language}.lproj/Localizable.strings")
            for key in ("Jetsam_Read_Failed_Body", "Jetsam_Save_Failed_Body",
                        "Jetsam_Save_Failed_Live_Body", "Jetsam_Readback_Mismatch_Body"):
                self.assertIn(f'"{key}" = ', strings)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <math.h>
#include <xpc/xpc.h>

static xpc_object_t test_empty_dictionary(void) {
    return xpc_dictionary_create(NULL, NULL, 0);
}
#define xpc_dictionary_create_empty test_empty_dictionary
static struct {
    struct { double jetsamMultiplier; bool markAppsAsDebugged; } jailbreakSettings;
} gSystemInfo;
#define jbsetting(key) (gSystemInfo.jailbreakSettings.key)
enum {
    NORMAL, NO_REPLY, NOT_A_DICTIONARY, NO_RESULT, BOOL_RESULT, LARGE_RESULT,
    FAILED_WITH_VALUE, NO_VALUE, BOOL_VALUE, IGNORED_WRITE, READ_FAILS_AFTER_WRITE
};
static int mode, sends, writes, reads;
static xpc_object_t jbserver_xpc_send(uint64_t domain, uint64_t action, xpc_object_t args);
'''

NATIVE_MAIN = r'''
static xpc_object_t jbserver_xpc_send(uint64_t domain, uint64_t action, xpc_object_t args) {
    ++sends;
    bool writing = domain == JBS_DOMAIN_PLATFORM && action == JBS_PLATFORM_JBSETTINGS_SET;
    bool reading = domain == JBS_DOMAIN_SYSTEMWIDE && action == JBS_SYSTEMWIDE_JBSETTINGS_GET;
    assert(writing || reading);
    if (writing) ++writes; else ++reads;
    const char *key = xpc_dictionary_get_string(args, "key");
    assert(key);
    if (mode == NO_REPLY || (mode == READ_FAILS_AFTER_WRITE && reading)) return NULL;
    if (mode == NOT_A_DICTIONARY) return xpc_string_create("unexpected reply");
    xpc_object_t reply = test_empty_dictionary();
    if (mode == NO_RESULT) return reply;
    if (mode == BOOL_RESULT) {
        xpc_dictionary_set_bool(reply, "result", true);
        return reply;
    }
    if (mode == LARGE_RESULT) {
        xpc_dictionary_set_int64(reply, "result", INT64_C(0x100000000));
        return reply;
    }
    if (mode == FAILED_WITH_VALUE) {
        xpc_dictionary_set_int64(reply, "result", -9);
        xpc_dictionary_set_double(reply, "value", 3.5);
        return reply;
    }
    int result;
    if (writing) {
        result = mode == IGNORED_WRITE ? 0 :
            jbsettings_set(key, xpc_dictionary_get_value(args, "value"));
    } else {
        xpc_object_t value = NULL;
        result = jbsettings_get(key, &value);
        if (value) {
            if (mode != NO_VALUE) xpc_dictionary_set_value(reply, "value", value);
            xpc_release(value);
        }
        if (mode == BOOL_VALUE) xpc_dictionary_set_bool(reply, "value", true);
    }
    xpc_dictionary_set_int64(reply, "result", result);
    return reply;
}

int main(void) {
    for (int option = 2; option <= 8; ++option) {
        mode = NORMAL;
        double actual = NAN, expected = (double)option / 2.0;
        assert(jbclient_platform_jbsettings_set_double_verified(
            "jetsamMultiplier", expected, &actual) == 0);
        assert(actual == expected);
        actual = NAN;
        assert(jbclient_jbsettings_get_double_checked("jetsamMultiplier", &actual) == 0);
        assert(actual == expected);
        assert(jbclient_jbsettings_get_double("jetsamMultiplier") == expected);
    }
    mode = NORMAL;
    assert(jbclient_platform_jbsettings_set_bool("markAppsAsDebugged", true) == 0);
    assert(jbclient_jbsettings_get_bool("markAppsAsDebugged"));
    assert(jbclient_platform_jbsettings_set_bool("markAppsAsDebugged", false) == 0);
    assert(!jbclient_jbsettings_get_bool("markAppsAsDebugged"));
    assert(jbclient_jbsettings_get_uint64("jetsamMultiplier") == 0);
    assert(!jbclient_jbsettings_get_bool("jetsamMultiplier"));
    double unchanged = 123.0;
    assert(jbclient_jbsettings_get_double_checked("markAppsAsDebugged", &unchanged)
        == JBCLIENT_SETTINGS_ERROR_INVALID_VALUE);
    assert(unchanged == 123.0);

    for (mode = NO_REPLY; mode <= BOOL_VALUE; ++mode) {
        int failure = mode == NO_REPLY ? -1 :
            mode == FAILED_WITH_VALUE ? -9 :
            mode >= NO_VALUE ? JBCLIENT_SETTINGS_ERROR_INVALID_VALUE :
            JBCLIENT_SETTINGS_ERROR_INVALID_REPLY;
        xpc_object_t value = (xpc_object_t)(uintptr_t)1;
        int result = jbclient_jbsettings_get("jetsamMultiplier", &value);
        if (mode == BOOL_VALUE) {
            assert(result == 0 && value && xpc_get_type(value) == XPC_TYPE_BOOL);
            xpc_release(value);
        } else {
            assert(result == failure && value == NULL);
        }
        unchanged = 123.0;
        assert(jbclient_jbsettings_get_double_checked("jetsamMultiplier", &unchanged) == failure);
        assert(unchanged == 123.0);
        assert(jbclient_jbsettings_get_double("jetsamMultiplier") == 0);
        if (mode <= FAILED_WITH_VALUE) {
            assert(jbclient_platform_jbsettings_set_double("jetsamMultiplier", 2.0) == failure);
        }
    }
    mode = NORMAL;
    gSystemInfo.jailbreakSettings.jetsamMultiplier = 0;
    unchanged = 123.0;
    assert(jbclient_jbsettings_get_double_checked("jetsamMultiplier", &unchanged) == 0);
    assert(unchanged == 0);
    mode = IGNORED_WRITE;
    unchanged = NAN;
    assert(jbclient_platform_jbsettings_set_double_verified("jetsamMultiplier", 2.5, &unchanged)
        == JBCLIENT_SETTINGS_ERROR_READBACK_MISMATCH);
    assert(unchanged == 0);
    mode = READ_FAILS_AFTER_WRITE;
    unchanged = 123.0;
    assert(jbclient_platform_jbsettings_set_double_verified("jetsamMultiplier", 2.5, &unchanged)
        == -1);
    assert(isnan(unchanged));
    mode = NORMAL;
    int prior = sends;
    assert(jbclient_platform_jbsettings_set_double_verified("jetsamMultiplier", NAN, NULL)
        == JBCLIENT_SETTINGS_ERROR_INVALID_VALUE);
    assert(sends == prior);
    xpc_object_t value = (xpc_object_t)(uintptr_t)1;
    assert(jbclient_jbsettings_get(NULL, &value) == JBCLIENT_SETTINGS_ERROR_INVALID_VALUE);
    assert(value == NULL);
    assert(jbclient_jbsettings_get_double_checked("jetsamMultiplier", NULL)
        == JBCLIENT_SETTINGS_ERROR_INVALID_VALUE);
    assert(jbclient_platform_jbsettings_set("jetsamMultiplier", NULL)
        == JBCLIENT_SETTINGS_ERROR_INVALID_VALUE);
    assert(writes && reads);
    puts("PASS: production settings client/server functions using real Darwin XPC objects; "
         "seven choices, malformed replies, missing values, ignored writes and lost readbacks; "
         "transport substituted, no launchd IPC/UIKit/device execution");
    return 0;
}
'''

PREFERENCE_MAIN = r'''
#import <Foundation/Foundation.h>
#import "DOPreferenceManager.h"
#include <assert.h>
#include <stdio.h>

@interface DOPreferenceManager (StorageTest)
- (void)loadPreferences;
@end

static DOPreferenceManager *manager_at(NSString *path) {
    DOPreferenceManager *manager = [[DOPreferenceManager alloc] init];
    [manager setValue:path forKey:@"preferencesPath"];
    [manager loadPreferences];
    return manager;
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rc9-preferences-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        assert([files createDirectoryAtPath:directory withIntermediateDirectories:NO
            attributes:nil error:&error]);
        @try {
            NSString *path = [directory stringByAppendingPathComponent:@"preferences.plist"];
            DOPreferenceManager *manager = manager_at(path);
            assert([manager setPreferenceValue:@YES forKey:@"unrelated" error:&error]);
            for (int option = 2; option <= 8; ++option) {
                error = nil;
                assert([manager setPreferenceValue:@(option) forKey:@"jetsamMultiplier" error:&error]);
                assert([[manager preferenceValueForKey:@"jetsamMultiplier"] isEqual:@(option)]);
                DOPreferenceManager *reopened = manager_at(path);
                assert([[reopened preferenceValueForKey:@"jetsamMultiplier"] isEqual:@(option)]);
                assert([[reopened preferenceValueForKey:@"jetsamMultiplier"] isKindOfClass:NSNumber.class]);
                assert([[reopened preferenceValueForKey:@"unrelated"] isEqual:@YES]);
            }
            NSString *notDirectory = [directory stringByAppendingPathComponent:@"not-a-directory"];
            assert([@"file" writeToFile:notDirectory atomically:YES
                encoding:NSUTF8StringEncoding error:&error]);
            [manager setValue:[notDirectory stringByAppendingPathComponent:@"prefs.plist"]
                forKey:@"preferencesPath"];
            error = nil;
            assert(![manager setPreferenceValue:@3 forKey:@"jetsamMultiplier" error:&error]);
            assert(error != nil);
            assert([[manager preferenceValueForKey:@"jetsamMultiplier"] isEqual:@8]);
            assert([[manager_at(path) preferenceValueForKey:@"jetsamMultiplier"] isEqual:@8]);
            [manager setValue:directory forKey:@"preferencesPath"];
            error = nil;
            assert(![manager setPreferenceValue:@4 forKey:@"jetsamMultiplier" error:&error]);
            assert(error != nil);
            assert([[manager preferenceValueForKey:@"jetsamMultiplier"] isEqual:@8]);
            puts("PASS: actual Foundation preference manager, all seven numeric choices, "
                 "atomic file writes, reopen/read-back and failed-save memory preservation; "
                 "temporary host storage, no UIKit/device execution");
        }
        @finally {
            [files removeItemAtPath:directory error:NULL];
        }
    }
    return 0;
}
'''


def native_tests():
    if sys.platform != "darwin":
        raise SystemExit("--native requires Darwin XPC; no native tests were run")
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang")
    header = source(HEADER)
    codes = header[header.index("enum {"):header.index("void jbclient_xpc_set_custom_port")]
    functions = "\n".join(extract(source(CLIENT), anchor) for anchor in (
        "static int jbclient_jbsettings_reply_result(",
        "int jbclient_jbsettings_get(",
        "bool jbclient_jbsettings_get_bool(",
        "uint64_t jbclient_jbsettings_get_uint64(",
        "int jbclient_jbsettings_get_double_checked(",
        "double jbclient_jbsettings_get_double(",
        "int jbclient_platform_jbsettings_set(",
        "int jbclient_platform_jbsettings_set_bool(",
        "int jbclient_platform_jbsettings_set_double(",
        "int jbclient_platform_jbsettings_set_double_verified(",
    ))
    handlers = "\n".join(extract(
        source("BaseBin/launchdhook/src/jbserver/jbsettings.c"), anchor
    ) for anchor in ("int jbsettings_get(", "int jbsettings_set("))
    with tempfile.TemporaryDirectory(prefix="rc9-settings-client-") as directory:
        path = Path(directory) / "client.c"
        binary = Path(directory) / "client-test"
        path.write_text("\n".join((
            NATIVE_PREFIX, source("BaseBin/libjailbreak/src/jbserver_domains.h"),
            codes, handlers, functions, NATIVE_MAIN)), encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-O1", "-g", "-fsanitize=address,undefined", str(path),
                        "-lxpc", "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
        preference_main = Path(directory) / "preferences.m"
        preference_binary = Path(directory) / "preferences-test"
        preference_main.write_text(PREFERENCE_MAIN, encoding="utf-8")
        root = Path(__file__).resolve().parents[1]
        preference_directory = root / "Application/Dopamine/Jailbreak"
        subprocess.run([compiler, "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-g", "-O1", "-fsanitize=address,undefined",
                        "-framework", "Foundation", "-I", str(preference_directory),
                        str(preference_directory / "DOPreferenceManager.m"),
                        str(preference_main), "-o", str(preference_binary)], check=True)
        subprocess.run([str(preference_binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SettingsClientContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.native:
        native_tests()
    else:
        print("Source contracts only; --native requires macOS and real Darwin XPC.")
