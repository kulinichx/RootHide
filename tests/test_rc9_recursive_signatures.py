"""Recursive signature failures: real functions, Foundation and production types.

ChOma parsing, randomization, trustcache and RootHide operations are test
boundaries. This does not prove parser safety, kernel behavior or iOS ABI.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


ROOT = Path(__file__).resolve().parents[1]
RECURSIVE = "BaseBin/libjailbreak/src/roothider/signatures.m"
SIGNATURES = "BaseBin/libjailbreak/src/signatures.c"


class RecursiveSignatureContracts(unittest.TestCase):
    def test_recursive_path_uses_shared_tristate_collector(self):
        text = source(RECURSIVE)
        self.assertIn('#include "../signatures.h"', text)
        body = extract(text, "static void recurse_handler(")
        self.assertIn("int signatureResult = macho_collect_adhoc_cdhash(macho, cdhash);", body)
        failure = extract(body, "if (signatureResult < 0)")
        for token in ("*collectionFailed = true;", "fat_free(fat);", "return;"):
            self.assertIn(token, failure)
        self.assertIn("bool isAdhocSigned = signatureResult > 0;", body)
        self.assertNotIn("macho_read_code_signature(macho)", body)
        self.assertIn("int macho_collect_adhoc_cdhash(",
                      source("BaseBin/libjailbreak/src/signatures.h"))
        extract(source(SIGNATURES), "int macho_collect_adhoc_cdhash(")

    def test_randomization_and_growth_failures_stop_collection(self):
        body = extract(source(RECURSIVE), "static void recurse_handler(")
        start = body.index("int ret = ensure_randomized_cdhash_for_slice(")
        end = body.index("// A trustcached executable", start)
        self.assertIn("*collectionFailed = true;", body[start:end])
        self.assertIn("fat_free(fat);", body[start:end])
        self.assertIn("if (*cdhashCountOut == UINT32_MAX)", body)
        self.assertIn("((size_t)*cdhashCountOut + 1) * sizeof(cdhash_t)", body)
        self.assertIn("for (uint32_t i", body)

    def test_wrapper_validates_inputs_and_discards_partial_output(self):
        body = extract(source(RECURSIVE), "int recurse_collect_untrusted_cdhashes(")
        self.assertLess(body.index("!cdhashesOut || !cdhashCountOut"),
                        body.index("*cdhashesOut = NULL;"))
        self.assertLess(body.index("*cdhashCountOut = 0;"), body.index("!path || !path[0]"))
        self.assertIn("!preferredArch->Types || !preferredArch->Subtypes", body)
        failure = extract(body, "if(collectionFailed)")
        for token in ("free(*cdhashesOut);", "*cdhashesOut = NULL;",
                      "*cdhashCountOut = 0;", "return -1;"):
            self.assertIn(token, failure)

    def test_live_consumer_returns_before_upload_on_failure(self):
        body = extract(source("BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c"),
                       "static int trust_macho_recurse(")
        failure = body.index("if(collectResult != 0)")
        upload = body.index("jb_trustcache_add_cdhashes(")
        self.assertLess(failure, upload)
        self.assertIn("return collectResult;", body[failure:upload])

    def test_existing_skips_and_dependency_walk_are_preserved(self):
        body = extract(source(RECURSIVE), "static void recurse_handler(")
        for token in ('"/private/preboot/Cryptexes/"', "!hasTrollstoreMarker(realfilepath)",
                      "isInsideJBRoot", "fileCaches containsObject:realLoadPath",
                      "ensure_jbroot_symlink(", "fat_find_slice(fat,",
                      "fat_find_preferred_slice(fat)", "is_cdhash_trustcached(cdhash)",
                      "macho_enumerate_dependencies(macho,", "*stop = true;"):
            self.assertIn(token, body)
        self.assertNotIn("cdhashWasKnown", body)
        # Missing paths and unsupported/non-Mach-O files are not made fatal here.
        for anchor in ("if(!resolvedLoadPath)", "if (fd < 0)", "if (!fat)"):
            self.assertNotIn("*collectionFailed = true;", extract(body, anchor))

    def test_native_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_recursive_signatures.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>
#include "signatures.h"

typedef struct {
    MachO macho;
    Fat fat;
    MachO *slice;
    CS_SuperBlob *raw;
    CS_DecodedSuperBlob *decoded;
    bool hasSignature, adhoc, readFailure, decodeFailure, hashFailure;
    bool randomizeFailure, parseFailure, sliceFailure, removable, trollstore;
    bool randomized;
    int commandError, dependencies[4], dependencyCount, reads, walks;
    unsigned char initialHash, finalHash;
} Node;

static Node nodes[4];
static NSString *testRoot;
static NSArray<NSString *> *paths;
static bool trusted[256], useRpath;
static int outstanding, fatOpens, fatCloses, growCalls, failGrow, randomizations;
static int preferredRequests;

static Node *node_for_path(const char *path) {
    for (int i = 0; i < 4; i++)
        if (!strcmp(path, paths[i].fileSystemRepresentation)) return &nodes[i];
    return NULL;
}
static Node *node_for_macho(MachO *macho) {
    for (int i = 0; i < 4; i++) if (macho == &nodes[i].macho) return &nodes[i];
    assert(!"Unexpected MachO");
    return NULL;
}
static Node *node_for_raw(CS_SuperBlob *blob) {
    for (int i = 0; i < 4; i++) if (nodes[i].raw == blob) return &nodes[i];
    assert(!"Unexpected raw blob");
    return NULL;
}
static Node *node_for_decoded(CS_DecodedSuperBlob *blob) {
    for (int i = 0; i < 4; i++) if (nodes[i].decoded == blob) return &nodes[i];
    assert(!"Unexpected decoded blob");
    return NULL;
}
static void *tracked_malloc(size_t size) {
    void *p = calloc(1, size);
    assert(p);
    outstanding++;
    return p;
}
static void tracked_free(void *p) {
    if (!p) return;
    for (int i = 0; i < 4; i++) {
        if (p == nodes[i].raw) nodes[i].raw = NULL;
        if (p == nodes[i].decoded) nodes[i].decoded = NULL;
    }
    assert(outstanding > 0);
    outstanding--;
    free(p);
}
static void *tracked_realloc(void *p, size_t size) {
    if (growCalls++ == failGrow) return NULL;
    bool isNew = p == NULL;
    void *result = realloc(p, size);
    assert(result);
    if (isNew) outstanding++;
    return result;
}
static bool test_shared_cache(const char *path) {
    return !strcmp(path, "/usr/lib/rc9-test-shared.dylib");
}
static bool string_has_prefix(const char *path, const char *prefix) {
    return !strncmp(path, prefix, strlen(prefix));
}
static bool isSubPathOf(const char *path, const char *parent) {
    return string_has_prefix(path, parent) && path[strlen(parent)] == '/';
}
static bool isRemovableBundlePath(const char *path) {
    Node *node = node_for_path(path);
    return node && node->removable;
}
static bool hasTrollstoreMarker(const char *path) {
    Node *node = node_for_path(path);
    return node && node->trollstore;
}
static void ensure_jbroot_symlink(const char *path) {
    assert(node_for_path(path));
}
Fat *fat_init_from_path(const char *path) {
    Node *node = node_for_path(path);
    assert(node);
    if (node->parseFailure) return NULL;
    fatOpens++;
    return &node->fat;
}
void fat_free(Fat *fat) {
    assert(fat);
    fatCloses++;
}
MachO *fat_find_slice(Fat *fat, cpu_type_t type, cpu_subtype_t subtype) {
    preferredRequests++;
    assert(type == CPU_TYPE_ARM64 && subtype == CPU_SUBTYPE_ARM64_ALL);
    return fat->slices[0];
}
static MachO *fat_find_preferred_slice(Fat *fat) {
    Node *node = node_for_macho(fat->slices[0]);
    return node->sliceFailure ? NULL : &node->macho;
}
int macho_enumerate_load_commands(MachO *macho,
        void (^visit)(struct load_command, uint64_t, void *, bool *)) {
    Node *node = node_for_macho(macho);
    if (node->commandError) return node->commandError;
    if (node->hasSignature) {
        struct load_command command = {
            .cmd = LC_CODE_SIGNATURE, .cmdsize = sizeof(struct linkedit_data_command)
        };
        bool stop = false;
        visit(command, 0, NULL, &stop);
        assert(stop);
    }
    return 0;
}
CS_SuperBlob *macho_read_code_signature(MachO *macho) {
    Node *node = node_for_macho(macho);
    assert(node->hasSignature && !node->raw);
    node->reads++;
    if (node->readFailure) return NULL;
    node->raw = tracked_malloc(sizeof(*node->raw));
    return node->raw;
}
CS_DecodedSuperBlob *csd_superblob_decode(CS_SuperBlob *blob) {
    Node *node = node_for_raw(blob);
    if (node->decodeFailure) return NULL;
    assert(!node->decoded);
    node->decoded = tracked_malloc(sizeof(*node->decoded));
    return node->decoded;
}
bool csd_superblob_is_adhoc_signed(CS_DecodedSuperBlob *blob) {
    return node_for_decoded(blob)->adhoc;
}
int csd_superblob_calculate_best_cdhash(CS_DecodedSuperBlob *blob,
        void *hash, int *type) {
    Node *node = node_for_decoded(blob);
    assert(!type);
    if (node->hashFailure) return -1;
    memset(hash, node->randomized ? node->finalHash : node->initialHash, sizeof(cdhash_t));
    return 0;
}
void csd_superblob_free(CS_DecodedSuperBlob *blob) {
    tracked_free(blob);
}
static bool is_cdhash_trustcached(cdhash_t hash) {
    return trusted[hash[0]];
}
static int ensure_randomized_cdhash_for_slice(const char *path,
        uint64_t offset, void *hash) {
    Node *node = node_for_path(path);
    assert(node && offset == node->macho.archDescriptor.offset);
    randomizations++;
    if (node->randomizeFailure) return -1;
    node->randomized = true;
    memset(hash, node->finalHash, sizeof(cdhash_t));
    return 0;
}
int macho_enumerate_dependencies(MachO *macho,
        void (^visit)(const char *, uint32_t, struct dylib *, bool *)) {
    Node *node = node_for_macho(macho);
    node->walks++;
    bool stop = false;
    for (int i = 0; i < node->dependencyCount && !stop; i++) {
        NSString *path = paths[node->dependencies[i]];
        if (useRpath) path = [@"@rpath/" stringByAppendingString:path.lastPathComponent];
        struct dylib dylib = {0};
        visit(path.fileSystemRepresentation, LC_LOAD_DYLIB, &dylib, &stop);
    }
    return 0;
}
int macho_enumerate_rpaths(MachO *macho, void (^visit)(const char *, bool *)) {
    node_for_macho(macho);
    bool stop = false;
    visit("@loader_path", &stop);
    return 0;
}
#define JBROOT_PATH(path) testRoot.fileSystemRepresentation
#define _dyld_shared_cache_contains_path test_shared_cache
#define JBLogDebug(...) ((void)0)
#define JBLogError(...) ((void)0)
#define DEBUG_LOG(...) ((void)0)
#define free tracked_free
#define realloc tracked_realloc
'''


NATIVE_MAIN = r'''
static preferredArchInfo defaultArch;

static void reset(void) {
    assert(outstanding == 0 && fatOpens == fatCloses);
    if (testRoot) assert([NSFileManager.defaultManager removeItemAtPath:testRoot error:nil]);
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:nil]);
    char canonical[PATH_MAX];
    assert(realpath(directory.fileSystemRepresentation, canonical));
    testRoot = @(canonical);
    NSMutableArray *newPaths = [NSMutableArray array];
    memset(nodes, 0, sizeof(nodes));
    memset(trusted, 0, sizeof(trusted));
    memset(&defaultArch, 0, sizeof(defaultArch));
    for (int i = 0; i < 4; i++) {
        NSString *path = [testRoot stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"file%d.dylib", i]];
        assert([[NSData data] writeToFile:path atomically:YES]);
        [newPaths addObject:path];
        nodes[i].slice = &nodes[i].macho;
        nodes[i].fat.slices = &nodes[i].slice;
        nodes[i].fat.slicesCount = 1;
        nodes[i].macho.archDescriptor.offset = i * 4096;
        nodes[i].hasSignature = nodes[i].adhoc = true;
        nodes[i].initialHash = i + 1;
        nodes[i].finalHash = i + 65;
    }
    paths = newPaths;
    nodes[0].dependencyCount = 3;
    for (int i = 0; i < 3; i++) nodes[0].dependencies[i] = i + 1;
    fatOpens = fatCloses = growCalls = randomizations = preferredRequests = 0;
    failGrow = -1;
    useRpath = false;
}
static int collect(cdhash_t **hashes, uint32_t *count) {
    return recurse_collect_untrusted_cdhashes(paths[0].fileSystemRepresentation,
                NULL, NULL, NULL, &defaultArch, hashes, count);
}
static void release_hashes(cdhash_t *hashes) {
    free(hashes);
    assert(outstanding == 0 && fatOpens == fatCloses);
}
static void expect_failure(void) {
    cdhash_t *hashes = (void *)1;
    uint32_t count = 99;
    assert(collect(&hashes, &count) == -1);
    assert(!hashes && count == 0 && outstanding == 0 && fatOpens == fatCloses);
}
int main(void) { @autoreleasepool {
    cdhash_t *hashes = NULL;
    uint32_t count = 0;
    reset();
    assert(collect(&hashes, &count) == 0 && count == 4);
    for (int i = 0; i < 4; i++) assert(hashes[i][0] == nodes[i].finalHash);
    assert(randomizations == 4);
    release_hashes(hashes);

    for (int kind = 0; kind < 6; kind++) {
        for (int position = 0; position < 4; position++) {
            reset();
            if (kind == 0) nodes[position].commandError = -1;
            if (kind == 1) nodes[position].readFailure = true;
            if (kind == 2) nodes[position].decodeFailure = true;
            if (kind == 3) nodes[position].hashFailure = true;
            if (kind == 4) nodes[position].randomizeFailure = true;
            if (kind == 5) failGrow = position;
            expect_failure();
            for (int i = position + 1; i < 4; i++) assert(nodes[i].reads == 0);
            assert(nodes[position].walks == 0);
        }
    }
    // Already trusted nodes still walk dependencies; repeated collections do not randomize again.
    reset();
    assert(collect(&hashes, &count) == 0 && count == 4);
    release_hashes(hashes);
    for (int i = 0; i < 4; i++) trusted[nodes[i].finalHash] = true;
    randomizations = 0;
    assert(collect(&hashes, &count) == 0 && !hashes && count == 0);
    for (int i = 0; i < 4; i++) assert(nodes[i].walks == 2);
    assert(randomizations == 0);
    release_hashes(hashes);

    reset();
    nodes[1].initialHash = nodes[0].finalHash;
    nodes[1].dependencyCount = 1;
    nodes[1].dependencies[0] = 0;
    assert(collect(&hashes, &count) == 0 && count == 3);
    assert(nodes[0].reads == 1 && nodes[1].walks == 1 && randomizations == 3);
    release_hashes(hashes);

    for (int skip = 0; skip < 6; skip++) {
        reset();
        if (skip == 0) nodes[1].hasSignature = false;
        if (skip == 1) nodes[1].adhoc = false;
        if (skip == 2) nodes[1].parseFailure = true;
        if (skip == 3) nodes[1].sliceFailure = true;
        if (skip == 4) nodes[1].removable = true;
        if (skip == 5) assert([NSFileManager.defaultManager removeItemAtPath:paths[1] error:nil]);
        assert(collect(&hashes, &count) == 0 && count == 3);
        assert(nodes[1].walks == 0);
        release_hashes(hashes);
    }
    reset();
    nodes[1].removable = nodes[1].trollstore = true;
    assert(collect(&hashes, &count) == 0 && count == 4);
    release_hashes(hashes);

    reset();
    useRpath = true;
    assert(collect(&hashes, &count) == 0 && count == 4);
    release_hashes(hashes);

    reset();
    uint32_t type = CPU_TYPE_ARM64, subtype = CPU_SUBTYPE_ARM64_ALL;
    defaultArch = (preferredArchInfo){1, &type, &subtype};
    assert(collect(&hashes, &count) == 0 && count == 4 && preferredRequests == 1);
    release_hashes(hashes);

    reset();
    assert(recurse_collect_untrusted_cdhashes("/usr/lib/rc9-test-shared.dylib",
                NULL, NULL, NULL, &defaultArch, &hashes, &count) == 0);
    assert(!hashes && count == 0 && fatOpens == 0);
    assert(recurse_collect_untrusted_cdhashes("@unresolvable/test", NULL, NULL,
                NULL, &defaultArch, &hashes, &count) == 0);
    assert(!hashes && count == 0 && fatOpens == 0);

    for (int invalid = 0; invalid < 5; invalid++) {
        reset();
        hashes = (void *)1;
        count = 99;
        const char *path = paths[0].fileSystemRepresentation;
        preferredArchInfo *arch = &defaultArch;
        if (invalid == 0) path = NULL;
        if (invalid == 1) path = "";
        if (invalid == 2) arch = NULL;
        if (invalid == 3) defaultArch = (preferredArchInfo){1, NULL, &subtype};
        if (invalid == 4) defaultArch = (preferredArchInfo){1, &type, NULL};
        assert(recurse_collect_untrusted_cdhashes(path, NULL, NULL, NULL,
                    arch, &hashes, &count) == -1);
        assert(!hashes && count == 0 && fatOpens == 0 && outstanding == 0);
    }
    assert(recurse_collect_untrusted_cdhashes(NULL, NULL, NULL, NULL, NULL, NULL, &count) == -1);
    assert(recurse_collect_untrusted_cdhashes(NULL, NULL, NULL, NULL, NULL, &hashes, NULL) == -1);
    assert([NSFileManager.defaultManager removeItemAtPath:testRoot error:nil]);
    puts("PASS: recursive failures, partial cleanup, final hashes, trusted/duplicate traversal, cycles, real rpaths and headers");
} return 0; }
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler or sys.platform != "darwin":
        raise SystemExit("--native requires macOS clang/Foundation and the fixed ChOma checkout")
    dependency = ROOT / "BaseBin/ChOma"
    revision = subprocess.check_output(
        ["git", "-C", str(dependency), "rev-parse", "HEAD"], text=True).strip()
    if revision != "ed99ac526142e78a5bc99793cf433775040f9d67":
        raise SystemExit("Native header regression requires RC9's fixed ChOma revision")
    text = source(RECURSIVE)
    start = text.index("typedef struct {")
    end = text.index("} preferredArchInfo;", start) + len("} preferredArchInfo;")
    code = "\n".join((
        NATIVE_PREFIX,
        text[start:end],
        *(extract(source(SIGNATURES), anchor) for anchor in (
            "static int macho_read_code_signature_checked(",
            "int macho_collect_adhoc_cdhash(",
        )),
        *(extract(text, anchor) for anchor in (
            "NSString* resolveLoaderExecutablePaths(",
            "static NSString *rpathCacheIdentity(",
            "static NSArray *cachedRpathsForLoader(",
            "NSString* resolveRpaths(",
            "NSString *resolveLoadPath(",
            "static void recurse_handler(",
            "int recurse_collect_untrusted_cdhashes(",
        )),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-recursive-signatures-") as tmp:
        directory = Path(tmp)
        include = directory / "include"
        include.mkdir()
        (include / "choma").symlink_to(dependency / "src", target_is_directory=True)
        path = directory / "recursive-signatures.m"
        binary = directory / "recursive-signatures-test"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run([
                compiler, "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-O1", "-g",
                "-fsanitize=address,undefined", "-I", str(include),
                "-I", str(ROOT / "BaseBin/libjailbreak/src"),
                str(path), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, timeout=30,
                                    capture_output=True, text=True)
            print(result.stdout.strip())
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            sys.stderr.write(diagnostic)
            encoded = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Recursive signature regression::{encoded[:3000]}")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(RecursiveSignatureContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
