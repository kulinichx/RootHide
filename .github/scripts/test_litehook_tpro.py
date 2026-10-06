#!/usr/bin/env python3
"""Test the patched rebind function with mocked TPRO and Mach operations.

This tests thread-state scope, including the observed protect return value 2.
It does not emulate ARM registers, PAC, XNU mappings, or device compatibility.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'BaseBin/_external/modules/litehook/src/litehook.c'


def extract_function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for position in range(opening, len(source)):
        if source[position] == '{':
            depth += 1
        elif source[position] == '}':
            depth -= 1
            if not depth:
                return source[start:position + 1]
    raise ValueError('unclosed C function')


PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Switch the extracted function's branch after system headers are loaded. */
#if TEST_TPRO_ARM64
#ifndef __arm64__
#define __arm64__ 1
#endif
#else
#undef __arm64__
#endif
/* macOS secure/_string.h may already define a fortified strlcpy macro. */
#ifdef strlcpy
#undef strlcpy
#endif
#define strlcpy tpro_test_strlcpy

typedef uintptr_t vm_address_t;
typedef struct { int unused; } mach_header_u;
typedef struct { char segname[16]; char sectname[16]; } section_u;
#define ptrauth_key_function_pointer 0
#define ptrauth_key_process_independent_code 0
#define ptrauth_strip(pointer, key) (pointer)
#define ptrauth_auth_function(pointer, key, discriminator) (pointer)
#define ptrauth_auth_and_resign(pointer, key1, discriminator1, key2, discriminator2) (pointer)

static void *slots[4];
static int original_object, replacement_object, unrelated_object;
static bool supported, writable, expect_match;
static int protect_result;
static char trace[64];
static unsigned trace_count;
static void event(char e) { assert(trace_count + 1 < sizeof(trace)); trace[trace_count++] = e; }

static size_t strlcpy(char *dst, const char *src, size_t capacity) {
    size_t n = strlen(src);
    if (capacity) { size_t count = n < capacity - 1 ? n : capacity - 1; memcpy(dst, src, count); dst[count] = 0; }
    return n;
}
static uint8_t *getsectiondata(const mach_header_u *header, const char *segname, const char *sectname, unsigned long *size) {
    (void)header; (void)segname; (void)sectname;
    *size = sizeof(slots);
    return (uint8_t *)slots;
}
#ifdef __arm64__
static bool os_tpro_is_supported(void) { event('S'); return supported; }
static bool os_thread_self_tpro_is_writeable(void) { event('Q'); assert(supported); return writable; }
static void os_thread_self_restrict_tpro_to_rw(void) { event('E'); assert(supported && !writable); writable = true; }
static void os_thread_self_restrict_tpro_to_ro(void) {
    event('R');
    assert(supported && writable && slots[1] == &replacement_object);
    writable = false;
}
#endif
static int litehook_unprotect(vm_address_t address, size_t size) {
    event('P');
    assert(expect_match && address == (uintptr_t)&slots[1] && size == sizeof(void *));
    assert(slots[1] == &original_object);
    assert(!supported || writable);
    return protect_result;
}
'''


SUFFIX = r'''
static void run_case(bool has_tpro, bool initially_writable, int result, bool authenticated, bool match, const char *expected_trace) {
    supported = has_tpro; writable = initially_writable; protect_result = result; expect_match = match;
    memset(trace, 0, sizeof(trace)); trace_count = 0;
    slots[0] = NULL; slots[1] = match ? &original_object : &unrelated_object;
    slots[2] = &unrelated_object; slots[3] = NULL;
    mach_header_u header = {0};
    section_u section = {0};
    strlcpy(section.segname, "__AUTH_CONST", sizeof(section.segname));
    strlcpy(section.sectname, authenticated ? "__auth_got" : "__got", sizeof(section.sectname));
    _litehook_rebind_symbol_in_section(&header, &section, &original_object, &replacement_object);
    assert(slots[1] == (match ? (void *)&replacement_object : (void *)&unrelated_object));
    assert(slots[0] == NULL && slots[2] == &unrelated_object && slots[3] == NULL);
    assert(writable == initially_writable);
    assert(strcmp(trace, expected_trace) == 0);
}
int main(void) {
#ifdef __arm64__
    run_case(false, false, 0, false, true, "SP");
    run_case(false, false, 0, true, true, "SP");
    run_case(true, false, 0, false, true, "SQEPR");
    run_case(true, false, 2, false, true, "SQEPR");
    run_case(true, false, 2, true, true, "SQEPR");
    run_case(true, true, 2, true, true, "SQP");
    run_case(true, false, 2, true, false, "");
    run_case(false, false, 0, false, false, "");
#else
    run_case(false, false, 0, false, true, "P");
    run_case(false, false, 0, true, true, "P");
    run_case(false, false, 0, true, false, "");
#endif
    puts("PASS: rebind writes and preserves the initial thread write state");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--check-only', action='store_true', help='validate patched source and wiring; do not run the C harness')
    args = parser.parse_args()
    source = args.source.read_text(encoding='utf-8')
    function = extract_function(source, 'void _litehook_rebind_symbol_in_section(')
    for marker in ('_COMM_PAGE_START_ADDRESS + 0x0D0', '_COMM_PAGE_START_ADDRESS + 0x0D8', 's3_6_c15_c1_5', '"ubfx            x0, x0, #0x24, #1;'):
        if marker not in source:
            raise AssertionError(f'missing upstream TPRO helper: {marker}')
    for marker in ('os_tpro_is_supported()', 'os_thread_self_tpro_is_writeable()', 'os_thread_self_restrict_tpro_to_rw()', 'os_thread_self_restrict_tpro_to_ro()'):
        if marker not in function:
            raise AssertionError(f'missing TPRO write scope: {marker}')
    workflow = (ROOT / '.github/workflows/roothide.yml').read_text(encoding='utf-8')
    apply_line = 'git -C BaseBin/_external/modules/litehook apply "$GITHUB_WORKSPACE/.github/patches/litehook-tpro.patch"'
    if apply_line not in workflow or 'run: python3 .github/scripts/test_litehook_tpro.py' not in workflow:
        raise AssertionError('TPRO patch or runtime regression is missing from CI')
    print('PASS: upstream TPRO helpers and build wiring present', flush=True)
    if args.check_only:
        print('C harness NOT run (--check-only); ARM registers and device behavior remain unverified.')
        return
    with tempfile.TemporaryDirectory(prefix='litehook-tpro-') as directory:
        test_c = Path(directory) / 'tpro.c'
        test_c.write_text(PREFIX + '\n' + function + '\n' + SUFFIX, encoding='utf-8')
        for mode, flags in [('arm64', ['-DTEST_TPRO_ARM64=1']), ('legacy', ['-DTEST_TPRO_ARM64=0'])]:
            test_exe = Path(directory) / mode
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', *flags, str(test_c), '-o', str(test_exe)], check=True)
            subprocess.run([str(test_exe)], check=True)
    print('Scope: mocked Mach/TPRO operations; hardware and device validation still required.')


if __name__ == '__main__':
    main()
