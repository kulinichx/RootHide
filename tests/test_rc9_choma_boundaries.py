"""Fixed ChOma production codec and stream regressions, not a full parser audit."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_rc9_services import extract, source


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCY = ROOT / "BaseBin/ChOma"
PIN = "ed99ac526142e78a5bc99793cf433775040f9d67"
PATCH = ".github/patches/ChOma-signature-boundaries.patch"


class ChomaBoundaryContracts(unittest.TestCase):
    def test_fixed_dependency_is_not_replaced_by_a_new_revision(self):
        entry = subprocess.check_output(
            ["git", "ls-tree", "HEAD", "BaseBin/ChOma"], cwd=ROOT, text=True)
        self.assertIn(f"160000 commit {PIN}", entry)

    def test_workflow_applies_and_records_the_patch_before_tests(self):
        workflow = source(".github/workflows/roothide.yml")
        apply = workflow.index(f'git -C BaseBin/ChOma apply "$GITHUB_WORKSPACE/{PATCH}"')
        regression = workflow.index("python3 tests/test_rc9_choma_boundaries.py --native")
        self.assertLess(apply, regression)
        self.assertIn(f"shasum -a 256 {PATCH}", workflow)
        self.assertIn("shasum -a 256 BaseBin/ChOma/src/CSBlob.c", workflow)

    def test_patch_has_sized_outer_bounds_and_child_allocation_cleanup(self):
        patch = source(PATCH)
        for token in ("cs_superblob_validate", "availableSize < sizeof(CS_SuperBlob)",
                      "length > availableSize", "count > (length - sizeof(header))",
                      "offset < tableEnd", "childLength > length - offset",
                      "csd_superblob_free(decodedSuperblob);", "if (!blob->stream)",
                      "if (!context)", "free(copy);"):
            self.assertIn(token, patch)

    def test_real_encoder_checks_allocation_and_length_before_writing(self):
        patch = source(PATCH)
        for token in ("if (!decodedSuperblob) return NULL;", "total > UINT32_MAX",
                      "size > UINT32_MAX - total", "if (!superblob) return NULL;",
                      "csd_blob_read(nextBlob, 0, curSize, superblobDataCur) != 0",
                      "if (!bestCDBlob) return -1;"):
            self.assertIn(token, patch)

    def test_trust_consumer_uses_the_known_allocation_size(self):
        body = extract(source("BaseBin/libjailbreak/src/signatures.c"), "int trust_signatures(")
        self.assertIn("csd_superblob_decode_with_size(superblob, curSigInfo->signature.fs_blob_size)", body)
        self.assertNotIn("csd_superblob_decode(superblob)", body)
        self.assertIn("if (!sigInfos) return -1;", body)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CSBlob.h"
#include "CodeDirectory.h"
#include "BufferedStream.h"

static int outstanding, allocCalls, failAt = -1, readCalls;
static uint8_t inputBytes[64];
static uint32_t inputSize = 48;
static int boundFailure, readFailure;
static size_t reportedSize;

static void *test_malloc(size_t size) {
    if (allocCalls++ == failAt) return NULL;
    void *p = malloc(size);
    assert(p);
    outstanding++;
    return p;
}
static void test_free(void *p) {
    if (p) { assert(outstanding > 0); outstanding--; free(p); }
}

// Only Mach-O I/O is substituted; the codec and buffered streams are production.
int macho_find_code_signature_bounds(MachO *macho, uint32_t *offset, uint32_t *size) {
    assert(macho == (MachO *)(uintptr_t)1);
    if (boundFailure) return -1;
    *offset = 0;
    *size = inputSize;
    return 0;
}
int macho_read_at_offset(MachO *macho, uint64_t offset, size_t size, void *out) {
    assert(macho == (MachO *)(uintptr_t)1 && offset == 0);
    assert(out && size <= sizeof(inputBytes));
    readCalls++;
    if (readFailure) return -1;
    memcpy(out, inputBytes, size);
    return 0;
}
unsigned csd_code_directory_calculate_rank(CS_DecodedBlob *blob) {
    (void)blob;
    assert(!"CodeDirectory hashing is outside this outer-container regression");
    return 0;
}
uint8_t csd_code_directory_get_hash_type(CS_DecodedBlob *blob) {
    (void)blob;
    assert(!"A missing CodeDirectory must not be dereferenced");
    return 0;
}
int csd_code_directory_calculate_hash(CS_DecodedBlob *blob, void *out) {
    (void)blob;
    (void)out;
    assert(!"A missing CodeDirectory must not be hashed");
    return -1;
}
#define malloc test_malloc
#define free test_free
'''

NATIVE_MAIN = r'''
static void put32(uint8_t *p, uint32_t value) {
    value = HOST_TO_BIG(value);
    memcpy(p, &value, sizeof(value));
}
static void make_signature(uint8_t *out) {
    memset(out, 0, 48);
    put32(out, CSMAGIC_EMBEDDED_SIGNATURE);
    put32(out + 4, 48);
    put32(out + 8, 2);
    put32(out + 12, CSSLOT_ENTITLEMENTS);
    put32(out + 16, 28);
    put32(out + 20, CSSLOT_SIGNATURESLOT);
    put32(out + 24, 37);
    put32(out + 28, CSMAGIC_EMBEDDED_ENTITLEMENTS);
    put32(out + 32, 9);
    out[36] = 'A';
    put32(out + 37, CSMAGIC_BLOBWRAPPER);
    put32(out + 41, 11);
    memcpy(out + 45, "BCD", 3);
}
static void reset_faults(void) {
    allocCalls = readCalls = boundFailure = readFailure = 0;
    failAt = -1;
    inputSize = 48;
}
static int fail_read(MemoryStream *stream, uint64_t offset, size_t size, void *out) {
    (void)stream; (void)offset; (void)size; (void)out;
    return -1;
}
static int fake_size(MemoryStream *stream, size_t *size) {
    (void)stream;
    *size = reportedSize;
    return 0;
}
int main(void) {
    uint8_t original[48], malformed[48], unaligned[49];
    make_signature(original);
    assert(!cs_superblob_validate(NULL, 0));
    assert(!csd_superblob_decode_with_size(NULL, 0));
    assert(!csd_superblob_decode(NULL));
    assert(!csd_superblob_encode(NULL));

    // Exact-size heap allocations let ASan detect accidental header overreads.
    for (size_t size = 1; size < sizeof(CS_SuperBlob); size++) {
        reset_faults();
        uint8_t *shortBuffer = malloc(size);
        memcpy(shortBuffer, original, size);
        int before = outstanding;
        allocCalls = 0;
        assert(!csd_superblob_decode_with_size((CS_SuperBlob *)shortBuffer, size));
        assert(outstanding == before && allocCalls == 0);
        free(shortBuffer);
        assert(outstanding == 0);
    }
    for (int bad = 0; bad < 9; bad++) {
        reset_faults();
        memcpy(malformed, original, sizeof(malformed));
        if (bad == 0) put32(malformed, 0);
        if (bad == 1) put32(malformed + 4, 11);
        if (bad == 2) put32(malformed + 4, 49);
        if (bad == 3) put32(malformed + 8, UINT32_MAX);
        if (bad == 4) put32(malformed + 16, 12);
        if (bad == 5) put32(malformed + 16, UINT32_MAX);
        if (bad == 6) put32(malformed + 16, 47);
        if (bad == 7) put32(malformed + 32, 7);
        if (bad == 8) put32(malformed + 41, UINT32_MAX);
        assert(!csd_superblob_decode_with_size((CS_SuperBlob *)malformed, sizeof(malformed)));
        assert(outstanding == 0 && allocCalls == 0);
    }
    for (int allocation = 0; allocation < 9; allocation++) {
        reset_faults();
        failAt = allocation;
        assert(!csd_superblob_decode_with_size((CS_SuperBlob *)original, sizeof(original)));
        assert(outstanding == 0);
    }

    reset_faults();
    memcpy(unaligned + 1, original, sizeof(original));
    CS_DecodedSuperBlob *decoded = csd_superblob_decode_with_size(
        (CS_SuperBlob *)(unaligned + 1), sizeof(original));
    assert(decoded && allocCalls == 9 && outstanding == 9);
    assert(decoded->firstBlob && decoded->firstBlob->next && !decoded->firstBlob->next->next);
    int live = outstanding;
    allocCalls = 0;
    failAt = 0;
    assert(!csd_superblob_encode(decoded) && outstanding == live);
    reset_faults();
    CS_SuperBlob *encoded = csd_superblob_encode(decoded);
    assert(encoded && cs_superblob_validate(encoded, sizeof(original)));
    assert(!memcmp(encoded, original, sizeof(original)));
    free(encoded);
    assert(outstanding == live);

    MemoryStream *stream = decoded->firstBlob->stream;
    int (*savedRead)(MemoryStream *, uint64_t, size_t, void *) = stream->read;
    stream->read = fail_read;
    assert(!csd_superblob_encode(decoded) && outstanding == live);
    stream->read = savedRead;
    int (*savedSize)(MemoryStream *, size_t *) = stream->getSize;
    for (int badSize = 0; badSize < 2; badSize++) {
        stream->getSize = fake_size;
        reportedSize = badSize ? UINT32_MAX : 7;
        allocCalls = 0;
        assert(!csd_superblob_encode(decoded) && outstanding == live && allocCalls == 0);
    }
    stream->getSize = savedSize;
    uint8_t hash[20];
    memset(hash, 0xa5, sizeof(hash));
    int type = 99;
    assert(csd_superblob_calculate_best_cdhash(decoded, hash, &type) == -1);
    assert(type == 99 && hash[0] == 0xa5);
    assert(csd_superblob_calculate_best_cdhash(NULL, hash, &type) == -1);
    csd_superblob_free(decoded);
    assert(outstanding == 0);

    reset_faults();
    memcpy(inputBytes, original, sizeof(original));
    encoded = macho_read_code_signature((MachO *)(uintptr_t)1);
    assert(encoded && readCalls == 1);
    free(encoded);
    assert(outstanding == 0);
    for (int failure = 0; failure < 5; failure++) {
        reset_faults();
        memcpy(inputBytes, original, sizeof(original));
        if (failure == 0) inputSize = 11;
        if (failure == 1) failAt = 0;
        if (failure == 2) readFailure = 1;
        if (failure == 3) put32(inputBytes + 4, 49);
        if (failure == 4) boundFailure = 1;
        assert(!macho_read_code_signature((MachO *)(uintptr_t)1) && outstanding == 0);
    }
    reset_faults();
    uint8_t padded[64] = {0};
    memcpy(padded, original, sizeof(original));
    assert(cs_superblob_validate((CS_SuperBlob *)padded, sizeof(padded)));
    put32(padded, CSMAGIC_DETACHED_SIGNATURE);
    decoded = csd_superblob_decode_with_size((CS_SuperBlob *)padded, sizeof(padded));
    assert(decoded && decoded->magic == CSMAGIC_DETACHED_SIGNATURE);
    csd_superblob_free(decoded);
    assert(outstanding == 0);
    puts("PASS: fixed ChOma outer bounds, real codec allocation faults and round-trip");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler or sys.platform != "darwin":
        raise SystemExit("--native requires macOS clang and the fixed patched ChOma checkout")
    revision = subprocess.check_output(
        ["git", "-C", str(DEPENDENCY), "rev-parse", "HEAD"], text=True).strip()
    if revision != PIN:
        raise SystemExit(f"ChOma must remain pinned to {PIN}, got {revision}")
    directory = DEPENDENCY / "src"
    blob = (directory / "CSBlob.c").read_text(encoding="utf-8")
    memory = (directory / "MemoryStream.c").read_text(encoding="utf-8")
    functions = [
        extract(memory, anchor) for anchor in (
            "int memory_stream_read(", "size_t memory_stream_get_size(", "void memory_stream_free(")
    ]
    functions += [
        extract(blob, anchor) for anchor in (
            "CS_SuperBlob *macho_read_code_signature(",
            "CS_DecodedBlob *csd_blob_init(", "int csd_blob_read(",
            "size_t csd_blob_get_size(", "void csd_blob_free(",
            "CS_DecodedSuperBlob *csd_superblob_init(",
            "bool cs_superblob_validate(",
            "CS_DecodedSuperBlob *csd_superblob_decode_with_size(",
            "CS_DecodedSuperBlob *csd_superblob_decode(",
            "CS_SuperBlob *csd_superblob_encode(",
            "CS_DecodedBlob *csd_superblob_find_best_code_directory(",
            "int csd_superblob_calculate_best_cdhash(",
            "void csd_superblob_free(")
    ]
    code = "\n".join([NATIVE_PREFIX, '#include "BufferedStream.c"', *functions, NATIVE_MAIN])
    with tempfile.TemporaryDirectory(prefix="rc9-choma-boundaries-") as tmp:
        path = Path(tmp) / "choma-boundaries.c"
        binary = Path(tmp) / "choma-boundaries-test"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run(
                [compiler, "-std=gnu11", "-fblocks", "-Wall", "-Werror", "-O1", "-g",
                 "-fsanitize=address,undefined", "-I", str(directory), str(path), "-o", str(binary)],
                check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, timeout=30,
                                    capture_output=True, text=True)
            print(result.stdout.strip())
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            sys.stderr.write(diagnostic)
            encoded = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Fixed ChOma boundary regression::{encoded[:3000]}")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ChomaBoundaryContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
