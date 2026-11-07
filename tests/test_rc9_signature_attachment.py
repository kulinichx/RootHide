"""Signature attachment failure-path regressions from the production C function."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


SIGNATURES = "BaseBin/libjailbreak/src/signatures.c"


class SignatureAttachmentContracts(unittest.TestCase):
    def test_encoding_failure_preserves_original_blob_and_fails(self):
        body = extract(source(SIGNATURES), "int trust_signatures(")
        encode = body.index("CS_SuperBlob *encodedSuperblob = csd_superblob_encode(decodedSuperblob);")
        failure = body.index("if (!encodedSuperblob)", encode)
        original_free = body.index("free(curSigInfo->signature.fs_blob_start);", encode)
        self.assertLess(encode, failure)
        self.assertLess(failure, original_free)
        self.assertIn("csd_superblob_free(decodedSuperblob);", body[failure:original_free])
        self.assertIn("free(cdhashes);", body[failure:original_free])
        self.assertIn("free(sigInfosToAttach);", body[failure:original_free])
        self.assertIn("return -2;", body[failure:original_free])
        self.assertIn("curSigInfo->signature.fs_blob_start = encodedSuperblob;", body)

    def test_native_regression_is_required_by_ci(self):
        workflow = source(".github/workflows/roothide.yml")
        self.assertIn("python3 tests/test_rc9_signature_attachment.py --native", workflow)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef uint8_t cdhash_t[20];
enum { CS_ADHOC = 2, SIGNATURE_SOURCE_ALLOCATION = 0, SPTMArgs = 1 };
typedef struct {
    uint32_t length;
    uint32_t flags;
    bool adhoc;
} CS_SuperBlob;
typedef struct { uint32_t flags; } CS_DecodedBlob;
typedef struct { CS_DecodedBlob best; bool adhoc; } CS_DecodedSuperBlob;
typedef struct {
    void *fs_blob_start;
    uint32_t fs_blob_size;
} fsignatures_t;
struct siginfo {
    int source;
    fsignatures_t signature;
};

static int outstanding, encodeFailure, trustCalls, attachCalls;
static uint32_t addedHashCount;

static void *tracked_malloc(size_t size) {
    void *p = malloc(size);
    if (p) outstanding++;
    return p;
}

static void tracked_free(void *p) {
    if (p) {
        assert(outstanding > 0);
        outstanding--;
        free(p);
    }
}

static CS_SuperBlob *siginfo_resolve_superblob(struct siginfo *info, int pid, int fd) {
    (void)pid;
    (void)fd;
    if (!info || !info->signature.fs_blob_start) return NULL;
    CS_SuperBlob *copy = tracked_malloc(sizeof(*copy));
    if (copy) memcpy(copy, info->signature.fs_blob_start, sizeof(*copy));
    return copy;
}

static CS_DecodedSuperBlob *csd_superblob_decode(CS_SuperBlob *blob) {
    CS_DecodedSuperBlob *decoded = tracked_malloc(sizeof(*decoded));
    if (!decoded) return NULL;
    decoded->best.flags = blob->flags;
    decoded->adhoc = blob->adhoc;
    return decoded;
}

static bool csd_superblob_is_adhoc_signed(CS_DecodedSuperBlob *blob) {
    return blob->adhoc;
}

static CS_DecodedBlob *csd_superblob_find_best_code_directory(CS_DecodedSuperBlob *blob) {
    return &blob->best;
}

static uint32_t csd_code_directory_get_flags(CS_DecodedBlob *blob) {
    return blob->flags;
}

static char *csd_code_directory_copy_team_id(CS_DecodedBlob *blob, size_t *length) {
    (void)blob;
    (void)length;
    return NULL;
}

static void csd_code_directory_set_flags(CS_DecodedBlob *blob, uint32_t flags) {
    blob->flags = flags;
}

static CS_SuperBlob *csd_superblob_encode(CS_DecodedSuperBlob *decoded) {
    if (encodeFailure) return NULL;
    CS_SuperBlob *blob = tracked_malloc(sizeof(*blob));
    if (!blob) return NULL;
    blob->length = 64;
    blob->flags = decoded->best.flags;
    blob->adhoc = decoded->adhoc;
    return blob;
}

static void csd_superblob_free(CS_DecodedSuperBlob *decoded) {
    tracked_free(decoded);
}

static void csd_code_directory_calculate_hash(CS_DecodedBlob *blob, uint8_t *hash) {
    memset(hash, (int)blob->flags, sizeof(cdhash_t));
}

static bool is_cdhash_trustcached(cdhash_t hash) {
    (void)hash;
    return false;
}

static int jb_trustcache_add_cdhashes(cdhash_t *hashes, uint32_t count) {
    assert(hashes);
    trustCalls++;
    addedHashCount = count;
    return 0;
}

static int ksymbol(int symbol) {
    assert(symbol == SPTMArgs);
    return 1;
}

static uint32_t OSSwapBigToHostInt32(uint32_t value) {
    return value;
}

static int fd_attach_signature(int fd, fsignatures_t *signature) {
    assert(fd == 12 && signature && signature->fs_blob_start);
    attachCalls++;
    return 0;
}

#define malloc tracked_malloc
#define free tracked_free
'''

NATIVE_MAIN = r'''
int main(void) {
    struct siginfo info = {0};
    info.source = SIGNATURE_SOURCE_ALLOCATION;
    CS_SuperBlob *original = tracked_malloc(sizeof(*original));
    assert(original);
    original->length = 24;
    original->flags = 0;
    original->adhoc = true;
    info.signature.fs_blob_start = original;
    info.signature.fs_blob_size = sizeof(*original);

    encodeFailure = 1;
    assert(trust_signatures(42, 12, &info, 1) == -2);
    assert(info.signature.fs_blob_start == original);
    assert(original->length == 24 && original->flags == 0);
    assert(trustCalls == 0 && attachCalls == 0 && outstanding == 1);
    tracked_free(original);
    assert(outstanding == 0);

    info = (struct siginfo){0};
    original = tracked_malloc(sizeof(*original));
    assert(original);
    original->length = 24;
    original->flags = 0;
    original->adhoc = true;
    info.source = SIGNATURE_SOURCE_ALLOCATION;
    info.signature.fs_blob_start = original;
    info.signature.fs_blob_size = sizeof(*original);
    encodeFailure = 0;

    assert(trust_signatures(42, 12, &info, 1) == 0);
    assert(info.signature.fs_blob_start != original);
    assert(info.signature.fs_blob_size == 64);
    assert(trustCalls == 1 && addedHashCount == 1 && attachCalls == 1);
    assert(outstanding == 1);
    tracked_free(info.signature.fs_blob_start);
    assert(outstanding == 0);

    assert(trust_signatures(42, 12, NULL, 0) == 0);
    puts("PASS: failed signature encoding preserves the original blob and returns an error");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    code = "\n".join((
        NATIVE_PREFIX,
        extract(source(SIGNATURES), "int trust_signatures("),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-signature-attachment-") as tmp:
        path = Path(tmp) / "signature-attachment.c"
        binary = Path(tmp) / "signature-attachment-test"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-parameter", "-O1", "-g",
                            "-fsanitize=address,undefined", str(path), "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, timeout=30,
                           capture_output=True, text=True)
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            if not diagnostic:
                diagnostic = f"native command exited with status {error.returncode}"
            encoded = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Signature attachment native regression::{encoded[:3000]}")
            sys.stderr.write(diagnostic)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SignatureAttachmentContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
