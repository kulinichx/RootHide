"""Focused 3.0.13 backports; --native tests extracted production C functions.

OS calls are mocked. This is not kernel, UIKit, or iOS device validation.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


PRIMITIVES = "BaseBin/libjailbreak/src/primitives.c"
UTIL = "BaseBin/libjailbreak/src/util.c"
MAIN = "BaseBin/systemhook/src/main.c"
SIGNATURES = "BaseBin/libjailbreak/src/signatures.c"


class Upstream313Contracts(unittest.TestCase):
    def test_logd_helper_skips_tweaks_without_disabling_systemhook(self):
        gate = extract(source(MAIN), "bool should_enable_tweaks(void)")
        paths = gate.split("const char *iOS16TweaksDisabledPaths[]", 1)[1].split("};", 1)[0]
        self.assertIn('"/usr/libexec/logd_helper"', paths)
        load = source(MAIN).split("if (should_enable_tweaks())", 1)[1]
        self.assertIn('JBROOT_PATH("/usr/lib/TweakLoader.dylib")', load)
        spawn = source("BaseBin/systemhook/src/common/common.c")
        self.assertNotIn('"/usr/libexec/logd_helper"', spawn)

    def test_process_write_uses_translated_page_table_not_recursive_process_lookup(self):
        body = extract(source(PRIMITIVES), "int proc_vwritebuf(")
        self.assertIn("return vwritebuf(ttep, addr, indata, datalen);", body)
        self.assertNotIn("return proc_vwritebuf(", body)
        for stage in ("task", "map", "pmap", "ttep"):
            self.assertIn(f"if (!{stage}) return -1;", body)

    def test_killall_uses_argument_capacity_and_bounded_path(self):
        body = extract(source(UTIL), "void killall(")
        self.assertIn("if (!executablePath) return;", body)
        self.assertIn("maxArgumentSize <= 0", body)
        self.assertIn("malloc((size_t)maxArgumentSize)", body)
        self.assertIn("size <= sizeof(int)", body)
        self.assertIn("size > (size_t)maxArgumentSize", body)
        self.assertIn("memchr(", body)
        self.assertNotIn("static int maxArgumentSize", body)

    def test_native_regression_is_required_by_existing_ci(self):
        self.assertIn("python3 tests/test_rc9_upstream_313.py --native",
                      source(".github/workflows/roothide.yml"))

    def test_old_arm64e_abi_is_allowed_for_libraries_not_executables(self):
        body = extract(source(SIGNATURES), "bool macho_is_mappable(")
        self.assertIn("bool isLibrary = (header->filetype != MH_EXECUTE);", body)
        self.assertIn("cpusubtype == CPU_SUBTYPE_ARM64E && isLibrary", body)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <signal.h>
#include <sys/types.h>

typedef int cpu_type_t;
typedef uint32_t cpu_subtype_t;
typedef int dispatch_once_t;
enum { CPU_TYPE_ARM64 = 0x100000c, CPU_SUBTYPE_ARM64E = 2,
    CPU_SUBTYPE_ARM64_ALL = 0, CPU_SUBTYPE_ARM64_V8 = 1, MH_EXECUTE = 2, MH_DYLIB = 6, MH_BUNDLE = 8 };
#define CPU_SUBTYPE_ARM64E_ABI_V2 0x80000000u
struct mach_header { cpu_type_t cputype; cpu_subtype_t cpusubtype; uint32_t filetype; };
typedef struct mach_header MachO;
static cpu_type_t mockCpuType = CPU_TYPE_ARM64;
static cpu_subtype_t mockCpuSubtype = CPU_SUBTYPE_ARM64E;
static void host_get_cpu_information(cpu_type_t *type, cpu_subtype_t *subtype) {
    *type = mockCpuType; *subtype = mockCpuSubtype;
}
static struct mach_header *macho_get_mach_header(MachO *macho) { return macho; }
/* Recompute the mocked CPU per case; this does not test dispatch_once itself. */
#define dispatch_once(token, callback) ((void)(token), host_get_cpu_information(&hostCpuType, &hostCpuSubtype))

static bool tweaksEnabled = true, ios16 = true;
static const char *gExecutablePath = "/usr/bin/normal";
static const char *disableEnv, *safeEnv, *msSafeEnv;
static bool roothide_isTweakInjectionEnabled(void) { return tweaksEnabled; }
static char *test_getenv(const char *key) {
    if (!strcmp(key, "DISABLE_TWEAKS")) return (char *)disableEnv;
    if (!strcmp(key, "_SafeMode")) return (char *)safeEnv;
    if (!strcmp(key, "_MSSafeMode")) return (char *)msSafeEnv;
    assert(false); return NULL;
}
#define getenv test_getenv

enum { offset_task_map = 8, offset_vm_map_pmap = 16, offset_pmap_ttep = 24 };
#define koffsetof(type, field) offset_##type##_##field
static uint64_t task = 0x2000, map = 0x3000, pmap = 0x4000, ttep = 0x5000;
static int taskCalls, readCalls, writeCalls, writeResult;
static uint64_t proc_task(uint64_t proc) {
    assert(proc == 0x1000); ++taskCalls; return task;
}
static uint64_t kread_ptr(uint64_t address) {
    ++readCalls;
    if (address == 0x2000 + offset_task_map) return map;
    if (address == 0x3000 + offset_vm_map_pmap) return pmap;
    assert(address == 0x4000 + offset_pmap_ttep); return ttep;
}
static const void *expectedAddress, *expectedData;
static size_t expectedLength;
static int vwritebuf(uint64_t pageTable, const void *address, const void *data, size_t length) {
    assert(pageTable == ttep && address == expectedAddress);
    assert(data == expectedData && length == expectedLength);
    ++writeCalls; return writeResult;
}

enum { CTL_KERN = 1, KERN_ARGMAX = 2, KERN_PROC = 3, KERN_PROC_ALL = 4, KERN_PROCARGS2 = 5 };
struct kinfo_proc { struct { pid_t p_pid; } kp_proc; };
static int failAllocation = -1, allocations, outstanding, failure, killed, argQueries;
static void *argumentBuffer;
static size_t argumentCapacity;
static void *test_malloc(size_t length) {
    if (allocations++ == failAllocation) return NULL;
    void *result = malloc(length);
    assert(result); ++outstanding;
    if (allocations == 2) { argumentBuffer = result; argumentCapacity = length; }
    return result;
}
static void test_free(void *pointer) {
    if (pointer) { --outstanding; free(pointer); }
}
#define malloc test_malloc
#define free test_free
static int test_kill(pid_t pid, int sig) {
    assert(pid == 42 && sig == SIGTERM); ++killed; return 0;
}
#define kill test_kill
static int sysctl(int *mib, unsigned int count, void *output, size_t *length, void *input, size_t inputLength) {
    assert(mib[0] == CTL_KERN && !input && !inputLength);
    if (mib[1] == KERN_ARGMAX) {
        assert(count == 2 && output && *length == sizeof(int));
        if (failure == 1) return -1;
        *(int *)output = failure == 2 ? 0 : failure == 3 ? -1 : 128;
        return 0;
    }
    assert(count == 3);
    if (mib[1] == KERN_PROC) {
        assert(mib[2] == KERN_PROC_ALL);
        if (!output) {
            if (failure == 4) return -1;
            *length = failure == 5 ? 0 : 5 * sizeof(struct kinfo_proc); return 0;
        }
        if (failure == 6) return -1;
        struct kinfo_proc processes[] = {{{0}}, {{-1}}, {{42}}, {{43}}, {{44}}};
        assert(*length == sizeof(processes)); memcpy(output, processes, sizeof(processes)); return 0;
    }
    assert(mib[1] == KERN_PROCARGS2 && mib[2] > 0);
    ++argQueries;
    assert(output == argumentBuffer && *length == argumentCapacity);
    assert(argumentCapacity == (failure >= 1 && failure <= 3 ? 4096 : 128));
    if (failure == 7) return -1;
    if (failure == 8) { *length = sizeof(int); return 0; }
    if (failure == 9) { *length = argumentCapacity + 1; return 0; }
    memset(output, 0x58, *length);
    if (failure == 10) return 0; /* No NUL in the returned path. */
    const char *path = mib[2] == 42 ? "/usr/libexec/test-daemon" :
        mib[2] == 43 ? "/usr/libexec/test-daemon.extra" : "/other/test-daemon";
    size_t used = sizeof(int) + strlen(path) + 1;
    assert(used <= *length);
    memcpy((char *)output + sizeof(int), path, strlen(path) + 1);
    *length = used; return 0;
}
'''

NATIVE_MAIN = r'''
int main(void) {
    const uint32_t filetypes[] = {MH_EXECUTE, MH_DYLIB, MH_BUNDLE};
    const cpu_subtype_t subtypes[] = {CPU_SUBTYPE_ARM64_ALL, CPU_SUBTYPE_ARM64_V8,
        CPU_SUBTYPE_ARM64E, CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_ARM64E_ABI_V2, 99};
    for (int hostArm64e = 0; hostArm64e < 2; hostArm64e++) {
        mockCpuSubtype = hostArm64e ? CPU_SUBTYPE_ARM64E : CPU_SUBTYPE_ARM64_ALL;
        for (size_t i = 0; i < sizeof(filetypes) / sizeof(filetypes[0]); i++) {
            for (size_t j = 0; j < sizeof(subtypes) / sizeof(subtypes[0]); j++) {
                MachO macho = {CPU_TYPE_ARM64, subtypes[j], filetypes[i]};
                bool allowed = j < 2 || (hostArm64e && (j == 3 || (j == 2 && i != 0)));
                assert(macho_is_mappable(&macho) == allowed);
                macho.cputype = 0; assert(!macho_is_mappable(&macho));
            }
        }
    }
    const char *blocked[] = {"/usr/libexec/logd", "/usr/libexec/logd_helper",
        "/usr/sbin/notifyd", "/usr/libexec/usermanagerd", "/usr/libexec/xpcproxy",
        "/private/var/containers/Dopamine.app/Dopamine"};
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        gExecutablePath = blocked[i]; assert(!should_enable_tweaks());
    }
    const char *allowed[] = {"/usr/libexec/logd_helper.extra", "/other/logd_helper", "/usr/bin/normal"};
    for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
        gExecutablePath = allowed[i]; assert(should_enable_tweaks());
    }
    tweaksEnabled = false; assert(!should_enable_tweaks()); tweaksEnabled = true;
    disableEnv = "1"; assert(!should_enable_tweaks()); disableEnv = NULL;
    safeEnv = "1"; assert(!should_enable_tweaks()); safeEnv = NULL;
    msSafeEnv = "1"; assert(!should_enable_tweaks()); msSafeEnv = NULL;
    disableEnv = safeEnv = msSafeEnv = "0"; assert(should_enable_tweaks());
    ios16 = false; gExecutablePath = "/usr/libexec/logd_helper"; assert(should_enable_tweaks());

    char payload[] = "payload"; expectedAddress = (const void *)(uintptr_t)0x123456;
    expectedData = payload; expectedLength = sizeof(payload);
    assert(proc_vwritebuf(0x1000, expectedAddress, payload, sizeof(payload)) == 0);
    assert(taskCalls == 1 && readCalls == 3 && writeCalls == 1);
    writeResult = -17;
    assert(proc_vwritebuf(0x1000, expectedAddress, payload, sizeof(payload)) == -17);
    assert(taskCalls == 2 && readCalls == 6 && writeCalls == 2);
    uint64_t *stages[] = {&task, &map, &pmap, &ttep};
    for (int i = 0; i < 4; i++) {
        uint64_t saved = *stages[i]; *stages[i] = 0; readCalls = 0;
        assert(proc_vwritebuf(0x1000, expectedAddress, payload, sizeof(payload)) == -1);
        assert(readCalls == i && writeCalls == 2);
        *stages[i] = saved;
    }

    killall(NULL, SIGTERM); assert(allocations == 0 && killed == 0);
    for (failure = 0; failure <= 10; failure++) {
        allocations = killed = argQueries = 0; argumentBuffer = NULL;
        killall("/usr/libexec/test-daemon", SIGTERM);
        assert(outstanding == 0);
        assert(killed == (failure <= 3 ? 1 : 0));
        assert(argQueries == (failure <= 3 || failure >= 7 ? 3 : 0));
    }
    failure = 0;
    for (failAllocation = 0; failAllocation < 2; failAllocation++) {
        allocations = killed = argQueries = 0; argumentBuffer = NULL;
        killall("/usr/libexec/test-daemon", SIGTERM);
        assert(outstanding == 0 && killed == 0 && argQueries == 0);
    }
    puts("PASS: Mach-O ABI selection, tweak gate, process write and killall bounds/failures");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    gate = extract(source(MAIN), "bool should_enable_tweaks(void)")
    availability = "__builtin_available(iOS 16.0, *)"
    if gate.count(availability) != 1:
        raise AssertionError("Recheck the availability mock against the production gate")
    gate = gate.replace(availability, "ios16")
    code = "\n".join((
        NATIVE_PREFIX,
        extract(source(SIGNATURES), "bool macho_is_mappable("),
        extract(source("BaseBin/systemhook/src/common/common.c"), "bool string_has_suffix("),
        gate,
        extract(source(PRIMITIVES), "int proc_vwritebuf("),
        extract(source(UTIL), "void killall("),
        NATIVE_MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-upstream313-") as tmp:
        path = Path(tmp) / "upstream313.c"
        binary = Path(tmp) / "upstream313-test"
        path.write_text(code, encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-O1", "-g", "-fsanitize=address,undefined",
                        str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Upstream313Contracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on a clang host.")
