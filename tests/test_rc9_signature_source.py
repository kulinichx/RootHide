"""Signature-source reads, not ChOma parsing or iOS kernel ABI validation."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


SIGNATURES = "BaseBin/libjailbreak/src/signatures.c"


class SignatureSourceContracts(unittest.TestCase):
    def test_file_reads_preserve_shared_offset_and_handle_partial_reads(self):
        body = extract(source(SIGNATURES), "CS_SuperBlob *siginfo_resolve_superblob(")
        self.assertIn("pread(fd,", body)
        self.assertNotIn("lseek(", body)
        self.assertIn("while (bytesRead < superblobSize)", body)
        self.assertIn("errno == EINTR", body)
        self.assertIn("if (r <= 0) break;", body)
        self.assertIn("success = bytesRead == superblobSize;", body)

    def test_file_ranges_are_checked_before_unsigned_addition(self):
        body = extract(source(SIGNATURES), "CS_SuperBlob *siginfo_resolve_superblob(")
        self.assertIn("siginfo->signature.fs_file_start < 0 || st.st_size < 0", body)
        bound = body.index("blobOffset > fileSize - fileStart")
        addition = body.index("uint64_t superblobStart = fileStart + blobOffset;")
        self.assertLess(bound, addition)
        self.assertIn("superblobSize > fileSize - superblobStart", body)
        self.assertIn("if (!siginfo->signature.fs_blob_start) break;", body)

    def test_native_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_signature_source.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

// The extracted resolver only copies bytes; no ChOma layout is simulated.
typedef struct CS_SuperBlob CS_SuperBlob;
enum { SIGNATURE_SOURCE_ALLOCATION, SIGNATURE_SOURCE_FILE, SIGNATURE_SOURCE_PROC };
struct siginfo {
    int source;
    struct { off_t fs_file_start; void *fs_blob_start; size_t fs_blob_size; } signature;
};

static int outstanding, failAllocation, statFailure, negativeSize;
static int readCalls, interruptOnce, shortReads, stopAfterFirst, processReadFailure;
static uint8_t fileBytes[64], processBytes[16];

static void *tracked_malloc(size_t size) {
    if (failAllocation) return NULL;
    void *p = malloc(size);
    assert(p);
    outstanding++;
    return p;
}
static void tracked_free(void *p) {
    if (p) { assert(outstanding > 0); outstanding--; free(p); }
}
static int test_fstat(int fd, struct stat *st) {
    if (statFailure) { errno = EIO; return -1; }
    int r = fstat(fd, st);
    if (r == 0 && negativeSize) st->st_size = -1;
    return r;
}
static ssize_t test_pread(int fd, void *buffer, size_t size, off_t offset) {
    readCalls++;
    if (interruptOnce) { interruptOnce = 0; errno = EINTR; return -1; }
    if (stopAfterFirst && readCalls > 1) {
        if (stopAfterFirst == 1) { errno = EIO; return -1; }
        return 0;
    }
    if (shortReads && size > 3) size = 3;
    return pread(fd, buffer, size, offset);
}
static uint64_t proc_find(int pid) { return pid == 42 ? 0x100 : 0; }
static int proc_vreadbuf(uint64_t proc, void *address, void *out, size_t size) {
    assert(proc == 0x100 && address == (void *)(uintptr_t)0x1000);
    assert(size == sizeof(processBytes));
    if (processReadFailure) return -1;
    memcpy(out, processBytes, size);
    return 0;
}
#define malloc tracked_malloc
#define free tracked_free
#define fstat test_fstat
#define pread test_pread
'''

NATIVE_MAIN = r'''
static void reset(void) {
    assert(outstanding == 0);
    failAllocation = statFailure = negativeSize = readCalls = 0;
    interruptOnce = shortReads = stopAfterFirst = processReadFailure = 0;
}
static struct siginfo file_info(void) {
    return (struct siginfo){
        .source = SIGNATURE_SOURCE_FILE,
        .signature = { .fs_file_start = 5,
            .fs_blob_start = (void *)(uintptr_t)9, .fs_blob_size = 12 },
    };
}
static void expect_file_failure(struct siginfo *info, int fd) {
    assert(siginfo_resolve_superblob(info, 42, fd) == NULL);
    assert(lseek(fd, 0, SEEK_CUR) == 7);
    assert(outstanding == 0);
}
int main(void) {
    for (size_t i = 0; i < sizeof(fileBytes); i++) fileBytes[i] = (uint8_t)i;
    for (size_t i = 0; i < sizeof(processBytes); i++) processBytes[i] = (uint8_t)(i + 100);
    char path[] = "/tmp/rc9-signature-source-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && unlink(path) == 0);
    assert(write(fd, fileBytes, sizeof(fileBytes)) == sizeof(fileBytes));
    assert(lseek(fd, 7, SEEK_SET) == 7);

    reset();
    assert(siginfo_resolve_superblob(NULL, 42, fd) == NULL);
    struct siginfo info = file_info();
    for (int mode = 0; mode < 3; mode++) {
        reset();
        shortReads = mode > 0;
        interruptOnce = mode == 2;
        CS_SuperBlob *blob = siginfo_resolve_superblob(&info, 42, fd);
        assert(blob && memcmp(blob, fileBytes + 14, 12) == 0);
        assert(lseek(fd, 0, SEEK_CUR) == 7);
        if (mode == 1) assert(readCalls == 4);
        if (mode == 2) assert(readCalls == 5);
        free(blob);
    }

    // Range checks reject wraparound and out-of-file requests before any read.
    for (int bad = 0; bad < 8; bad++) {
        reset();
        info = file_info();
        if (bad == 0) info.signature.fs_file_start = -1;
        if (bad == 1) info.signature.fs_file_start = LLONG_MAX;
        if (bad == 2) info.signature.fs_blob_start = (void *)UINTPTR_MAX;
        if (bad == 3) info.signature.fs_blob_start = (void *)(uintptr_t)60;
        if (bad == 4) info.signature.fs_blob_size = sizeof(fileBytes);
        if (bad == 5) info.signature.fs_blob_size = 0;
        if (bad == 6) statFailure = 1;
        if (bad == 7) negativeSize = 1;
        expect_file_failure(&info, fd);
        assert(readCalls == 0);
    }
    for (int failure = 1; failure <= 2; failure++) {
        reset();
        info = file_info();
        shortReads = 1;
        stopAfterFirst = failure;
        expect_file_failure(&info, fd);
        assert(readCalls == 2);
    }
    reset();
    info = file_info();
    failAllocation = 1;
    expect_file_failure(&info, fd);
    assert(readCalls == 0);
    reset();
    info = file_info();
    assert(siginfo_resolve_superblob(&info, 42, -1) == NULL && outstanding == 0);

    reset();
    info = (struct siginfo){ .source = SIGNATURE_SOURCE_ALLOCATION,
        .signature = { .fs_blob_start = fileBytes, .fs_blob_size = sizeof(fileBytes) } };
    CS_SuperBlob *blob = siginfo_resolve_superblob(&info, 42, fd);
    assert(blob && memcmp(blob, fileBytes, sizeof(fileBytes)) == 0);
    free(blob);
    info.signature.fs_blob_start = NULL;
    assert(siginfo_resolve_superblob(&info, 42, fd) == NULL && outstanding == 0);

    reset();
    info = (struct siginfo){ .source = SIGNATURE_SOURCE_PROC,
        .signature = { .fs_blob_start = (void *)(uintptr_t)0x1000,
            .fs_blob_size = sizeof(processBytes) } };
    blob = siginfo_resolve_superblob(&info, 42, fd);
    assert(blob && memcmp(blob, processBytes, sizeof(processBytes)) == 0);
    free(blob);
    processReadFailure = 1;
    assert(siginfo_resolve_superblob(&info, 42, fd) == NULL && outstanding == 0);
    processReadFailure = 0;
    assert(siginfo_resolve_superblob(&info, 43, fd) == NULL && outstanding == 0);
    info.source = 99;
    assert(siginfo_resolve_superblob(&info, 42, fd) == NULL && outstanding == 0);
    assert(lseek(fd, 0, SEEK_CUR) == 7);
    assert(close(fd) == 0);
    puts("PASS: signature-source bounds, positional reads and failure cleanup");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    code = "\n".join((
        NATIVE_PREFIX,
        extract(source(SIGNATURES), "CS_SuperBlob *siginfo_resolve_superblob("),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-signature-source-") as tmp:
        path = Path(tmp) / "signature-source.c"
        binary = Path(tmp) / "signature-source-test"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                            "-O1", "-g", "-fsanitize=address,undefined",
                            str(path), "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, timeout=30,
                           capture_output=True, text=True)
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            sys.stderr.write(diagnostic)
            encoded = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Signature source native regression::{encoded[:3000]}")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SignatureSourceContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
