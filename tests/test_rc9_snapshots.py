"""SpringBoard snapshot contracts and extracted Objective-C regressions.

--native requires macOS clang/Foundation. It does not run iOS SpringBoard.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


SNAPSHOTS = "BaseBin/roothidehooks/springboard.x"
SAVE = "- (BOOL)_imageAccessQueue_saveData:"


class SnapshotContracts(unittest.TestCase):
    def test_optional_hook_checks_private_method_abi_before_initialization(self):
        text = source(SNAPSHOTS)
        self.assertIn("%group SnapshotWriteHooks", text)
        init = extract(text, "void sbInit(void)")
        self.assertIn("%init();", init)
        gate = extract(init, "if (springboardSnapshotWriteAPIAvailable())")
        self.assertIn("%init(SnapshotWriteHooks);", gate)
        api = extract(text, "static BOOL springboardSnapshotWriteAPIAvailable")
        for selector in (
            "_imageAccessQueue_saveData:forSnapshot:",
            "_outputFormatForSnapshot:", "containerIdentity",
            "_configureDefaultPathWithinGroupForFormat:",
            "bundleIdentifier", "snapshotContainerPath",
        ):
            self.assertIn(f"@selector({selector})", api)
        self.assertIn(')), "Bc", "@@")', api)
        self.assertIn(')), "q", "@")', api)
        self.assertIn(')), "@", "q")', api)
        signature = extract(text, "static BOOL springboardSnapshotMethodMatches")
        for check in ("!method", "method_getTypeEncoding", "numberOfArguments",
                      "methodReturnType", "getArgumentTypeAtIndex:"):
            self.assertIn(check, signature)

    def test_only_current_roothide_snapshot_paths_are_written(self):
        text = source(SNAPSHOTS)
        method = extract(text.split("%group SnapshotWriteHooks", 1)[1], SAVE)
        self.assertIn(
            'springboardJbrootPath(@"/var/mobile/Library/SplashBoard/Snapshots")',
            method,
        )
        for check in (
            "if (!snapshotRoot) return %orig;",
            '[snapshotRoot.stringByStandardizingPath stringByAppendingString:@"/"]',
            "containerPath.stringByStandardizingPath hasPrefix:snapshotRoot",
            "path = path.stringByStandardizingPath;",
            "if (![path hasPrefix:snapshotRoot]) return %orig;",
        ):
            self.assertIn(check, method)
        self.assertLess(method.index("hasPrefix:snapshotRoot"),
                        method.index("_configureDefaultPathWithinGroupForFormat:"))
        self.assertLess(method.index("if (![path hasPrefix:snapshotRoot])"),
                        method.index("createDirectoryAtPath:"))
        self.assertNotIn("realpath", method)
        self.assertNotIn("fileExistsAtPath:", method)
        self.assertIn("return [data writeToFile:path options:0 error:nil];", method)

    def test_invalid_inputs_and_stock_apple_apps_use_original(self):
        method = extract(source(SNAPSHOTS).split("%group SnapshotWriteHooks", 1)[1], SAVE)
        for check in (
            "isKindOfClass:NSData.class", "!data.length",
            'NSClassFromString(@"XBApplicationSnapshot")',
            'NSClassFromString(@"XBSnapshotContainerIdentity")',
            "bundleIdentifier isKindOfClass:NSString.class",
            "!bundleIdentifier.length",
            '[bundleIdentifier hasPrefix:@"com.apple."]',
            "!is_apple_internal_identifier(bundleIdentifier.UTF8String)",
            "if (isStockAppleApp) return %orig;",
            "if (!path) return NO;",
            "if (![path isKindOfClass:NSString.class]) return %orig;",
            "withIntermediateDirectories:YES attributes:nil error:nil]) return %orig;",
        ):
            self.assertIn(check, method)

    def test_existing_redirect_and_fcntl_and_blacklist_fixes_remain(self):
        text = source(SNAPSHOTS)
        redirect = extract(text, "-(NSString *)snapshotContainerPath")
        self.assertIn("if (!redirectedPath) return path;", redirect)
        self.assertIn("return path;", extract(redirect, "if (!created)"))
        self.assertIn("NSFilePosixPermissions : @0755", redirect)
        self.assertIn("is_apple_internal_identifier", redirect)
        self.assertIn("path isKindOfClass:NSString.class", redirect)
        self.assertIn("!bundleIdentifier.length", redirect)
        root = extract(text, "static NSString *springboardJbrootPath")
        self.assertIn("jbclient_get_jbroot()", root)
        self.assertIn("rootPath[0] != '/'", root)
        self.assertIn("case F_GETPROTECTIONCLASS:", text)
        self.assertEqual(text.count("va_arg("), 1)
        self.assertIn("isJailbreakBundlePath(executableURL.path.fileSystemRepresentation)", text)
        self.assertIn("objc_setAssociatedObject(bundleIdentifier, kDenyQueryTagKey, nil,", text)

    def test_hook_still_builds_for_both_architectures_and_springboard(self):
        build = source("BaseBin/roothidehooks/Makefile")
        self.assertIn("ARCHS = arm64 arm64e", build)
        self.assertIn("$(wildcard *.x)", build)
        self.assertIn('-Werror -fobjc-arc', build)
        main = extract(source("BaseBin/roothidehooks/main.x"), "%ctor")
        self.assertIn('[processName isEqualToString:@"SpringBoard"]', main)
        self.assertIn("sbInit();", main)
        loader = source("BaseBin/systemhook/src/main.c")
        springboard = loader.index('"/System/Library/CoreServices/SpringBoard.app/SpringBoard"')
        self.assertIn('dlopen(JBROOT_PATH("/basebin/roothidehooks.dylib"), RTLD_NOW);',
                      loader[springboard:springboard + 260])


PREFIX = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static NSString *testRoot, *hiddenClass;
static Class replacementManifest;
static int originalCalls, formatCalls;
static BOOL originalResult = YES;
static const char *jbclient_get_jbroot(void) {
    return testRoot ? testRoot.fileSystemRepresentation : NULL;
}
static BOOL is_apple_internal_identifier(const char *identifier) {
    return identifier && !strncmp(identifier, "com.apple.internal.", 19);
}
static Class snapshotTestClassFromString(NSString *name) {
    if ([name isEqualToString:hiddenClass]) return Nil;
    if (replacementManifest && [name isEqualToString:@"XBApplicationSnapshotManifestImpl"])
        return replacementManifest;
    return NSClassFromString(name);
}

@interface XBSnapshotContainerIdentity : NSObject
@property(nonatomic, strong) NSString *bundleIdentifier;
@property(nonatomic, strong) NSString *originalContainerPath;
@property(nonatomic, readonly, copy) NSString *snapshotContainerPath;
@end
@interface XBApplicationSnapshot : NSObject
@property(nonatomic, strong) XBSnapshotContainerIdentity *containerIdentity;
@property(nonatomic, strong) id configuredPath;
@property(nonatomic) int configureCalls;
@property(nonatomic) long long seenFormat;
- (NSString *)_configureDefaultPathWithinGroupForFormat:(long long)format;
@end
@interface XBApplicationSnapshotManifestImpl : NSObject
+ (long long)_outputFormatForSnapshot:(id)snapshot;
- (BOOL)_imageAccessQueue_saveData:(NSData *)data forSnapshot:(XBApplicationSnapshot *)snapshot;
- (BOOL)originalSaveData:(NSData *)data forSnapshot:(XBApplicationSnapshot *)snapshot;
@end
@implementation XBApplicationSnapshot
- (NSString *)_configureDefaultPathWithinGroupForFormat:(long long)format {
    ++self.configureCalls; self.seenFormat = format; return self.configuredPath;
}
@end
'''

MANIFEST = r'''
+ (long long)_outputFormatForSnapshot:(id)snapshot {
    ++formatCalls; return (1LL << 40) + 7;
}
- (BOOL)originalSaveData:(NSData *)data forSnapshot:(XBApplicationSnapshot *)snapshot {
    ++originalCalls; return originalResult;
}
'''

MAIN = r'''
static XBApplicationSnapshot *makeSnapshot(NSString *identifier, NSString *originalPath,
                                           NSString *configuredPath) {
    XBSnapshotContainerIdentity *identity = [XBSnapshotContainerIdentity new];
    identity.bundleIdentifier = identifier; identity.originalContainerPath = originalPath;
    XBApplicationSnapshot *snapshot = [XBApplicationSnapshot new];
    snapshot.containerIdentity = identity; snapshot.configuredPath = configuredPath;
    originalCalls = formatCalls = 0;
    return snapshot;
}
static void checkFallback(XBApplicationSnapshotManifestImpl *manifest, NSData *data,
                          XBApplicationSnapshot *snapshot) {
    originalCalls = 0;
    assert([manifest _imageAccessQueue_saveData:data forSnapshot:snapshot] == originalResult);
    assert(originalCalls == 1);
}
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"rc9-snapshots-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    testRoot = [temporary stringByAppendingPathComponent:@".jbroot-12345678"];
    NSString *systemPath = @"/var/mobile/Library/SplashBoard/Snapshots/org.example.app";
    NSString *container = springboardJbrootPath(systemPath);
    NSString *destination = [container stringByAppendingPathComponent:@"group/new.png"];
    NSData *data = [@"snapshot-one" dataUsingEncoding:NSUTF8StringEncoding];
    XBApplicationSnapshotManifestImpl *manifest = [XBApplicationSnapshotManifestImpl new];
    assert(springboardSnapshotWriteAPIAvailable());
    for (NSString *name in @[@"XBApplicationSnapshotManifestImpl", @"XBApplicationSnapshot",
                             @"XBSnapshotContainerIdentity"]) {
        hiddenClass = name; assert(!springboardSnapshotWriteAPIAvailable());
    }
    hiddenClass = nil;
    Method save = class_getInstanceMethod(manifest.class,
        @selector(_imageAccessQueue_saveData:forSnapshot:));
    assert(springboardSnapshotMethodMatches(save, "Bc", "@@"));
    assert(!springboardSnapshotMethodMatches(NULL, "Bc", "@@"));
    assert(!springboardSnapshotMethodMatches(save, "q", "@@"));
    assert(!springboardSnapshotMethodMatches(save, "Bc", "@q"));
    assert(!springboardSnapshotMethodMatches(save, "Bc", "@"));
    const char *badTypes[] = {"q32@0:8@16@24", "B32@0:8q16@24", "B24@0:8@16"};
    Method format = class_getClassMethod(manifest.class, @selector(_outputFormatForSnapshot:));
    for (size_t index = 0; index < sizeof(badTypes) / sizeof(badTypes[0]); index++) {
        NSString *name = [NSString stringWithFormat:@"SnapshotBadABI%zu", index];
        Class bad = objc_allocateClassPair(NSObject.class, name.UTF8String, 0);
        assert(bad);
        assert(class_addMethod(bad, method_getName(save), method_getImplementation(save), badTypes[index]));
        assert(class_addMethod(object_getClass(bad), method_getName(format),
                               method_getImplementation(format), method_getTypeEncoding(format)));
        objc_registerClassPair(bad);
        replacementManifest = bad; assert(!springboardSnapshotWriteAPIAvailable());
    }
    replacementManifest = Nil;

    XBApplicationSnapshot *snapshot = makeSnapshot(@"org.example.app", systemPath, destination);
    assert(![fm fileExistsAtPath:destination]);
    assert([manifest _imageAccessQueue_saveData:data forSnapshot:snapshot]);
    assert(originalCalls == 0 && snapshot.configureCalls == 1 && formatCalls == 1);
    assert(snapshot.seenFormat == (1LL << 40) + 7);
    assert([[NSData dataWithContentsOfFile:destination] isEqualToData:data]);
    NSData *newData = [@"snapshot-two" dataUsingEncoding:NSUTF8StringEncoding];
    assert([manifest _imageAccessQueue_saveData:newData forSnapshot:snapshot]);
    assert([[NSData dataWithContentsOfFile:destination] isEqualToData:newData]);

    snapshot = makeSnapshot(@"com.apple.Preferences", systemPath, destination);
    checkFallback(manifest, data, snapshot);
    assert(snapshot.configureCalls == 0 && formatCalls == 0);
    assert([snapshot.containerIdentity.snapshotContainerPath isEqualToString:systemPath]);
    originalResult = NO; checkFallback(manifest, data, snapshot); originalResult = YES;
    snapshot = makeSnapshot(@"com.apple.internal.test", systemPath, destination);
    assert([manifest _imageAccessQueue_saveData:data forSnapshot:snapshot] && originalCalls == 0);

    snapshot = makeSnapshot(@"org.example.app", systemPath, destination);
    checkFallback(manifest, nil, snapshot);
    checkFallback(manifest, NSData.data, snapshot);
    checkFallback(manifest, (id)NSNull.null, snapshot);
    checkFallback(manifest, data, nil);
    checkFallback(manifest, data, (id)NSNull.null);
    snapshot.containerIdentity = nil; checkFallback(manifest, data, snapshot);
    snapshot.containerIdentity = (id)NSNull.null; checkFallback(manifest, data, snapshot);
    for (id identifier in @[@"", @42]) {
        snapshot = makeSnapshot(identifier, systemPath, destination);
        checkFallback(manifest, data, snapshot);
    }
    snapshot = makeSnapshot(nil, systemPath, destination); checkFallback(manifest, data, snapshot);
    assert([snapshot.containerIdentity.snapshotContainerPath isEqualToString:systemPath]);
    snapshot = makeSnapshot(@"org.example.app", nil, destination);
    checkFallback(manifest, data, snapshot);
    snapshot.containerIdentity.originalContainerPath = (id)NSNull.null;
    checkFallback(manifest, data, snapshot);

    for (NSString *path in @[@"/outside", [testRoot stringByAppendingString:
                              @"/var/mobile/Library/SplashBoard/Snapshots-other/app"]]) {
        snapshot = makeSnapshot(@"org.example.app", path, destination);
        checkFallback(manifest, data, snapshot); assert(snapshot.configureCalls == 0);
    }
    NSString *outside = [temporary stringByAppendingPathComponent:@"outside.png"];
    NSString *snapshots = springboardJbrootPath(@"/var/mobile/Library/SplashBoard/Snapshots");
    for (NSString *path in @[outside, [snapshots stringByAppendingString:@"-other/out.png"],
                             [snapshots stringByAppendingString:@"/../out.png"]]) {
        snapshot = makeSnapshot(@"org.example.app", systemPath, path);
        checkFallback(manifest, data, snapshot); assert(![fm fileExistsAtPath:path]);
    }
    snapshot = makeSnapshot(@"org.example.app", systemPath, nil);
    assert(![manifest _imageAccessQueue_saveData:data forSnapshot:snapshot] && originalCalls == 0);
    snapshot.configuredPath = @42; checkFallback(manifest, data, snapshot);

    NSString *savedRoot = testRoot;
    testRoot = nil;
    snapshot = makeSnapshot(@"org.example.app", systemPath, destination);
    assert([snapshot.containerIdentity.snapshotContainerPath isEqualToString:systemPath]);
    checkFallback(manifest, data, snapshot);
    testRoot = @""; checkFallback(manifest, data, snapshot);
    testRoot = @"relative"; checkFallback(manifest, data, snapshot);
    testRoot = [temporary stringByAppendingPathComponent:@".jbroot-87654321"];
    checkFallback(manifest, data, snapshot);
    destination = [springboardJbrootPath(systemPath) stringByAppendingPathComponent:@"group/new.png"];
    snapshot = makeSnapshot(@"org.example.app", systemPath, destination);
    assert([manifest _imageAccessQueue_saveData:data forSnapshot:snapshot] && originalCalls == 0);
    assert([[NSData dataWithContentsOfFile:destination] isEqualToData:data]);
    testRoot = savedRoot;

    NSString *blocked = [container stringByAppendingPathComponent:@"blocked"];
    assert([data writeToFile:blocked atomically:NO]);
    snapshot = makeSnapshot(@"org.example.app", systemPath, [blocked stringByAppendingPathComponent:@"file.png"]);
    checkFallback(manifest, data, snapshot);
    assert([[NSData dataWithContentsOfFile:blocked] isEqualToData:data]);
    NSString *blockedSystemPath = [systemPath stringByAppendingPathComponent:@"blocked"];
    snapshot = makeSnapshot(@"org.example.app", blockedSystemPath, nil);
    assert([snapshot.containerIdentity.snapshotContainerPath isEqualToString:blockedSystemPath]);

    NSString *directory = [container stringByAppendingPathComponent:@"directory.png"];
    assert([fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    snapshot = makeSnapshot(@"org.example.app", systemPath, directory);
    assert(![manifest _imageAccessQueue_saveData:data forSnapshot:snapshot] && originalCalls == 0);
    BOOL isDirectory = NO;
    assert([fm fileExistsAtPath:directory isDirectory:&isDirectory] && isDirectory);
    assert([fm removeItemAtPath:temporary error:nil]);
    puts("PASS: actual snapshot redirect/write and ABI guards; randomized roots, new files, Apple exclusions, invalid inputs, path escapes, mkdir/write failures");
} return 0; }
'''


def native_tests():
    clang = shutil.which("clang")
    if not clang:
        raise SystemExit("--native requires macOS clang/Foundation; no native tests run")
    text = source(SNAPSHOTS)
    redirect = extract(text, "-(NSString *)snapshotContainerPath").replace(
        "%orig", "[self originalContainerPath]",
    )
    save = extract(text.split("%group SnapshotWriteHooks", 1)[1], SAVE).replace(
        "%orig", "[self originalSaveData:data forSnapshot:snapshot]",
    )
    gate = extract(text, "static BOOL springboardSnapshotWriteAPIAvailable").replace(
        "NSClassFromString(", "snapshotTestClassFromString(",
    )
    program = (
        PREFIX + extract(text, "static NSString *springboardJbrootPath") +
        "\n@implementation XBSnapshotContainerIdentity\n" + redirect + "\n@end\n" +
        "\n@implementation XBApplicationSnapshotManifestImpl\n" + MANIFEST + save + "\n@end\n" +
        extract(text, "static BOOL springboardSnapshotMethodMatches") + "\n" + gate + "\n" + MAIN
    )
    with tempfile.TemporaryDirectory(prefix="rc9-snapshots-") as temporary:
        path = Path(temporary) / "snapshots.m"
        binary = Path(temporary) / "snapshots"
        path.write_text(program, encoding="utf-8")
        subprocess.run([
            clang, "-fobjc-arc", "-fblocks", "-framework", "Foundation", "-Wall", "-Wextra",
            "-Werror", "-Wno-unused-parameter", "-O1", "-g", "-fsanitize=address,undefined",
            str(path), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SnapshotContracts),
    )
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.native:
        native_tests()
    else:
        print("Source checks only; --native runs extracted Objective-C on macOS, not iOS SpringBoard.")
