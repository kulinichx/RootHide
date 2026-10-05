#!/usr/bin/env python3
"""Compile and execute transient-failure tests against loadPathHook()."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "BaseBin/systemhook/src/roothider_main.c").read_text(encoding="utf-8")

def extract_function(signature: str) -> str:
    start = SOURCE.index(signature)
    opening = SOURCE.index("{", start)
    depth = 0
    for pos in range(opening, len(SOURCE)):
        if SOURCE[pos] == "{": depth += 1
        elif SOURCE[pos] == "}":
            depth -= 1
            if depth == 0: return SOURCE[start:pos + 1]
    raise ValueError("unclosed loadPathHook")

function = extract_function("void loadPathHook()")
harness = r"""
#include <assert.h>
#include <stdbool.h>
#include <pthread.h>
#include <stddef.h>
static int load_attempts, symbol_attempts, close_count, hook_count;
static int fail_loads, fail_symbols;
static const char *test_path = "/var/jb/basebin/roothidehooks.dylib";
static void pathhook_impl(void) { hook_count++; }
static void *test_dlopen(const char *path, int flags) {
    (void)flags; assert(path == test_path); load_attempts++;
    if (fail_loads-- > 0) return NULL;
    return (void *)0x1234;
}
static void *test_dlsym(void *handle, const char *name) {
    assert(handle == (void *)0x1234); (void)name; symbol_attempts++;
    if (fail_symbols-- > 0) return NULL;
    return (void *)pathhook_impl;
}
static int test_dlclose(void *handle) { assert(handle == (void *)0x1234); close_count++; return 0; }
static const char *test_dlerror(void) { return "injected failure"; }
#define RTLD_NOW 2
#define JBROOT_PATH(path) (test_path)
#define SYSLOG(...) ((void)0)
#define dlopen test_dlopen
#define dlsym test_dlsym
#define dlclose test_dlclose
#define dlerror test_dlerror
""" + function + r"""
int main(void) {
    fail_loads = 1;
    loadPathHook();
    assert(load_attempts == 1 && hook_count == 0);
    fail_symbols = 1;
    loadPathHook();
    assert(load_attempts == 2 && symbol_attempts == 1 && close_count == 1 && hook_count == 0);
    loadPathHook();
    assert(load_attempts == 3 && symbol_attempts == 2 && hook_count == 1);
    loadPathHook();
    assert(load_attempts == 3 && hook_count == 1);
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "pathhook_test.c"
    binary = Path(tmp) / "pathhook_test"
    source.write_text(harness, encoding="utf-8")
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("PASS: path hook transient load and symbol failures retry")
