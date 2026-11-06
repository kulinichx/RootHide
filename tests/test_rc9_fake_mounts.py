"""RC9 custom fake-mount bridge checks; native mode runs the real category with mocks."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = "Application/Dopamine/Jailbreak/DOEnvironmentManager+RCFakeMounts"
ENVIRONMENT = "Application/Dopamine/Jailbreak/DOEnvironmentManager"
NATIVE = r'''
#import <Foundation/Foundation.h>
#import <libjailbreak/jbroot.h>
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#import "DOEnvironmentManager+RCFakeMounts.h"

NSString *testRoot;
static BOOL jailbroken;
static int commandResult;
static NSUInteger rootCalls, sandboxCalls, commandCalls;
static char commandArguments[5][PATH_MAX];
static NSUInteger argumentCount;

char *get_jbroot(void) { return (char *)testRoot.fileSystemRepresentation; }

static int testExecCmd(const char *binary, ...) {
    commandCalls++;
    argumentCount = 0;
    snprintf(commandArguments[argumentCount++], PATH_MAX, "%s", binary ?: "(null)");
    va_list arguments;
    va_start(arguments, binary);
    const char *argument;
    while ((argument = va_arg(arguments, const char *))) {
        assert(argumentCount < 5);
        snprintf(commandArguments[argumentCount++], PATH_MAX, "%s", argument);
    }
    va_end(arguments);
    assert(argumentCount == 4);
    assert(strcmp(commandArguments[1], "internal") == 0);
    if (commandResult == 0 && strcmp(commandArguments[2], "mount") == 0) {
        NSString *mirror = [JBROOT_PATH(@"/mnt") stringByAppendingString:
                            [NSString stringWithUTF8String:commandArguments[3]]];
        [NSFileManager.defaultManager createDirectoryAtPath:mirror
                                withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return commandResult;
}

@implementation DOEnvironmentManager
- (BOOL)isJailbroken { return jailbroken; }
- (void)runAsRoot:(void (^)(void))block { rootCalls++; block(); }
- (void)runUnsandboxed:(void (^)(void))block { sandboxCalls++; block(); }
@end

#define exec_cmd testExecCmd
#include "DOEnvironmentManager+RCFakeMounts.m"
#undef exec_cmd

int main(void) { @autoreleasepool {
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    testRoot = [temporary stringByAppendingPathComponent:@".jbroot-12345678"];
    DOEnvironmentManager *manager = [DOEnvironmentManager new];
    assert([[manager fakeMountPaths] isEqual:@[]]);
    NSUInteger initialRoot = rootCalls, initialSandbox = sandboxCalls;
    assert(([manager saveFakeMountPaths:@[@"/System/Library/Test", @"/private/var/test"]]));
    assert(rootCalls == initialRoot + 1 && sandboxCalls == initialSandbox + 1);
    assert(([[manager fakeMountPaths] isEqual:@[@"/System/Library/Test", @"/private/var/test"]]));

    NSUInteger before = commandCalls;
    assert([manager setFakeMountPath:@"/System/../private" mounted:YES deleteMirror:NO] == EINVAL);
    assert([manager setFakeMountPath:@"/" mounted:YES deleteMirror:NO] == EINVAL);
    assert([manager setFakeMountPath:@"relative" mounted:YES deleteMirror:NO] == EINVAL);
    assert(commandCalls == before);

    assert([manager setFakeMountPath:@"/System/Library/Test" mounted:YES deleteMirror:NO] == 0);
    assert(commandCalls == before + 1);
    assert(strcmp(commandArguments[0], JBROOT_PATH("/basebin/jbctl")) == 0);
    assert(strcmp(commandArguments[1], "internal") == 0);
    assert(strcmp(commandArguments[2], "mount") == 0);
    assert(strcmp(commandArguments[3], "/System/Library/Test") == 0);
    NSString *mirror = [JBROOT_PATH(@"/mnt") stringByAppendingString:@"/System/Library/Test"];
    assert([NSFileManager.defaultManager fileExistsAtPath:mirror]);

    commandResult = 7;
    assert([manager setFakeMountPath:@"/System/Library/Test" mounted:NO deleteMirror:YES] == 7);
    assert([NSFileManager.defaultManager fileExistsAtPath:mirror]);
    commandResult = 0;
    assert([manager setFakeMountPath:@"/System/Library/Test" mounted:NO deleteMirror:YES] == 0);
    assert(![NSFileManager.defaultManager fileExistsAtPath:mirror]);

    before = commandCalls;
    [manager restoreFakeMounts];
    assert(commandCalls == before + 2);
    assert(strcmp(commandArguments[2], "mount") == 0);

    assert([NSFileManager.defaultManager removeItemAtPath:temporary error:nil]);
    puts("PASS: real RC9 fake-mount category, persisted list, root/sandbox boundary, path validation, jbctl arguments, failed delete preservation and restore loop");
} return 0; }
'''


class FakeMountContracts(unittest.TestCase):
    def test_rc9_custom_mount_methods_are_outside_upstream_environment_manager(self):
        for extension in (".h", ".m"):
            text = source(ENVIRONMENT + extension)
            self.assertNotIn("fakeMount", text)
            self.assertNotIn("setFakeMountPath", text)
            bridge = source(BRIDGE + extension)
            self.assertIn("DOEnvironmentManager (RCFakeMounts)", bridge)
        bridge = source(BRIDGE + ".m")
        for token in ("@\"/mnt/newFakePath.plist\"", '"internal"', '"mount"',
                      '"unmount"', "runAsRoot:", "runUnsandboxed:", "stringByStandardizingPath"):
            self.assertIn(token, bridge)

    def test_mount_method_bodies_match_pre_alignment_baseline(self):
        manifest = json.loads(source("docs/rc9-upstream-alignment-20261106.json"))
        text = source(BRIDGE + ".m").split(
            "@implementation DOEnvironmentManager (RCFakeMounts)", 1)[1]
        for anchor, expected in manifest["phase_two"]["method_body_sha256"].items():
            actual = hashlib.sha256(extract(text, anchor).encode("utf-8")).hexdigest()
            self.assertEqual(actual, expected, anchor)

    def test_upstream_references_do_not_contain_rc9_user_mount_api(self):
        ledger = json.loads(source("docs/rc9-upstream-alignment-20261106.json"))
        finding = next(entry for entry in ledger["ledger"] if entry["id"] == "custom_fake_mounts")
        self.assertEqual(finding["status"], "isolated_as_rc9_only")
        self.assertIn("The official and zqbb reference commits contain no user-managed path list",
                      finding["evidence"])
        self.assertIn("internal fakelib mount", finding["distinction"])

    def test_all_callers_import_the_extension_explicitly(self):
        settings = source("Application/Dopamine/UI/Settings/DOSettingsController.m")
        jailbreaker = source("Application/Dopamine/Jailbreak/DOJailbreaker.m")
        self.assertIn('#import "DOEnvironmentManager+RCFakeMounts.h"', settings)
        self.assertIn('#import "DOEnvironmentManager+RCFakeMounts.h"', jailbreaker)
        self.assertIn("[[DOEnvironmentManager sharedManager] restoreFakeMounts]", jailbreaker)

    def test_xcode_compiles_extension_once_in_the_app_target(self):
        project = source("Application/Dopamine.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("DOEnvironmentManager+RCFakeMounts.m in Sources"), 2)
        self.assertEqual(project.count("DOEnvironmentManager+RCFakeMounts.h"), 3)

    def test_native_regression_is_required_by_ci(self):
        workflow = source(".github/workflows/roothide.yml")
        self.assertIn("python3 tests/test_rc9_fake_mounts.py --native", workflow)

    def test_ios16_is_a_hard_upstream_porting_gate(self):
        manifest = json.loads(source("docs/rc9-upstream-alignment-20261106.json"))
        gate = manifest["compatibility_gate"]
        self.assertEqual(gate["primary_family"], "iOS 16")
        self.assertEqual(gate["minimum_ios"], "16.0")
        matrix = gate["supported_matrix"]
        self.assertEqual(
            matrix["status"],
            "pending_inventory_and_device_validation",
        )
        self.assertIn("All iOS 16.x", matrix["scope"])
        self.assertTrue(any("not only the user's iPadOS 16.5 device" in rule for rule in gate["rules"]))
        self.assertIn("full jailbreak matrix", matrix["clarification"].lower())
        self.assertTrue(any("iOS 17 or later" in rule for rule in gate["rules"]))
        project = source("Application/Dopamine.xcodeproj/project.pbxproj")
        for configuration in (
            "8C71982F2ABF0E84003C6658",
            "8C7198302ABF0E84003C6658",
        ):
            block = extract(project, configuration)
            self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 16.0;", block)
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.opa334.Dopamine-roothide;", block)
        package_tests = source("tests/test_rc9_release_package.py")
        self.assertIn('"expected_minimum_os": "16.0"', package_tests)


def native_tests():
    clang = shutil.which("clang")
    if sys.platform != "darwin" or not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    with tempfile.TemporaryDirectory(prefix="rc9-fake-mounts-") as directory:
        includes = Path(directory) / "libjailbreak"
        includes.mkdir()
        (includes / "jbroot.h").write_text(r'''
#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdio.h>
extern NSString *testRoot;
char *get_jbroot(void);
__attribute__((overloadable)) static inline NSString *JBROOT_PATH(NSString *path) {
    return [NSString stringWithFormat:@"%s%@", get_jbroot(), path];
}
__attribute__((overloadable)) static inline const char *JBROOT_PATH(const char *path) {
    static char buffer[PATH_MAX];
    snprintf(buffer, sizeof(buffer), "%s%s", get_jbroot(), path);
    return buffer;
}
''', encoding="utf-8")
        (includes / "util.h").write_text("int exec_cmd(const char *binary, ...);\n", encoding="utf-8")
        test = Path(directory) / "fake_mounts.m"
        test.write_text(
            '#include <limits.h>\n'
            '#import "' + str(ROOT / (ENVIRONMENT + ".h")) + '"\n' + NATIVE,
            encoding="utf-8")
        binary = Path(directory) / "fake_mounts"
        subprocess.run([
            clang, "-fobjc-arc", "-fblocks", "-framework", "Foundation",
            "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
            "-Wno-incomplete-implementation", "-O1", "-g",
            "-fsanitize=address,undefined", "-I", directory,
            "-I", str(ROOT / "Application/Dopamine/Jailbreak"),
            str(test), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(FakeMountContracts),
    )
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.native:
        native_tests()
    else:
        print("Source checks only; --native compiles and runs the real category with macOS Foundation mocks.")
