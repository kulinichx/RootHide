"""Real fixed ChOma load-command and path enumerators with bounded fault I/O.

Uses production types, buffered streams and parser functions. Does not execute
Mach-O initialization, segment parsing, DSC translation, dyld or iOS kernels.
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
DEPENDENCY = ROOT / "BaseBin/ChOma"
PIN = "ed99ac526142e78a5bc99793cf433775040f9d67"
PATCH = ".github/patches/ChOma-signature-boundaries.patch"


class LoadCommandContracts(unittest.TestCase):
    def test_fixed_patch_carries_enumerator_changes_and_ci_provenance(self):
        patch = source(PATCH)
        self.assertIn("diff --git a/src/MachO.c b/src/MachO.c", patch)
        workflow = source(".github/workflows/roothide.yml")
        self.assertIn("python3 tests/test_rc9_choma_load_commands.py --native", workflow)
        self.assertIn("shasum -a 256 BaseBin/ChOma/src/MachO.c", workflow)

    def test_command_bounds_read_failures_and_shape_changes_are_checked(self):
        patch = source(PATCH)
        for token in ("!macho || !macho->stream || !enumeratorBlock",
                      "streamSize == MEMORY_STREAM_SIZE_INVALID",
                      "macho->machHeader.sizeofcmds > streamSize - headerSize",
                      "sizeof(struct load_command) > commandsEnd - offset",
                      "loadCommand.cmdsize < sizeof(struct load_command)",
                      "loadCommand.cmdsize > commandsEnd - offset",
                      "void *cmd = malloc(loadCommand.cmdsize);",
                      "readCommand.cmd != loadCommand.cmd",
                      "readCommand.cmdsize != loadCommand.cmdsize"):
            self.assertIn(token, patch)

    def test_path_headers_and_terminators_precede_callback(self):
        patch = source(PATCH)
        for token in ("loadCommand.cmdsize < sizeof(struct dylib_command)",
                      "loadCommand.cmdsize < sizeof(struct rpath_command)",
                      "dependencyLength == available", "rpathLength == available",
                      "return status != 0 ? status : result;"):
            self.assertIn(token, patch)
        self.assertIn("-            if (dependencyPath[dependencyLength] != 0)", patch)
        self.assertIn("-            if (rpath[rpathLength] != 0)", patch)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int outstanding, allocCalls, failAlloc = -1;
static void *test_malloc(size_t size) {
    if (allocCalls++ == failAlloc) return NULL;
    void *p = malloc(size);
    assert(p);
    outstanding++;
    return p;
}
static void test_free(void *p) {
    if (p) { assert(outstanding > 0); outstanding--; free(p); }
}
// Instrument the actual MemoryStream callback declaration and implementation together.
#define malloc test_malloc
#define free test_free
#include "MachO.h"
#include "MachOByteOrder.h"
#include "MachOLoadCommand.h"
#include "BufferedStream.h"

// These DSC-only branches are deliberately not exercised by standalone fixtures.
int macho_translate_fileoff_to_vmaddr(MachO *macho, uint64_t offset,
        uint64_t *address, MachOSegment **segment) {
    assert(!"DSC translation is outside this regression");
    return -1;
}
int macho_read_at_vmaddr(MachO *macho, uint64_t address, size_t size, void *out) {
    assert(!"DSC reading is outside this regression");
    return -1;
}
'''


NATIVE_MAIN = r'''
static uint8_t fixture[128];
static MachO macho;
static int readCalls, failRead, shortRead, mutateRead, mutateField, visits;
static int (*backingRead)(MemoryStream *, uint64_t, size_t, void *);

static void put32(void *p, uint32_t value) {
    value = OSSwapHostToLittleInt32(value);
    memcpy(p, &value, sizeof(value));
}
static int fault_read(MemoryStream *stream, uint64_t offset, size_t size, void *out) {
    int call = readCalls++;
    if (call == failRead) return -1;
    int result = backingRead(stream, offset, size, out);
    if (call == shortRead) return result - 1;
    if (call == mutateRead) {
        assert(size == 32);
        put32((uint8_t *)out + (mutateField ? 4 : 0), mutateField ? 8 : LC_UUID);
    }
    return result;
}
static int fail_size(MemoryStream *stream, size_t *out) {
    return -1;
}
static void reset(uint32_t command) {
    assert(outstanding == 0);
    allocCalls = 0;
    failAlloc = -1;
    readCalls = visits = 0;
    failRead = shortRead = mutateRead = -1;
    memset(fixture, 0, sizeof(fixture));
    memset(&macho, 0, sizeof(macho));
    macho.machHeader.ncmds = 3;
    macho.machHeader.sizeofcmds = 96;
    for (int i = 0; i < 3; i++) {
        uint8_t *cmd = fixture + 32 + i * 32;
        uint32_t header = command == LC_RPATH ? sizeof(struct rpath_command) :
                                                sizeof(struct dylib_command);
        put32(cmd, command);
        put32(cmd + 4, 32);
        put32(cmd + 8, header);
        memcpy(cmd + header, "path", 5);
    }
    macho.stream = buffered_stream_init_from_buffer_nocopy(fixture, sizeof(fixture), 0);
    assert(macho.stream);
    backingRead = macho.stream->read;
    macho.stream->read = fault_read;
    allocCalls = 0;
}
static void finish(void) {
    memory_stream_free(macho.stream);
    assert(outstanding == 0);
}
static int enumerate(int kind, bool stopFirst) {
    if (kind == 0) return macho_enumerate_load_commands(&macho,
            ^(struct load_command command, uint64_t offset, void *data, bool *stop) {
        assert(data && offset == (uint64_t)(32 + visits * 32));
        visits++;
        if (stopFirst) *stop = true;
    });
    if (kind == 1) return macho_enumerate_dependencies(&macho,
            ^(const char *path, uint32_t command, struct dylib *dylib, bool *stop) {
        assert(path && path[0] && dylib);
        visits++;
        if (stopFirst) *stop = true;
    });
    return macho_enumerate_rpaths(&macho, ^(const char *path, bool *stop) {
        assert(path && path[0]);
        visits++;
        if (stopFirst) *stop = true;
    });
}
int main(void) {
    for (int kind = 0; kind < 3; kind++) {
        uint32_t command = kind == 2 ? LC_RPATH : LC_LOAD_DYLIB;
        reset(command);
        assert(enumerate(kind, false) == 0 && visits == 3 && readCalls == 6);
        assert(outstanding == 2);
        finish();

        reset(command);
        put32(fixture + 32 + 32 + 4, 0);
        assert(enumerate(kind, true) == 0 && visits == 1 && readCalls == 2);
        finish();

        for (int position = 0; position < 6; position++) {
            for (int shortness = 0; shortness < 2; shortness++) {
                reset(command);
                if (shortness) shortRead = position;
                else failRead = position;
                assert(enumerate(kind, false) == -1 && visits == position / 2);
                assert(readCalls == position + 1 && outstanding == 2);
                finish();
            }
        }
        for (int position = 0; position < 3; position++) {
            reset(command);
            failAlloc = position;
            assert(enumerate(kind, false) == -1 && visits == position && outstanding == 2);
            finish();
            for (int field = 0; field < 2; field++) {
                reset(command);
                mutateRead = position * 2 + 1;
                mutateField = field;
                assert(enumerate(kind, false) == -1 && visits == position && outstanding == 2);
                finish();
            }
            for (int malformed = 0; malformed < 4; malformed++) {
                reset(command);
                uint32_t sizes[] = {0, 7, UINT32_MAX, 97};
                put32(fixture + 32 + position * 32 + 4, sizes[malformed]);
                assert(enumerate(kind, false) == -1 && visits == position && outstanding == 2);
                finish();
            }
        }
        for (int invalid = 0; invalid < 6; invalid++) {
            reset(command);
            if (invalid == 0) macho.machHeader.ncmds = 0;
            if (invalid == 1) macho.machHeader.ncmds = 1001;
            if (invalid == 2) macho.machHeader.sizeofcmds = UINT32_MAX;
            if (invalid == 3) macho.stream->getSize = fail_size;
            if (invalid == 4) {
                BufferedStreamContext *context = macho.stream->context;
                context->subBufferSize = 31;
            }
            if (invalid == 5) macho.machHeader.sizeofcmds = 7;
            assert(enumerate(kind, false) == -1 && visits == 0 && readCalls == 0);
            finish();
        }
        reset(command);
        macho.machHeader.sizeofcmds = 71;
        assert(enumerate(kind, false) == -1 && visits == 2 && readCalls == 4);
        finish();
    }

    for (int kind = 1; kind < 3; kind++) {
        uint32_t command = kind == 2 ? LC_RPATH : LC_LOAD_DYLIB;
        uint32_t header = kind == 2 ? sizeof(struct rpath_command) : sizeof(struct dylib_command);
        for (int position = 0; position < 3; position++) {
            for (uint32_t size = 8; size < header; size++) {
                reset(command);
                put32(fixture + 32 + position * 32 + 4, size);
                assert(enumerate(kind, false) == -1 && visits == position && outstanding == 2);
                finish();
            }
            for (int malformed = 0; malformed < 6; malformed++) {
                reset(command);
                uint8_t *cmd = fixture + 32 + position * 32;
                if (malformed == 0) put32(cmd + 8, 0);
                if (malformed == 1) put32(cmd + 8, header - 1);
                if (malformed == 2) put32(cmd + 8, 32);
                if (malformed == 3) put32(cmd + 8, UINT32_MAX);
                if (malformed == 4) cmd[header] = 0;
                if (malformed == 5) memset(cmd + header, 'x', 32 - header);
                assert(enumerate(kind, false) == -1 && visits == position && outstanding == 2);
                finish();
            }
        }
        reset(command);
        for (int i = 0; i < 3; i++) {
            uint8_t *cmd = fixture + 32 + i * 32;
            memset(cmd + header, 'x', 32 - header);
            cmd[31] = 0;
        }
        assert(enumerate(kind, false) == 0 && visits == 3);
        finish();
    }
    const uint32_t dependencies[] = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
        LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB};
    for (size_t i = 0; i < sizeof(dependencies) / sizeof(dependencies[0]); i++) {
        reset(dependencies[i]);
        assert(enumerate(1, false) == 0 && visits == 3);
        assert(macho_enumerate_rpaths(&macho, ^(const char *path, bool *stop) {
            assert(!"Not an rpath");
        }) == 0);
        finish();
    }
    reset(LC_LOAD_DYLIB);
    put32(fixture + 32, 0x7ffffffe);
    assert(enumerate(1, false) == 0 && visits == 2 && readCalls == 5);
    finish();
    assert(macho_enumerate_load_commands(NULL, NULL) == -1);
    assert(macho_enumerate_dependencies(NULL, NULL) == -1);
    assert(macho_enumerate_rpaths(NULL, NULL) == -1);
    memset(&macho, 0, sizeof(macho));
    assert(enumerate(0, false) == -1);
    puts("PASS: real load-command/path parsers, bounded names, read/allocation faults, shape changes and cleanup");
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
    macho = (directory / "MachO.c").read_text(encoding="utf-8")
    memory = (directory / "MemoryStream.c").read_text(encoding="utf-8")
    commands = (directory / "MachOLoadCommand.c").read_text(encoding="utf-8")
    code = "\n".join((
        NATIVE_PREFIX, '#include "BufferedStream.c"',
        # Limit the legacy int/size_t warning exception to unmodified stream helpers.
        '#pragma clang diagnostic push',
        '#pragma clang diagnostic ignored "-Wsign-compare"',
        *(extract(memory, anchor) for anchor in (
            "int memory_stream_read(", "size_t memory_stream_get_size(",
            "void memory_stream_free(")),
        '#pragma clang diagnostic pop',
        extract(commands, "char *load_command_to_string("),
        *(extract(macho, anchor) for anchor in (
            "size_t macho_get_mach_header_size(",
            "size_t macho_get_mach_header_and_commands_size(",
            "int macho_read_at_offset(", "int macho_enumerate_load_commands(",
            "int macho_enumerate_dependencies(", "int macho_enumerate_rpaths(")),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-choma-load-commands-") as tmp:
        path = Path(tmp) / "load-commands.c"
        binary = Path(tmp) / "load-commands-test"
        path.write_text(code, encoding="utf-8")
        try:
            subprocess.run([
                compiler, "-std=gnu11", "-fblocks", "-Wall", "-Wextra", "-Werror",
                "-Wno-unused-parameter", "-O1", "-g", "-fsanitize=address,undefined",
                "-I", str(directory), str(path), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, timeout=30,
                                    capture_output=True, text=True)
            print(result.stdout.strip())
        except subprocess.CalledProcessError as error:
            diagnostic = (error.stdout or "") + (error.stderr or "")
            sys.stderr.write(diagnostic)
            encoded = diagnostic.strip().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=ChOma load-command regression::{encoded[:3000]}")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(LoadCommandContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
