#!/usr/bin/env python3
"""Host-only regressions for the Darwin comparator and kernel-read self-check.

Compiles the functions extracted from the actual source with a fake kernel read
primitive. Does not emulate XNU, validate device offsets, or prove jailbreak safety.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def extract_function(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for pos in range(opening, len(source)):
        if source[pos] == '{':
            depth += 1
        elif source[pos] == '}':
            depth -= 1
            if depth == 0:
                return source[start:pos + 1]
    raise ValueError(f'Unclosed function: {signature}')


PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define OS_LOG_DEFAULT 0
#define os_log(...) ((void)0)
#define UNSIGN_PTR(value) (value)
#define koffsetof(type, member) (gSystemInfo.kernelStruct.type.member)
#define ksymbol(symbol) (kernel_head)
#define getpid() (1234)
#define UNICOPY_DST_USER 0
#define UNICOPY_DST_KERN 1
#define UNICOPY_DST_PHYS 2
#define UNICOPY_SRC_USER 0
#define UNICOPY_SRC_KERN 4
#define UNICOPY_SRC_PHYS 8
static size_t copied_bytes;
size_t unicopy(unsigned int mode, uintptr_t dst, uintptr_t src, size_t size) {
    (void)mode; (void)dst; (void)src; (void)size;
    return copied_bytes;
}
static uint64_t kernel_head = 0x1000;
struct {
    struct {
        struct { uint32_t list_next, pid, flag, proc_ro, textvp, struct_size; } proc;
        struct { uint32_t csflags; } proc_ro;
    } kernelStruct;
} gSystemInfo;
static uint32_t pid_value = 1234, flag_value = 2, csflags_value = 0x04000001;
static uint64_t ro_value = 0x3000, textvp_value = 0x4000, fail_at = 0;
int kreadbuf(uint64_t address, void *out, size_t size);
'''
SUFFIX = r'''
int kreadbuf(uint64_t address, void *out, size_t size) {
    if (address == fail_at) return -1;
    if (address == 0x1000 && size == 8) {
        uint64_t val = 0x2000; memcpy(out, &val, size); return 0;
    }
    if (address == 0x2000 && size == 8) {
        uint64_t val = 0; memcpy(out, &val, size); return 0;
    }
    if (address == 0x2060 && size == 4) {
        memcpy(out, &pid_value, size); return 0;
    }
    if (address == 0x2454 && size == 4) {
        memcpy(out, &flag_value, size); return 0;
    }
    if (address == 0x2018 && size == 8) {
        memcpy(out, &ro_value, size); return 0;
    }
    if (address == 0x301c && size == 4) {
        memcpy(out, &csflags_value, size); return 0;
    }
    if (address == 0x2548 && size == 8) {
        memcpy(out, &textvp_value, size); return 0;
    }
    return -1;
}
int main(void) {
    char buffer[8] = {0};
    copied_bytes = sizeof(buffer);
    assert(kreadbuf_wrapper(0x1000, buffer, sizeof(buffer)) == 0);
    assert(kwritebuf_wrapper(0x1000, buffer, sizeof(buffer)) == 0);
    assert(physreadbuf_wrapper(0x1000, buffer, sizeof(buffer)) == 0);
    assert(physwritebuf_wrapper(0x1000, buffer, sizeof(buffer)) == 0);
    copied_bytes = sizeof(buffer) - 1;
    assert(kreadbuf_wrapper(0x1000, buffer, sizeof(buffer)) != 0);
    assert(kwritebuf_wrapper(0x1000, buffer, sizeof(buffer)) != 0);
    assert(physreadbuf_wrapper(0x1000, buffer, sizeof(buffer)) != 0);
    assert(physwritebuf_wrapper(0x1000, buffer, sizeof(buffer)) != 0);
    char error[256] = {0};
    gSystemInfo.kernelStruct.proc.list_next = 0;
    gSystemInfo.kernelStruct.proc.pid = 0x60;
    gSystemInfo.kernelStruct.proc.flag = 0x454;
    gSystemInfo.kernelStruct.proc.proc_ro = 0x18;
    gSystemInfo.kernelStruct.proc.textvp = 0x548;
    gSystemInfo.kernelStruct.proc_ro.csflags = 0x1c;
    assert(darwin_version_compare("23.10.0", "23.4.0") > 0);
    assert(darwin_version_compare("23.0.0", "23.4.0") < 0);
    assert(darwin_version_compare("23.4.0", "23.4.0") == 0);
    assert(darwin_version_compare("24.0.0", "23.6.0") > 0);
    assert(jbinfo_selfcheck(error, sizeof(error)));
    fail_at = 0x2454;
    assert(!jbinfo_selfcheck(error, sizeof(error)));
    assert(strstr(error, "flag") != NULL);
    fail_at = 0;
    flag_value = 0;
    assert(!jbinfo_selfcheck(error, sizeof(error)));
    flag_value = 2;
    pid_value = 9999;
    assert(!jbinfo_selfcheck(error, sizeof(error)));
    pid_value = 1234;
    ro_value = 0;
    assert(!jbinfo_selfcheck(error, sizeof(error)));
    ro_value = 0x3000;
    textvp_value = 0;
    assert(!jbinfo_selfcheck(error, sizeof(error)));
    puts("PASS: Darwin comparisons, kernel read contract, six self-check cases");
    return 0;
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--info', type=Path)
    parser.add_argument('--bridge', type=Path)
    args = parser.parse_args()
    info = args.info or Path(__file__).resolve().parents[2] / 'BaseBin/libjailbreak/src/info.c'
    source = info.read_text(encoding='utf-8')
    bridge = args.bridge or Path(__file__).resolve().parents[2] / 'BaseBin/dopamine/src/krw-corellium.m'
    bridge_source = bridge.read_text(encoding='utf-8')
    parts = [extract_function(source, signature) for signature in (
        'static int darwin_version_compare(',
        'static bool jbinfo_checked_read(',
        'bool jbinfo_selfcheck(',
    )]
    parts += [extract_function(bridge_source, signature) for signature in (
        'static int kreadbuf_wrapper(',
        'static int kwritebuf_wrapper(',
        'static int physreadbuf_wrapper(',
        'static int physwritebuf_wrapper(',
    )]
    harness = PREFIX + '\n\n'.join(parts) + SUFFIX
    with tempfile.TemporaryDirectory(prefix='ios17-health-') as directory:
        test_c = Path(directory) / 'health.c'
        test_exe = Path(directory) / 'health'
        test_c.write_text(harness, encoding='utf-8')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(test_c), '-o', str(test_exe)], check=True)
        subprocess.run([str(test_exe)], check=True)
    print('Scope: extracted functions + fake kernel memory; device verification still required.')


if __name__ == '__main__':
    main()
