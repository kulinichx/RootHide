"""Update regressions: production updater and extractor with injected OS failures."""
import argparse
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import unittest
from test_rc9_services import extract, source

UPDATE = 'BaseBin/launchdhook/src/update.m'
UTIL = 'BaseBin/libjailbreak/src/util.c'


class UpdateContracts(unittest.TestCase):
    def test_validate_staging_before_live_replacement(self):
        body = extract(source(UPDATE), 'int jbupdate_basebin(')
        self.assertLess(body.index('jbupdate_patch_launchdaemons(tmpBasebinPath)'),
                        body.index('randomizeAndLoadBasebinTrustcache('))
        self.assertLess(body.index('if (!newVersion.length)'), body.index('removeItemAtPath:oldBasebinPath'))
        self.assertIn('if (![fm copyItemAtPath:', body)
        self.assertIn('@finally', body)
        self.assertLess(body.index('copyItemAtPath:'), body.index('setenv('))

    def test_extract_reports_write_header_errors_and_cleans_up(self):
        body = extract(source(UTIL), 'int libarchive_unarchive(')
        header = body.split('r = archive_write_header(ext, entry);', 1)[1].split('else if', 1)[0]
        self.assertIn('if (r < ARCHIVE_WARN) goto out;', header)
        for operation in ('archive_read_close(a)', 'archive_read_free(a)',
                          'archive_write_close(ext)', 'archive_write_free(ext)'):
            self.assertIn(operation, body.split('out:', 1)[1])
        self.assertIn('>= sizeof(outputPath)', body)


UPDATE_PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
static NSString *root, *fixture, *failure;
static NSMutableDictionary *markers;
static int trustCalls, liveWrites, cleanups, markerCalls;
static NSString *jbpath(NSString *path) { return [root stringByAppendingString:path]; }
#define JBROOT_PATH(path) jbpath(path)
@interface TestFileManager : NSObject
+(instancetype)defaultManager;
-(BOOL)fileExistsAtPath:(NSString *)path;
-(NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error;
-(BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error;
-(BOOL)copyItemAtPath:(NSString *)path toPath:(NSString *)target error:(NSError **)error;
@end
@implementation TestFileManager
+(instancetype)defaultManager { static id fm; if (!fm) fm = [self new]; return fm; }
-(BOOL)fileExistsAtPath:(NSString *)path { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
-(NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if ([failure isEqualToString:@"list"] && [path.lastPathComponent isEqualToString:@"basebin"]) return nil;
    if ([failure isEqualToString:@"empty"] && [path.lastPathComponent isEqualToString:@"basebin"]) return @[];
    return [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:error];
}
-(BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    if ([path hasPrefix:jbpath(@"/basebin/")]) {
        liveWrites++;
        if ([failure isEqualToString:@"remove"]) return NO;
    } else if ([path.lastPathComponent isEqualToString:@"basebin.tc"]) {
        if ([failure isEqualToString:@"tc-remove"]) return NO;
    } else { cleanups++; }
    return [NSFileManager.defaultManager removeItemAtPath:path error:error];
}
-(BOOL)copyItemAtPath:(NSString *)path toPath:(NSString *)target error:(NSError **)error {
    liveWrites++;
    if ([failure isEqualToString:@"copy"]) return NO;
    return [NSFileManager.defaultManager copyItemAtPath:path toPath:target error:error];
}
@end
@interface NSMutableDictionary (UpdateTests)
-(BOOL)rc_test_writeToFile:(NSString *)path atomically:(BOOL)atomically;
@end
@implementation NSMutableDictionary (UpdateTests)
-(BOOL)rc_test_writeToFile:(NSString *)path atomically:(BOOL)atomically {
    if ([failure isEqualToString:@"plist-write"]) return NO;
    return [self writeToFile:path atomically:atomically];
}
@end
static int libarchive_unarchive(const char *tarPath, const char *destination) {
    if ([failure isEqualToString:@"extract"]) return 1;
    return [NSFileManager.defaultManager copyItemAtPath:fixture toPath:@(destination) error:NULL] ? 0 : 1;
}
static int randomizeAndLoadBasebinTrustcache(const char *path) { trustCalls++; return [failure isEqualToString:@"trust"] ? -1 : 0; }
static int test_setenv(const char *key, const char *value, int overwrite) {
    markerCalls++;
    if (([failure isEqualToString:@"marker1"] && markerCalls == 1) ||
        ([failure isEqualToString:@"marker2"] && markerCalls == 2)) return -1;
    markers[@(key)] = @(value); return 0;
}
static int test_unsetenv(const char *key) { [markers removeObjectForKey:@(key)]; return 0; }
static void put(NSString *path, NSString *value) {
    assert([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]);
    assert([value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
}
static void reset(NSString *mode) {
    if (root) [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    fixture = [root stringByAppendingPathComponent:@"fixture"];
    failure = mode; markers = [NSMutableDictionary new];
    trustCalls = liveWrites = cleanups = markerCalls = 0;
    put(jbpath(@"/basebin/.version"), @"old");
    put(jbpath(@"/basebin/tool"), @"old-tool");
    put(jbpath(@"/basebin/gen/dyld"), @"live-dyld");
    put(jbpath(@"/basebin/.fakelib/sentinel"), @"live-mount");
    put([fixture stringByAppendingPathComponent:@"basebin/.version"], @"new");
    put([fixture stringByAppendingPathComponent:@"basebin/basebin.tc"], @"tc");
    put([fixture stringByAppendingPathComponent:@"basebin/tool"], @"new-tool");
    put([fixture stringByAppendingPathComponent:@"basebin/LaunchDaemons/service.plist"], @"");
    NSDictionary *plist = @{@"Label": @"test", @"ProgramArguments": @[@"@JBROOT@/basebin/tool", @"@JBROOT@/basebin/tool"]};
    assert([plist writeToFile:[fixture stringByAppendingPathComponent:@"basebin/LaunchDaemons/service.plist"] atomically:YES]);
    put([root stringByAppendingPathComponent:@"update.tar"], @"tar");
}
#define NSFileManager TestFileManager
#define setenv test_setenv
#define unsetenv test_unsetenv
'''

UPDATE_MAIN = r'''
#undef NSFileManager
static int run(void) { return jbupdate_basebin([root stringByAppendingPathComponent:@"update.tar"].fileSystemRepresentation); }
static void check(NSString *mode, int expected, BOOL touchedLive) {
    reset(mode); assert(run() == expected); assert(cleanups == 1); assert(markers.count == 0);
    if (!touchedLive) { assert(liveWrites == 0); assert([[NSString stringWithContentsOfFile:jbpath(@"/basebin/tool") encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"old-tool"]); }
}
int main(void) { @autoreleasepool {
    reset(nil); assert(run() == 0); assert(cleanups == 1 && trustCalls == 1);
    assert([markers[@"JBUPDATE_NEW_VERSION"] isEqualToString:@"new"]);
    assert([markers[@"JBUPDATE_PREV_VERSION"] isEqualToString:@"old"]);
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:jbpath(@"/basebin/LaunchDaemons/service.plist")];
    for (NSString *arg in plist[@"ProgramArguments"]) assert([arg isEqualToString:[jbpath(@"/") stringByAppendingString:@"/basebin/tool"]]);
    assert([[NSString stringWithContentsOfFile:jbpath(@"/basebin/gen/dyld") encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"live-dyld"]);
    assert([NSFileManager.defaultManager fileExistsAtPath:jbpath(@"/basebin/.fakelib/sentinel")]);
    reset(nil); assert(jbupdate_basebin(NULL) == 1 && cleanups == 0 && liveWrites == 0);
    assert(jbupdate_basebin("/nonexistent/rc9-update.tar") == 1);
    check(@"extract", 2, NO); check(@"trust", 5, NO);
    check(@"plist-write", 12, NO); assert(trustCalls == 0);
    check(@"tc-remove", 13, NO); check(@"list", 7, NO); check(@"empty", 7, NO);
    check(@"remove", 8, YES); check(@"copy", 9, YES);
    check(@"marker1", 14, YES); check(@"marker2", 14, YES);
    reset(nil); [NSFileManager.defaultManager removeItemAtPath:[fixture stringByAppendingPathComponent:@"basebin/basebin.tc"] error:NULL];
    assert(run() == 3 && cleanups == 1 && liveWrites == 0 && trustCalls == 0);
    reset(nil); put([fixture stringByAppendingPathComponent:@"basebin/.version"], @"");
    assert(run() == 6 && cleanups == 1 && liveWrites == 0 && trustCalls == 0);
    reset(nil); [NSFileManager.defaultManager removeItemAtPath:[fixture stringByAppendingPathComponent:@"basebin/LaunchDaemons"] error:NULL];
    assert(run() == 10 && cleanups == 1 && liveWrites == 0 && trustCalls == 0);
    reset(nil); put([fixture stringByAppendingPathComponent:@"basebin/LaunchDaemons/service.plist"], @"invalid");
    assert(run() == 11 && cleanups == 1 && liveWrites == 0 && trustCalls == 0);
    reset(nil); [@{@"ProgramArguments": @[@1]} writeToFile:[fixture stringByAppendingPathComponent:@"basebin/LaunchDaemons/service.plist"] atomically:YES];
    assert(run() == 11 && cleanups == 1 && liveWrites == 0);
    reset(nil); [@{@"Program": @"/bin/test"} writeToFile:[fixture stringByAppendingPathComponent:@"basebin/LaunchDaemons/service.plist"] atomically:YES];
    assert(run() == 0 && cleanups == 1);
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    puts("PASS: actual updater; invalid payloads, plist, trust, remove/copy, marker failures; live dyld untouched");
} return 0; }
'''

ARCHIVE_PREFIX = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#define ARCHIVE_OK 0
#define ARCHIVE_WARN -20
#define ARCHIVE_FAILED -25
#define ARCHIVE_EOF 1
#define ARCHIVE_EXTRACT_TIME 1
#define ARCHIVE_EXTRACT_PERM 2
#define ARCHIVE_EXTRACT_ACL 4
#define ARCHIVE_EXTRACT_FFLAGS 8
#define ARCHIVE_EXTRACT_OWNER 16
struct archive { int writer; };
struct archive_entry { int unused; };
static struct archive reader, writer;
static struct archive_entry entry;
static int fail, warning, headers, readCloses, writeCloses, readFrees, writeFrees, bodyCalls;
static const char *entryPath = "basebin/tool";
static struct archive *archive_read_new(void) { return fail == 1 ? NULL : &reader; }
static struct archive *archive_write_disk_new(void) { return fail == 2 ? NULL : &writer; }
static int archive_read_support_format_all(struct archive *a) { return 0; }
static int archive_read_support_filter_all(struct archive *a) { return 0; }
static int archive_write_disk_set_options(struct archive *a, int flags) { return 0; }
static int archive_write_disk_set_standard_lookup(struct archive *a) { return 0; }
static int archive_read_open_filename(struct archive *a, const char *p, size_t block) { return fail == 3 ? ARCHIVE_FAILED : 0; }
static int archive_read_next_header(struct archive *a, struct archive_entry **out) {
    if (fail == 4) return ARCHIVE_FAILED;
    if (headers++) return ARCHIVE_EOF;
    *out = &entry; return 0;
}
static const char *archive_error_string(struct archive *a) { return "injected archive error"; }
static const char *archive_entry_pathname(struct archive_entry *e) { return entryPath; }
static void archive_entry_set_pathname(struct archive_entry *e, const char *path) {}
static int archive_write_header(struct archive *a, struct archive_entry *e) { return fail == 5 ? ARCHIVE_FAILED : (warning ? ARCHIVE_WARN : 0); }
static int archive_entry_size(struct archive_entry *e) { return 1; }
static int copy_data(struct archive *a, struct archive *b) { bodyCalls++; return fail == 6 ? ARCHIVE_FAILED : 0; }
static int archive_write_finish_entry(struct archive *a) { return fail == 7 ? ARCHIVE_FAILED : 0; }
static int archive_read_close(struct archive *a) { readCloses++; return fail == 8 ? ARCHIVE_FAILED : 0; }
static int archive_write_close(struct archive *a) { writeCloses++; return fail == 9 ? ARCHIVE_FAILED : 0; }
static int archive_read_free(struct archive *a) { readFrees++; return fail == 10 ? ARCHIVE_FAILED : 0; }
static int archive_write_free(struct archive *a) { writeFrees++; return fail == 11 ? ARCHIVE_FAILED : 0; }
static void reset(int mode) { fail=mode;warning=headers=readCloses=writeCloses=readFrees=writeFrees=bodyCalls=0;entryPath="basebin/tool"; }
'''

ARCHIVE_MAIN = r'''
int main(void) {
    reset(0); assert(libarchive_unarchive("payload.tar", "/tmp/staging") == 0);
    assert(readFrees == 1 && writeFrees == 1 && bodyCalls == 1);
    for (int mode=1; mode<=11; mode++) {
        reset(mode); assert(libarchive_unarchive("payload.tar", "/tmp/staging") == 1);
        assert(readFrees == (mode != 1)); assert(writeFrees == (mode > 2));
        assert(readCloses == readFrees && writeCloses == writeFrees);
        if (mode == 5) assert(bodyCalls == 0);
    }
    reset(0); warning=1; assert(libarchive_unarchive("payload.tar", "/tmp/staging") == 0);
    reset(0); entryPath=NULL; assert(libarchive_unarchive("payload.tar", "/tmp/staging") == 1);
    assert(readFrees == 1 && writeFrees == 1);
    char longPath[PATH_MAX+1]; memset(longPath, 'x', sizeof(longPath)-1); longPath[PATH_MAX]=0;
    reset(0); assert(libarchive_unarchive("payload.tar", longPath) == 1 && writeFrees == 1);
    reset(0); entryPath=longPath; assert(libarchive_unarchive("payload.tar", "/tmp") == 1 && writeFrees == 1);
    reset(0); assert(libarchive_unarchive(NULL, "/tmp") == 1 && readFrees == 0);
    assert(libarchive_unarchive("payload.tar", NULL) == 1);
    puts("PASS: actual extractor; allocation/open/header/body/finish/close/free failures and truncated paths");
    return 0;
}
'''

REAL_ARCHIVE_PREFIX = r'''
#include <archive.h>
#include <archive_entry.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
'''
REAL_ARCHIVE_MAIN = r'''
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    return libarchive_unarchive(argv[1], argv[2]);
}
'''


def native_tests():
    clang = shutil.which('clang')
    if not clang:
        raise SystemExit('--native requires macOS clang/Foundation')
    update = extract(source(UPDATE), 'static int jbupdate_patch_launchdaemons(')
    update += '\n' + extract(source(UPDATE), 'int jbupdate_basebin(')
    update = update.replace('writeToFile:', 'rc_test_writeToFile:')
    archive = extract(source(UTIL), 'int libarchive_unarchive(')
    with tempfile.TemporaryDirectory(prefix='rc9-update-') as temp:
        for name, code, suffix, flags in (
            ('updater', UPDATE_PREFIX + update + UPDATE_MAIN, '.m', ['-fobjc-arc', '-framework', 'Foundation']),
            ('archive', ARCHIVE_PREFIX + archive + ARCHIVE_MAIN, '.c', []),
        ):
            path = Path(temp) / (name + suffix)
            binary = Path(temp) / name
            path.write_text(code, encoding='utf-8')
            subprocess.run([clang, *flags, '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                            '-O1', '-g', '-fsanitize=address,undefined', str(path), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
        # Exercise real libarchive semantics as well as injected API results.
        path = Path(temp) / 'real_archive.c'
        binary = Path(temp) / 'real_archive'
        path.write_text(REAL_ARCHIVE_PREFIX + extract(source(UTIL), 'static int\ncopy_data(') +
                        archive + REAL_ARCHIVE_MAIN, encoding='utf-8')
        subprocess.run([clang, '-Wall', '-Wextra', '-Werror', '-O1', '-g',
                        '-fsanitize=address,undefined', str(path), '-larchive', '-o', str(binary)], check=True)
        payload = Path(temp) / 'payload.tar'
        content = b'basebin extraction regression\n' * 256
        with tarfile.open(payload, 'w') as tar:
            directory = tarfile.TarInfo('basebin')
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            tar.addfile(directory)
            item = tarfile.TarInfo('basebin/tool')
            item.mode = 0o755
            item.size = len(content)
            tar.addfile(item, io.BytesIO(content))
            link = tarfile.TarInfo('basebin/link')
            link.type = tarfile.SYMTYPE
            link.linkname = 'tool'
            tar.addfile(link)
        output = Path(temp) / 'extracted'
        subprocess.run([str(binary), str(payload), str(output)], check=True)
        assert (output / 'basebin/tool').read_bytes() == content
        assert (output / 'basebin/link').is_symlink()
        assert (output / 'basebin/link').read_bytes() == content
        blocked = Path(temp) / 'blocked'
        blocked.write_text('existing file', encoding='utf-8')
        assert subprocess.run([str(binary), str(payload), str(blocked)]).returncode == 1
        assert blocked.read_text(encoding='utf-8') == 'existing file'
        damaged = Path(temp) / 'damaged.tar'
        damaged.write_bytes(payload.read_bytes()[:2048])
        assert subprocess.run([str(binary), str(damaged), str(Path(temp) / 'damaged-output')]).returncode == 1
        print('PASS: real libarchive; regular file, symlink, blocked destination and truncated payload')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', action='store_true')
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(UpdateContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.native:
        native_tests()
    else:
        print('Source checks only; native checks require macOS Foundation.')
