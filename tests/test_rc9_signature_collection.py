"""Extracted signature-collection regressions; ChOma and OS boundaries are mocked.

--native runs production C with Blocks and ASan/UBSan on macOS. This does not
validate the ChOma parser itself, kernel trustcache lifetime, or iOS private ABI.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


SIGNATURES = "BaseBin/libjailbreak/src/signatures.c"


class SignatureCollectionContracts(unittest.TestCase):
    def test_parse_failure_is_distinct_from_no_signature_or_nonadhoc(self):
        text = source(SIGNATURES)
        reader = extract(text, "static int macho_read_code_signature_checked(")
        self.assertIn("LC_CODE_SIGNATURE", reader)
        self.assertIn("if (status != 0) return -1;", reader)
        self.assertIn("if (!hasSignature) return 0;", reader)
        self.assertIn("return *superblobOut ? 1 : -1;", reader)
        body = extract(text, "static int macho_collect_adhoc_cdhash(")
        self.assertIn("macho_read_code_signature_checked(macho, &superblob)", body)
        self.assertIn("if (signatureResult <= 0) return signatureResult;", body)
        self.assertIn("if (!decodedSuperblob) return -1;", body)
        self.assertIn("== 0 ? 1 : -1", body)
        wrapper = extract(text, "bool macho_parse_code_signature(")
        self.assertIn("macho_collect_adhoc_cdhash(macho, cdhashOut) == 1", wrapper)

    def test_both_collectors_fail_without_publishing_partial_results(self):
        text = source(SIGNATURES)
        for anchor in ("int fat_collect_untrusted_cdhashes(",
                       "int file_collect_untrusted_cdhashes("):
            body = extract(text, anchor)
            self.assertIn("int signatureResult = macho_collect_adhoc_cdhash(", body)
            self.assertIn("signatureResult < 0", body)
            self.assertIn("status = ENOEXEC;", body)
            self.assertIn("cdhashCount == UINT32_MAX", body)
            self.assertIn("((size_t)cdhashCount + 1) * sizeof(cdhash_t)", body)
            failure = body.index("if (status != 0) {\n\t\tfree(cdhashes);")
            self.assertLess(failure, body.index("*cdhashesOut = cdhashes;"))
        self.assertIn("int fat_collect_untrusted_cdhashes(", source(
            "BaseBin/libjailbreak/src/signatures.h"))

    def test_rc9_file_policy_and_randomization_remain_in_file_collector(self):
        body = extract(source(SIGNATURES), "int file_collect_untrusted_cdhashes(")
        for token in ('fcntl(fd, F_GETPATH', '"/private/preboot/Cryptexes/"',
                      "isRemovableBundlePath(filepath)", "!hasTrollstoreMarker(filepath)",
                      "ensure_randomized_cdhash_for_slice(filepath,"):
            self.assertIn(token, body)
        self.assertNotIn("hasJailFoolsMarker", body)
        self.assertNotIn("hasTrollstoreLiteMarker", body)

    def test_active_consumers_propagate_collection_status(self):
        body = extract(source("BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c"),
                       "int systemwide_trust_file(")
        self.assertIn("if (prepareStatus != 0)", body)
        self.assertIn("return prepareStatus;", body)
        self.assertIn("int status = file_collect_untrusted_cdhashes_by_path(",
                      source("BaseBin/libjailbreak/src/trustcache_fs.c"))
        update = source("BaseBin/launchdhook/src/update.m")
        self.assertIn("r = file_collect_untrusted_cdhashes_by_path(", update)
        self.assertIn("int collectStatus = file_collect_untrusted_cdhashes_by_path(",
                      source("BaseBin/dopamine/src/main.m"))

    def test_native_regressions_are_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_signature_collection.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif
enum { LC_CODE_SIGNATURE = 0x1d, F_GETPATH = 123, O_RDONLY = 0, FILE_STREAM_SIZE_AUTO = -1 };
typedef uint8_t cdhash_t[20];
typedef struct {
    struct { uint64_t offset; } archDescriptor;
    bool mappable, hasSignature, readFailure, decodeFailure, hashFailure, adhoc, cached;
    int loadError, randomizeError;
    unsigned char hash;
} MachO;
typedef struct { MachO *owner; } CS_SuperBlob;
typedef struct { MachO *owner; } CS_DecodedSuperBlob;
struct load_command { uint32_t cmd; };
typedef struct { int placeholder; } MemoryStream;
typedef struct { MachO slices[4]; size_t count; } Fat;
static Fat fat;
static MemoryStream stream;
static int outstanding, growCalls, failGrow, blobReads, randomizations;
static int streamsFreed, fatsFreed, closeCalls, pathError;
static bool streamFailure, fatFailure, removable, trollstore, openFailure;
static const char *filePath;

static void *tracked_malloc(size_t size) {
    void *p = malloc(size); assert(p); outstanding++; return p;
}
static void tracked_free(void *p) {
    if (p) { assert(outstanding > 0); outstanding--; free(p); }
}
static void *tracked_realloc(void *p, size_t size) {
    if (growCalls++ == failGrow) return NULL;
    bool newAllocation = p == NULL;
    void *result = realloc(p, size); assert(result);
    if (newAllocation) outstanding++;
    return result;
}
static void reset(void) {
    assert(outstanding == 0);
    memset(&fat, 0, sizeof(fat)); fat.count = 3;
    for (size_t i = 0; i < fat.count; i++) {
        MachO *m = &fat.slices[i];
        m->archDescriptor.offset = i * 4096;
        m->mappable = m->hasSignature = m->adhoc = true;
        m->hash = (unsigned char)(i + 1);
    }
    growCalls = blobReads = randomizations = streamsFreed = fatsFreed = closeCalls = pathError = 0;
    failGrow = -1;
    streamFailure = fatFailure = removable = trollstore = openFailure = false;
    filePath = "/var/jb/usr/lib/test.dylib";
}
static bool macho_is_mappable(MachO *m) { return m->mappable; }
static int macho_enumerate_load_commands(MachO *m,
        void (^visit)(struct load_command, uint64_t, void *, bool *)) {
    if (m->loadError) return m->loadError;
    if (m->hasSignature) {
        bool stop = false;
        struct load_command command = {LC_CODE_SIGNATURE};
        visit(command, 0, NULL, &stop); assert(stop);
    }
    return 0;
}
static CS_SuperBlob *macho_read_code_signature(MachO *m) {
    blobReads++;
    if (m->readFailure) return NULL;
    CS_SuperBlob *blob = tracked_malloc(sizeof(*blob)); blob->owner = m; return blob;
}
static CS_DecodedSuperBlob *csd_superblob_decode(CS_SuperBlob *blob) {
    if (blob->owner->decodeFailure) return NULL;
    CS_DecodedSuperBlob *decoded = tracked_malloc(sizeof(*decoded));
    decoded->owner = blob->owner; return decoded;
}
static bool csd_superblob_is_adhoc_signed(CS_DecodedSuperBlob *blob) { return blob->owner->adhoc; }
static int csd_superblob_calculate_best_cdhash(CS_DecodedSuperBlob *blob,
        cdhash_t hash, void *algorithm) {
    assert(!algorithm);
    if (blob->owner->hashFailure) return -1;
    memset(hash, blob->owner->cached ? 0xcc : blob->owner->hash, sizeof(cdhash_t));
    return 0;
}
static void csd_superblob_free(CS_DecodedSuperBlob *blob) { tracked_free(blob); }
static void fat_enumerate_slices(Fat *f, void (^visit)(MachO *, bool *)) {
    bool stop = false;
    for (size_t i = 0; i < f->count && !stop; i++) visit(&f->slices[i], &stop);
}
static bool is_cdhash_trustcached(cdhash_t hash) { return hash[0] == 0xcc; }
static int ensure_randomized_cdhash_for_slice(const char *path, uint64_t offset, cdhash_t hash) {
    assert(!strcmp(path, filePath)); randomizations++;
    for (size_t i = 0; i < fat.count; i++) {
        if (fat.slices[i].archDescriptor.offset != offset) continue;
        if (fat.slices[i].randomizeError) return fat.slices[i].randomizeError;
        memset(hash, fat.slices[i].hash + 0x40, sizeof(cdhash_t)); return 0;
    }
    assert(false); return EINVAL;
}
static int mock_fcntl(int fd, int command, char *path) {
    assert(command == F_GETPATH);
    if (pathError || fd != 77) { errno = pathError ? pathError : EBADF; return -1; }
    assert(strlen(filePath) < PATH_MAX); strcpy(path, filePath); return 0;
}
static bool string_has_prefix(const char *text, const char *prefix) {
    return !strncmp(text, prefix, strlen(prefix));
}
static bool isRemovableBundlePath(const char *path) { assert(path); return removable; }
static bool hasTrollstoreMarker(const char *path) { assert(path); return trollstore; }
static MemoryStream *file_stream_init_from_file_descriptor(int fd, int offset, int length, int flags) {
    assert(fd == 77 && !offset && length == FILE_STREAM_SIZE_AUTO && !flags);
    return streamFailure ? NULL : &stream;
}
static Fat *fat_init_from_memory_stream(MemoryStream *s) {
    assert(s == &stream); return fatFailure ? NULL : &fat;
}
static void memory_stream_free(MemoryStream *s) { assert(s == &stream); streamsFreed++; }
static void fat_free(Fat *f) { assert(f == &fat); fatsFreed++; streamsFreed++; }
static int mock_open(const char *path, int flags) {
    assert(path && flags == O_RDONLY);
    if (openFailure) { errno = ENOENT; return -1; }
    return 77;
}
static int mock_close(int fd) { assert(fd == 77); closeCalls++; errno = EBADF; return 0; }
#define free tracked_free
#define realloc tracked_realloc
#define fcntl mock_fcntl
#define open mock_open
#define close mock_close
#define JBLogError(...) ((void)0)
#define JBLogDebug(...) ((void)0)
'''

NATIVE_MAIN = r'''
static int collect(bool fromFile, cdhash_t **hashes, uint32_t *count) {
    return fromFile ? file_collect_untrusted_cdhashes(77, hashes, count) :
        fat_collect_untrusted_cdhashes(&fat, hashes, count);
}
int main(void) {
    cdhash_t *hashes = (void *)(uintptr_t)1, hash;
    uint32_t count = 99;
    reset();
    assert(fat_collect_untrusted_cdhashes(NULL, &hashes, &count) == EINVAL);
    assert(!hashes && count == 0);
    assert(fat_collect_untrusted_cdhashes(&fat, NULL, &count) == EINVAL);
    assert(file_collect_untrusted_cdhashes(77, &hashes, NULL) == EINVAL);
    assert(macho_collect_adhoc_cdhash(NULL, hash) == -1);
    assert(macho_collect_adhoc_cdhash(&fat.slices[0], NULL) == -1);
    assert(macho_parse_code_signature(&fat.slices[0], hash));
    assert(outstanding == 0);

    for (int file = 0; file < 2; file++) {
        reset(); hashes = NULL; count = 0;
        assert(collect(file, &hashes, &count) == 0 && count == 3);
        assert(hashes[0][0] == (file ? 0x41 : 1));
        assert(randomizations == (file ? 3 : 0));
        free(hashes); assert(outstanding == 0);

        for (int failure = 0; failure < 4; failure++) {
            reset();
            MachO *second = &fat.slices[1];
            if (failure == 0) second->loadError = EIO;
            if (failure == 1) second->readFailure = true;
            if (failure == 2) second->decodeFailure = true;
            if (failure == 3) second->hashFailure = true;
            hashes = (void *)(uintptr_t)1; count = 99;
            assert(collect(file, &hashes, &count) == ENOEXEC);
            assert(!hashes && count == 0 && outstanding == 0);
            assert(growCalls == 1); /* Stop before publishing an incomplete set. */
        }
        for (int skipped = 0; skipped < 4; skipped++) {
            reset();
            if (skipped == 0) fat.slices[1].hasSignature = false;
            if (skipped == 1) fat.slices[1].adhoc = false;
            if (skipped == 2) fat.slices[1].cached = true;
            if (skipped == 3) fat.slices[1].mappable = false;
            assert(collect(file, &hashes, &count) == 0 && count == 2);
            assert(randomizations == (file ? 2 : 0));
            free(hashes); assert(outstanding == 0);
        }
        for (int allocation = 0; allocation < 3; allocation++) {
            reset(); failGrow = allocation;
            assert(collect(file, &hashes, &count) == ENOMEM);
            assert(!hashes && count == 0 && outstanding == 0);
        }
        reset(); fat.count = 0;
        assert(collect(file, &hashes, &count) == 0 && !hashes && count == 0);
    }
    reset(); fat.slices[1].randomizeError = EACCES;
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == EACCES);
    assert(!hashes && !count && outstanding == 0 && randomizations == 2);
    reset(); pathError = EACCES;
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == EACCES);
    assert(!hashes && !count && streamsFreed == 0);
    reset(); streamFailure = true;
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == ENOMEM);
    assert(!hashes && !count && streamsFreed == 0);
    reset(); fatFailure = true;
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == ENOEXEC);
    assert(!hashes && !count && streamsFreed == 1 && fatsFreed == 0);
    reset(); filePath = "/private/preboot/Cryptexes/test";
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == 0);
    assert(!hashes && !count && blobReads == 0);
    reset(); removable = true;
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == 0);
    assert(!hashes && !count && blobReads == 0);
    trollstore = true;
    assert(file_collect_untrusted_cdhashes(77, &hashes, &count) == 0 && count == 3);
    free(hashes);
    reset(); openFailure = true;
    assert(file_collect_untrusted_cdhashes_by_path(filePath, &hashes, &count) == ENOENT);
    assert(!hashes && !count && closeCalls == 0);
    reset(); fat.slices[0].readFailure = true;
    assert(file_collect_untrusted_cdhashes_by_path(filePath, &hashes, &count) == ENOEXEC);
    assert(closeCalls == 1 && !hashes && !count && outstanding == 0);
    reset();
    assert(file_collect_untrusted_cdhashes_by_path(filePath, &hashes, &count) == 0);
    assert(closeCalls == 1 && count == 3); free(hashes);
    assert(outstanding == 0);
    puts("PASS: signature tri-state, partial-result cleanup, allocation faults and preserved RC9 file policy");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    code = "\n".join((
        NATIVE_PREFIX,
        *(extract(source(SIGNATURES), anchor) for anchor in (
            "static int macho_read_code_signature_checked(",
            "static int macho_collect_adhoc_cdhash(",
            "bool macho_parse_code_signature(",
            "int fat_collect_untrusted_cdhashes(",
            "int file_collect_untrusted_cdhashes(",
            "int file_collect_untrusted_cdhashes_by_path(",
        )),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-signature-collection-") as tmp:
        path = Path(tmp) / "signatures.c"
        binary = Path(tmp) / "signatures-test"
        path.write_text(code, encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-fblocks", "-Wall", "-Wextra",
                        "-Werror", "-Wno-unused-parameter", "-O1", "-g",
                        "-fsanitize=address,undefined", str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SignatureCollectionContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
