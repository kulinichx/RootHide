#!/usr/bin/env python3
"""Host regression for the four extracted spawn PID blocks (not full iOS hooks).

Run: python3 .github/scripts/test_spawn_pid.py [--root PATH]
Requires a POSIX host and a C compiler. No real process is spawned by the stub.
Checks pointer identity, NULL fallback, success/failure and unreadable output on
failure. A mutant restoring the old unconditional read must fail the same tests.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

SITES = {
    'BaseBin/launchdhook/src/roothider.m': 2,
    'BaseBin/systemhook/src/roothider_main.c': 1,
    'BaseBin/libjailbreak/src/roothider/common.m': 1,
}
PATTERN = re.compile(
    r'pid_t pidval = 0;\s*if \(!pidp\) pidp = &pidval;\s*'
    r'int ret = (?:__posix_spawn_orig_wrapper|__posix_spawn_orig|posix_spawn)'
    r'\(pidp,[^;]+;\s*pid_t pid = [^;]+;'
)
PREFIX = r'''
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
static pid_t *expected_pointer;
static pid_t observed_pid, next_pid;
static int next_result, calls;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(2); } } while (0)
static int spawn_stub(pid_t *actual, ...) {
    ++calls;
    CHECK(actual != NULL);
    CHECK(expected_pointer == NULL || actual == expected_pointer);
    if (next_result == 0) *actual = next_pid;
    return next_result;
}
#define __posix_spawn_orig_wrapper spawn_stub
#define __posix_spawn_orig spawn_stub
#define posix_spawn spawn_stub
#define path NULL
#define desc NULL
#define argv NULL
#define envc NULL
#define envp NULL
#define fap NULL
#define attrp NULL
'''
SUFFIX = r'''
static void run_case(int (*wrapper)(pid_t *), pid_t *output, int result, pid_t child) {
    expected_pointer = output;
    next_result = result;
    next_pid = child;
    observed_pid = -999;
    calls = 0;
    CHECK(wrapper(output) == result);
    CHECK(calls == 1);
    CHECK(observed_pid == (result == 0 ? child : 0));
}
int main(void) {
    int (*wrappers[])(pid_t *) = {wrapper0, wrapper1, wrapper2, wrapper3};
    int errors[] = {ENOENT, EACCES, ENOMEM, EINVAL, EAGAIN};
    long page_size = sysconf(_SC_PAGESIZE);
    CHECK(page_size > 0);
    void *page = mmap(NULL, (size_t)page_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(page != MAP_FAILED);
    unsigned cases = 0;
    for (unsigned i = 0; i < 4; ++i) {
        pid_t value;
        for (unsigned zero = 0; zero < 2; ++zero) {
            pid_t child = zero ? 0 : 12345;
            value = 9876;
            run_case(wrappers[i], &value, 0, child);
            CHECK(value == child);
            run_case(wrappers[i], NULL, 0, child);
            cases += 2;
        }
        for (unsigned e = 0; e < sizeof(errors) / sizeof(errors[0]); ++e) {
            value = 9876;
            run_case(wrappers[i], &value, errors[e], 12345);
            CHECK(value == 9876); /* Do not clear or change caller storage on failure. */
            run_case(wrappers[i], NULL, errors[e], 12345);
            /* Synthetic failure stub: output is never initialized or made readable.
             * This tests no-read behavior; it does not emulate Darwin syscalls. */
            run_case(wrappers[i], (pid_t *)page, errors[e], 12345);
            cases += 3;
        }
    }
    CHECK(munmap(page, (size_t)page_size) == 0);
    printf("PASS: %u cases across four extracted PID blocks\n", cases);
    return 0;
}
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    snippets = []
    for name, count in SITES.items():
        text = (args.root / name).read_text()
        blocks = PATTERN.findall(text)
        if len(blocks) != count:
            raise SystemExit(f'Expected {count} PID blocks in {name}, found {len(blocks)}')
        for block in blocks:
            if 'pid_t pid = (ret == 0) ? *pidp : 0;' not in block:
                raise SystemExit(f'Missing success-only PID read: {name}')
        snippets.extend(blocks)
    body = '\n'.join(f'static int wrapper{i}(pid_t *pidp) {{\n{block}\nobserved_pid = pid; return ret;\n}}' for i, block in enumerate(snippets))
    source = PREFIX + body + SUFFIX
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    with tempfile.TemporaryDirectory(prefix='spawn-pid-test-') as temp:
        root = Path(temp)
        for mutant in (False, True):
            code = source.replace('(ret == 0) ? *pidp : 0', '*pidp') if mutant else source
            src, exe = root / 'test.c', root / 'test'
            src.write_text(code)
            subprocess.run(compiler + ['-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', str(src), '-o', str(exe)], check=True)
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            if mutant:
                if result.returncode != 2 or 'observed_pid ==' not in result.stderr:
                    raise SystemExit(f'Old unconditional-read mutant was not rejected as expected: {result.returncode}')
                print('PASS: restoring the old unconditional read is rejected by the runtime checks')
            else:
                if result.returncode:
                    raise SystemExit(f'PID regression failed ({result.returncode}): {result.stderr}')
                print(result.stdout.strip())
    print('Scope: extracted C PID blocks only; full SDK build and real-device validation remain separate.')

if __name__ == '__main__':
    main()
