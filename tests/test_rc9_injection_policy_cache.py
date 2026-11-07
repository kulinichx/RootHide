"""Injection-policy cache regressions using the production C implementation.

--native exercises real files, concurrent readers, and fork with an inherited
locked cache. XPC parsing and unfair locks are host-side test doubles.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_runtime_policy import ROOT, source


HEADER = "BaseBin/shared/RCInjectPolicyCache.h"
IMPLEMENTATION = "BaseBin/shared/RCInjectPolicyCache.c"
WORKFLOW = ".github/workflows/roothide.yml"


class InjectionPolicyCacheContracts(unittest.TestCase):
    def test_cache_state_is_process_owned_and_lock_free_to_replace(self):
        header = source(HEADER)
        implementation = source(IMPLEMENTATION)
        self.assertIn("_Atomic(RCInjectPolicyCacheState *) state;", header)
        self.assertIn("ATOMIC_POINTER_LOCK_FREE == 2", implementation)
        current = implementation.split(
            "static RCInjectPolicyCacheState *cache_current_state", 1)[1].split(
                "static xpc_object_t cache_load_dictionary", 1)[0]
        self.assertIn("state->owner == owner", current)
        self.assertIn("atomic_compare_exchange_strong_explicit", current)
        self.assertIn("intentionally left alone in the child process", current)

    def test_file_identity_includes_ctime_and_stable_descriptor_read(self):
        implementation = source(IMPLEMENTATION)
        metadata = implementation.split(
            "static bool cache_metadata_matches", 1)[1].split(
                "static void cache_set_metadata_locked", 1)[0]
        self.assertIn("st_dev", metadata)
        self.assertIn("st_ino", metadata)
        self.assertIn("st_size", metadata)
        self.assertIn("st_mtimespec", metadata)
        self.assertIn("st_ctimespec", metadata)
        loader = implementation.split(
            "static xpc_object_t cache_load_dictionary", 1)[1].split(
                "xpc_object_t rc_inject_policy_cache_copy_dictionary", 1)[0]
        self.assertIn("O_CLOEXEC | O_NONBLOCK", loader)
        self.assertIn("fstat(fd, &before)", loader)
        self.assertIn("errno == EINTR", loader)
        self.assertIn("offset == length && fstat(fd, &after)", loader)

    def test_failed_parse_preserves_last_valid_snapshot_and_missing_file_clears(self):
        implementation = source(IMPLEMENTATION)
        lookup = implementation.split(
            "xpc_object_t rc_inject_policy_cache_copy_dictionary", 1)[1].split(
                "void rc_inject_policy_cache_invalidate", 1)[0]
        self.assertIn("state->dictionary ? xpc_retain(state->dictionary) : NULL", lookup)
        self.assertIn("if (parsed) {\n            cache_replace_locked(state, &observed, parsed);", lookup)
        self.assertIn("if (errno == ENOENT || errno == ENOTDIR)", lookup)
        self.assertIn("cache_clear_locked(state);", lookup)

    def test_native_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_injection_policy_cache.py --native",
                      source(WORKFLOW))


PREFIX = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef __APPLE__
#define st_atimespec st_atim
#define st_mtimespec st_mtim
#define st_ctimespec st_ctim
#endif

enum { XPC_TYPE_DICTIONARY = 1 };
typedef struct { int type; int refs; bool enabled; } TestXPC;
typedef TestXPC *xpc_object_t;
typedef int os_unfair_lock;
typedef struct {
    pid_t owner;
    os_unfair_lock lock;
    bool metadataValid;
    dev_t device;
    ino_t inode;
    mode_t mode;
    off_t fileSize;
    struct timespec fileMtime;
    struct timespec fileCtime;
    xpc_object_t dictionary;
} RCInjectPolicyCacheState;
typedef struct { _Atomic(RCInjectPolicyCacheState *) state; } RCInjectPolicyCache;
#define OS_UNFAIR_LOCK_INIT 0
#define RC_INJECT_POLICY_CACHE_INIT { .state = NULL }

static int xpc_get_type(xpc_object_t value);
static xpc_object_t xpc_retain(xpc_object_t value);
static void xpc_release(xpc_object_t value);
static xpc_object_t
rc_inject_policy_cache_copy_dictionary(RCInjectPolicyCache *cache, const char *path);
static void rc_inject_policy_cache_invalidate(RCInjectPolicyCache *cache);

static atomic_int parseCalls;
static void os_unfair_lock_lock(os_unfair_lock *lock) {
    while (__atomic_exchange_n(lock, 1, __ATOMIC_ACQUIRE)) sched_yield();
}
static void os_unfair_lock_unlock(os_unfair_lock *lock) {
    __atomic_store_n(lock, 0, __ATOMIC_RELEASE);
}
xpc_object_t xpc_create_from_plist(const void *bytes, size_t length) {
    atomic_fetch_add(&parseCalls, 1);
    if (length != 1 || (*(const char *)bytes != '0' && *(const char *)bytes != '1'))
        return NULL;
    TestXPC *value = calloc(1, sizeof(*value)); assert(value);
    value->type = XPC_TYPE_DICTIONARY;
    value->refs = 1;
    value->enabled = *(const char *)bytes == '1';
    return value;
}
static int xpc_get_type(xpc_object_t value) { return value->type; }
static xpc_object_t xpc_retain(xpc_object_t value) {
    assert(value && __atomic_load_n(&value->refs, __ATOMIC_RELAXED) > 0);
    __atomic_add_fetch(&value->refs, 1, __ATOMIC_RELAXED);
    return value;
}
static void xpc_release(xpc_object_t value) {
    if (!value) return;
    int refs = __atomic_sub_fetch(&value->refs, 1, __ATOMIC_ACQ_REL);
    assert(refs >= 0);
    if (!refs) free(value);
}
static bool xpc_dictionary_get_bool(xpc_object_t value, const char *key) {
    assert(value && value->type == XPC_TYPE_DICTIONARY);
    assert(strcmp(key, "enabled") == 0);
    return value->enabled;
}

static char root[] = "/tmp/rc9-policy-cache-XXXXXX";
static char configPath[PATH_MAX];
static RCInjectPolicyCache cache = RC_INJECT_POLICY_CACHE_INIT;
static void write_config(const char *bytes, size_t length) {
    int fd = open(configPath, O_WRONLY | O_CREAT | O_TRUNC, 0600); assert(fd >= 0);
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, bytes + offset, length - offset);
        assert(count > 0); offset += (size_t)count;
    }
    assert(close(fd) == 0);
}
static xpc_object_t read_config(void) {
    return rc_inject_policy_cache_copy_dictionary(&cache, configPath);
}
static bool read_enabled(bool expected) {
    xpc_object_t value = read_config();
    assert(value);
    bool result = xpc_dictionary_get_bool(value, "enabled");
    xpc_release(value);
    return result == expected;
}
static void *reader_thread(void *unused) {
    (void)unused;
    for (int i = 0; i < 500; i++) {
        xpc_object_t value = read_config();
        if (!value) return (void *)1;
        bool enabled = xpc_dictionary_get_bool(value, "enabled");
        xpc_release(value);
        if (!enabled) return (void *)1;
    }
    return NULL;
}

int main(void) {
    assert(mkdtemp(root));
    assert(snprintf(configPath, sizeof(configPath), "%s/config.plist", root) > 0);
    write_config("1", 1);
    assert(read_enabled(true));

    // Same inode, size, and restored mtime must still observe the changed ctime.
    struct stat original; assert(stat(configPath, &original) == 0);
    struct timespec oldTimes[2] = { original.st_atimespec, original.st_mtimespec };
    struct timespec delay = { .tv_nsec = 20000000 };
    nanosleep(&delay, NULL);
    write_config("0", 1);
    assert(utimensat(AT_FDCWD, configPath, oldTimes, 0) == 0);
    assert(read_enabled(false));

    // Keep the prior valid snapshot during an invalid atomic-write window.
    write_config("x", 1);
    xpc_object_t previous = read_config();
    assert(previous && !xpc_dictionary_get_bool(previous, "enabled"));
    xpc_release(previous);

    write_config("1", 1);
    assert(read_enabled(true));
    pthread_t threads[8];
    for (size_t i = 0; i < 8; i++) assert(pthread_create(&threads[i], NULL, reader_thread, NULL) == 0);
    for (size_t i = 0; i < 8; i++) {
        void *result = NULL;
        assert(pthread_join(threads[i], &result) == 0 && result == NULL);
    }

    // A forked child must not wait on a lock held by a vanished parent thread.
    RCInjectPolicyCacheState *state =
        atomic_load_explicit(&cache.state, memory_order_acquire);
    assert(state && state->owner == getpid());
    os_unfair_lock_lock(&state->lock);
    write_config("0", 1);
    pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        alarm(3);
        xpc_object_t value = read_config();
        if (!value) _exit(10);
        bool enabled = xpc_dictionary_get_bool(value, "enabled");
        xpc_release(value);
        _exit(enabled ? 11 : 0);
    }
    os_unfair_lock_unlock(&state->lock);
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(read_enabled(false));

    unlink(configPath);
    xpc_object_t missing = read_config();
    assert(!missing);
    rc_inject_policy_cache_invalidate(&cache);
    assert(atomic_load(&parseCalls) >= 4);
    assert(rmdir(root) == 0);
    puts("PASS: stable config snapshots, ctime refresh, invalid-write fallback, concurrent readers and fork lock recovery");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    implementation = source(IMPLEMENTATION).replace(
        '#include "RCInjectPolicyCache.h"', "", 1)
    code = "\n".join((PREFIX, implementation))
    with tempfile.TemporaryDirectory(prefix="rc9-injection-cache-") as tmp:
        path = Path(tmp) / "injection-cache.c"
        binary = Path(tmp) / "injection-cache-test"
        path.write_text(code, encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-Wno-unused-function", "-O1", "-g",
                        "-fsanitize=address,undefined", "-pthread",
                        str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(InjectionPolicyCacheContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
