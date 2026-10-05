#!/usr/bin/env python3
"""Compile and execute negative host tests against the real envbuf.c."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
C_TEST = r"""
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "BaseBin/systemhook/src/common/envbuf.c"
int main(void) {
    char **empty = envbuf_mutcopy(NULL);
    assert(empty && empty[0] == NULL);
    envbuf_setenv(&empty, "A", "1");
    assert(strcmp(envbuf_getenv((const char **)empty, "A"), "1") == 0);
    envbuf_setenv(&empty, "A", "2");
    assert(strcmp(envbuf_getenv((const char **)empty, "A"), "2") == 0);
    envbuf_setenv(&empty, "", "bad");
    envbuf_setenv(&empty, "BAD=NAME", "bad");
    assert(envbuf_find((const char **)empty, "BAD") == -1);
    envbuf_unsetenv(&empty, "A");
    assert(envbuf_getenv((const char **)empty, "A") == NULL);
    envbuf_free(empty);
    const char *source[] = { "ONE=1", "TWO=2", NULL };
    char **copy = envbuf_mutcopy(source);
    assert(copy && copy[0] != source[0]);
    assert(strcmp(copy[1], "TWO=2") == 0);
    envbuf_free(copy);
    const char **unterminated = calloc(ENVBUF_MAX_ENTRIES, sizeof(char *));
    assert(unterminated);
    for (int i = 0; i < ENVBUF_MAX_ENTRIES; i++) unterminated[i] = "X=1";
    assert(envbuf_len(unterminated) == -1);
    assert(envbuf_find(unterminated, "MISSING") == -1);
    assert(envbuf_mutcopy(unterminated) == NULL);
    free(unterminated);
    return 0;
}
"""
C_ALLOC_FAILURE_TEST = r"""
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static int allocation_count;
static int fail_after;
static void *test_malloc(size_t size) {
    if (fail_after >= 0 && allocation_count++ == fail_after) return NULL;
    return malloc(size);
}
static void *test_calloc(size_t count, size_t size) {
    if (fail_after >= 0 && allocation_count++ == fail_after) return NULL;
    return calloc(count, size);
}
static void *test_realloc(void *pointer, size_t size) {
    if (fail_after >= 0 && allocation_count++ == fail_after) return NULL;
    return realloc(pointer, size);
}
static char *test_strdup(const char *value) {
    size_t size = strlen(value) + 1;
    char *copy = test_malloc(size);
    if (copy) memcpy(copy, value, size);
    return copy;
}
#define malloc test_malloc
#define calloc test_calloc
#define realloc test_realloc
#define strdup test_strdup
#include "BaseBin/systemhook/src/common/envbuf.c"
#undef malloc
#undef calloc
#undef realloc
#undef strdup
static void reset_failure(int index) { allocation_count = 0; fail_after = index; }
int main(void) {
    const char *source[] = { "A=1", "B=2", NULL };
    reset_failure(0);
    assert(envbuf_mutcopy(source) == NULL);
    reset_failure(2);
    assert(envbuf_mutcopy(source) == NULL);
    reset_failure(0);
    assert(envbuf_mutcopy(NULL) == NULL);
    reset_failure(-1);
    char **empty = envbuf_mutcopy(NULL);
    assert(empty && empty[0] == NULL);
    reset_failure(0);
    envbuf_setenv(&empty, "A", "1");
    assert(empty && empty[0] == NULL);
    reset_failure(-1);
    envbuf_free(empty);
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "envbuf_test.c"
    binary = Path(tmp) / "envbuf_test"
    source.write_text(C_TEST, encoding="utf-8")
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-I", str(ROOT), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    failure_source = Path(tmp) / "envbuf_alloc_failure_test.c"
    failure_binary = Path(tmp) / "envbuf_alloc_failure_test"
    failure_source.write_text(C_ALLOC_FAILURE_TEST, encoding="utf-8")
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-I", str(ROOT), str(failure_source), "-o", str(failure_binary)], check=True)
    subprocess.run([str(failure_binary)], check=True)
print("PASS: envbuf executable boundary and sanitizer regressions")
