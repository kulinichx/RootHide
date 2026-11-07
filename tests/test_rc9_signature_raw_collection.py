"""Raw signature collection: production functions and headers, mocked I/O.

The native regression does not validate ChOma parsing, kernel operations or the
iOS ABI. Parser implementation regressions live in test_rc9_choma_boundaries.
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
SIGNATURES = "BaseBin/libjailbreak/src/signatures.c"


class RawSignatureContracts(unittest.TestCase):
    def test_checked_reader_distinguishes_absence_and_failure(self):
        body = extract(source(SIGNATURES), "static int macho_read_code_signature_checked(")
        for token in ("*superblobOut = NULL;", "if (!macho) return -1;",
                      "LC_CODE_SIGNATURE", "if (status != 0) return -1;",
                      "if (!hasSignature) return 0;", "return *superblobOut ? 1 : -1;"):
            self.assertIn(token, body)

    def test_raw_collector_propagates_errors_and_keeps_complete_outputs_only(self):
        body = extract(source(SIGNATURES), "int fat_collect_signatures(")
        for token in ("macho_read_code_signature_checked(macho, &superblob)",
                      "if (signatureResult < 0)", "status = ENOEXEC;",
                      "if (signatureResult > 0)", "*stop = true;"):
            self.assertIn(token, body)
        failure = body.index("if (status != 0) {\n\t\tfor (uint32_t i")
        self.assertLess(failure, body.index("*sigInfosOut = sigInfos;"))
        self.assertIn("free(sigInfos[i].signature.fs_blob_start);", body[failure:])
        self.assertIn("free(sigInfos);", body[failure:])
        self.assertLess(body.index("*sigInfosOut = NULL;"), body.index("if (!fat)"))

    def test_growth_is_bounded_and_failed_growth_releases_current_blob(self):
        body = extract(source(SIGNATURES), "int fat_collect_signatures(")
        self.assertIn("sigInfoCount == UINT32_MAX", body)
        self.assertIn("status = EOVERFLOW;", body)
        self.assertIn("((size_t)sigInfoCount + 1) * sizeof(struct siginfo)", body)
        failure = body.index("if (!newSigInfos)")
        self.assertIn("free(superblob);", body[failure:body.index("sigInfos = newSigInfos;")])
        self.assertIn("status = ENOMEM;", body)

    def test_file_wrapper_and_live_consumer_preserve_failure_status(self):
        wrapper = extract(source(SIGNATURES), "int file_collect_signatures(")
        self.assertIn("int status = fat_collect_signatures(", wrapper)
        self.assertIn("fat_free(fat);", wrapper)
        self.assertIn("return status;", wrapper)
        consumer = extract(source("BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c"),
                           "int systemwide_trust_file(")
        failure = consumer.index("if (signatureStatus != 0)")
        trust = consumer.index("int r = trust_signatures(")
        self.assertLess(failure, trust)
        self.assertIn("close(fd);", consumer[failure:trust])
        self.assertIn("return signatureStatus;", consumer[failure:trust])

    def test_rc9_successful_collection_metadata_and_native_ci_are_preserved(self):
        body = extract(source(SIGNATURES), "int fat_collect_signatures(")
        for token in ("macho_is_mappable(macho)", "SIGNATURE_SOURCE_ALLOCATION",
                      "macho->archDescriptor.offset", "fs_blob_start = superblob",
                      "OSSwapBigToHostInt32(superblob->length)"):
            self.assertIn(token, body)
        self.assertNotIn("csd_superblob_is_adhoc_signed", body)
        self.assertIn("python3 tests/test_rc9_signature_raw_collection.py --native",
                      source(".github/workflows/roothide.yml"))


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include "signatures.h"
#include "FileStream.h"

// Use production types; only external operations and their outcomes are replaced.
typedef struct {
    bool mappable, hasSignature, readFailure;
    int commandError;
} SliceState;
static SliceState states[3];
static MachO slices[3];
static MachO *slicePointers[3];
static MemoryStream stream;
static Fat fat;
static int outstanding, growCalls, failGrow, blobReads, commandScans, sliceVisits;
static int streamCalls, streamsFreed, fatsFreed;
static bool streamFailure, fatFailure;

static void *tracked_malloc(size_t size) {
    void *p = malloc(size);
    assert(p);
    outstanding++;
    return p;
}
static void tracked_free(void *p) {
    if (p) {
        assert(outstanding > 0);
        outstanding--;
        free(p);
    }
}
static void *tracked_realloc(void *p, size_t size) {
    if (growCalls++ == failGrow) return NULL;
    bool isNew = p == NULL;
    void *result = realloc(p, size);
    assert(result);
    if (isNew) outstanding++;
    return result;
}
static SliceState *state_for(MachO *macho) {
    for (size_t i = 0; i < 3; i++) {
        if (macho == &slices[i]) return &states[i];
    }
    assert(!"Unexpected MachO pointer");
    return NULL;
}
static void reset(void) {
    assert(outstanding == 0);
    memset(slices, 0, sizeof(slices));
    memset(states, 0, sizeof(states));
    memset(&fat, 0, sizeof(fat));
    for (size_t i = 0; i < 3; i++) {
        slicePointers[i] = &slices[i];
        slices[i].archDescriptor.offset = i * 4096;
        states[i].mappable = states[i].hasSignature = true;
    }
    fat.slices = slicePointers;
    fat.slicesCount = 3;
    fat.stream = &stream;
    growCalls = blobReads = commandScans = sliceVisits = 0;
    streamCalls = streamsFreed = fatsFreed = 0;
    failGrow = -1;
    streamFailure = fatFailure = false;
}
static bool macho_is_mappable(MachO *macho) {
    return state_for(macho)->mappable;
}
int macho_enumerate_load_commands(MachO *macho,
        void (^visit)(struct load_command, uint64_t, void *, bool *)) {
    SliceState *state = state_for(macho);
    commandScans++;
    if (state->commandError) return state->commandError;
    if (state->hasSignature) {
        bool stop = false;
        struct load_command command = {
            .cmd = LC_CODE_SIGNATURE,
            .cmdsize = sizeof(struct linkedit_data_command)
        };
        visit(command, 0, NULL, &stop);
        assert(stop);
    }
    return 0;
}
CS_SuperBlob *macho_read_code_signature(MachO *macho) {
    SliceState *state = state_for(macho);
    assert(state->hasSignature);
    blobReads++;
    if (state->readFailure) return NULL;
    CS_SuperBlob *blob = tracked_malloc(sizeof(*blob));
    blob->magic = OSSwapHostToBigInt32(CSMAGIC_EMBEDDED_SIGNATURE);
    blob->length = OSSwapHostToBigInt32(sizeof(*blob));
    blob->count = 0;
    return blob;
}
void fat_enumerate_slices(Fat *input, void (^visit)(MachO *, bool *)) {
    assert(input == &fat);
    bool stop = false;
    for (uint32_t i = 0; i < input->slicesCount && !stop; i++) {
        sliceVisits++;
        visit(input->slices[i], &stop);
    }
}
MemoryStream *file_stream_init_from_file_descriptor(
        int fd, uint32_t start, size_t size, uint32_t flags) {
    assert(fd == 77 && start == 0 && size == FILE_STREAM_SIZE_AUTO && flags == 0);
    streamCalls++;
    return streamFailure ? NULL : &stream;
}
Fat *fat_init_from_memory_stream(MemoryStream *input) {
    assert(input == &stream);
    return fatFailure ? NULL : &fat;
}
void memory_stream_free(MemoryStream *input) {
    assert(input == &stream);
    streamsFreed++;
}
void fat_free(Fat *input) {
    assert(input == &fat);
    fatsFreed++;
    memory_stream_free(input->stream);
}
#define free tracked_free
#define realloc tracked_realloc
'''


NATIVE_MAIN = r'''
static int collect(bool fromFile, struct siginfo **infos, uint32_t *count) {
    return fromFile ? file_collect_signatures(77, infos, count) :
        fat_collect_signatures(&fat, infos, count);
}
static void release_infos(struct siginfo *infos, uint32_t count) {
    for (uint32_t i = 0; i < count; i++) {
        assert(infos[i].source == SIGNATURE_SOURCE_ALLOCATION);
        assert(infos[i].signature.fs_blob_size == sizeof(CS_SuperBlob));
        assert(infos[i].signature.fs_blob_start);
        free(infos[i].signature.fs_blob_start);
    }
    free(infos);
    assert(outstanding == 0);
}
int main(void) {
    struct siginfo *infos = (void *)(uintptr_t)1;
    uint32_t count = 99;
    CS_SuperBlob *blob = (void *)(uintptr_t)1;
    reset();
    assert(macho_read_code_signature_checked(NULL, &blob) == -1 && !blob);
    assert(macho_read_code_signature_checked(&slices[0], NULL) == -1);
    assert(fat_collect_signatures(NULL, &infos, &count) == EINVAL);
    assert(!infos && count == 0);
    assert(fat_collect_signatures(&fat, NULL, &count) == EINVAL);
    assert(fat_collect_signatures(&fat, &infos, NULL) == EINVAL);
    assert(file_collect_signatures(77, NULL, &count) == EINVAL);
    assert(file_collect_signatures(77, &infos, NULL) == EINVAL);
    assert(streamCalls == 0 && outstanding == 0);

    for (int fromFile = 0; fromFile < 2; fromFile++) {
        reset();
        assert(collect(fromFile, &infos, &count) == 0 && count == 3);
        assert(outstanding == 4 && blobReads == 3 && commandScans == 3);
        for (uint32_t i = 0; i < count; i++) {
            assert(infos[i].signature.fs_file_start == i * 4096);
        }
        assert(fatsFreed == fromFile && streamsFreed == fromFile);
        release_infos(infos, count);

        // Every failure position must discard all earlier successful slices.
        for (int failure = 0; failure < 2; failure++) {
            for (int index = 0; index < 3; index++) {
                reset();
                if (failure == 0) states[index].commandError = EIO;
                if (failure == 1) states[index].readFailure = true;
                infos = (void *)(uintptr_t)1;
                count = 99;
                assert(collect(fromFile, &infos, &count) == ENOEXEC);
                assert(!infos && count == 0 && outstanding == 0);
                assert(growCalls == index && sliceVisits == index + 1);
                assert(fatsFreed == fromFile && streamsFreed == fromFile);
            }
        }
        for (int index = 0; index < 3; index++) {
            reset();
            failGrow = index;
            assert(collect(fromFile, &infos, &count) == ENOMEM);
            assert(!infos && count == 0 && outstanding == 0);
            assert(growCalls == index + 1 && sliceVisits == index + 1);
        }
        for (int absent = 0; absent < 2; absent++) {
            reset();
            if (absent == 0) states[1].hasSignature = false;
            if (absent == 1) {
                states[1].mappable = false;
                states[1].commandError = EIO;
                states[1].readFailure = true;
            }
            assert(collect(fromFile, &infos, &count) == 0 && count == 2);
            assert(infos[0].signature.fs_file_start == 0);
            assert(infos[1].signature.fs_file_start == 8192);
            assert(blobReads == 2 && commandScans == (absent ? 2 : 3));
            release_infos(infos, count);

            reset();
            for (int i = 0; i < 3; i++) {
                if (absent == 0) states[i].hasSignature = false;
                if (absent == 1) states[i].mappable = false;
            }
            assert(collect(fromFile, &infos, &count) == 0);
            assert(!infos && count == 0 && outstanding == 0 && blobReads == 0);
        }
        reset();
        fat.slicesCount = 0;
        assert(collect(fromFile, &infos, &count) == 0);
        assert(!infos && count == 0 && outstanding == 0);
    }
    reset();
    streamFailure = true;
    assert(file_collect_signatures(77, &infos, &count) == ENOMEM);
    assert(!infos && count == 0 && streamsFreed == 0 && fatsFreed == 0);
    reset();
    fatFailure = true;
    assert(file_collect_signatures(77, &infos, &count) == ENOEXEC);
    assert(!infos && count == 0 && streamsFreed == 1 && fatsFreed == 0);
    puts("PASS: raw signature failures, partial cleanup, absent/unmappable slices and real headers");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler or sys.platform != "darwin":
        raise SystemExit("--native requires macOS clang and the fixed ChOma checkout")
    dependency = ROOT / "BaseBin/ChOma"
    revision = subprocess.check_output(
        ["git", "-C", str(dependency), "rev-parse", "HEAD"], text=True).strip()
    if revision != "ed99ac526142e78a5bc99793cf433775040f9d67":
        raise SystemExit("Native header regression requires RC9's fixed ChOma revision")
    code = "\n".join((
        NATIVE_PREFIX,
        *(extract(source(SIGNATURES), anchor) for anchor in (
            "static int macho_read_code_signature_checked(",
            "int fat_collect_signatures(",
            "int file_collect_signatures(",
        )),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-raw-signature-collection-") as tmp:
        directory = Path(tmp)
        include = directory / "include"
        include.mkdir()
        (include / "choma").symlink_to(dependency / "src", target_is_directory=True)
        path = directory / "raw-signatures.c"
        binary = directory / "raw-signatures-test"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run(
                [compiler, "-std=gnu11", "-fblocks", "-Wall", "-Wextra", "-Werror",
                 "-Wno-unused-parameter", "-O1", "-g", "-fsanitize=address,undefined",
                 "-I", str(include), "-I", str(dependency / "src"),
                 "-I", str(ROOT / "BaseBin/libjailbreak/src"),
                 str(path), "-o", str(binary)],
                check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, timeout=30,
                                    capture_output=True, text=True)
            print(result.stdout.strip())
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            sys.stderr.write(diagnostic)
            encoded = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Raw signature collection regression::{encoded[:3000]}")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(RawSignatureContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
