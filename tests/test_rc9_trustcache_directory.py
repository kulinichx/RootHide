"""Production directory-walker regressions, with real host files and injected faults.

--native runs the extracted C functions with ASan/UBSan on macOS. ChOma, file
hash collection and kernel trustcache insertion are mocks, not iOS validation.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


FILE = "BaseBin/libjailbreak/src/trustcache_fs.c"


class DirectoryCollectionContracts(unittest.TestCase):
    def test_magic_probe_retries_interrupted_reads_and_checks_all_formats(self):
        body = extract(source(FILE), "static int file_has_macho_magic(")
        self.assertIn("O_RDONLY | O_CLOEXEC", body)
        self.assertIn("errno == EINTR", body)
        self.assertIn("if (n == 0) break;", body)
        self.assertIn("size == sizeof(magic)", body)
        for magic in ("MH_MAGIC", "MH_CIGAM", "MH_MAGIC_64", "MH_CIGAM_64",
                      "FAT_MAGIC", "FAT_CIGAM", "FAT_MAGIC_64", "FAT_CIGAM_64"):
            self.assertIn(f"magic == {magic}", body)
        self.assertIn("if (close(fd) != 0 && status == 0)", body)

    def test_directory_io_and_callback_errors_propagate(self):
        body = extract(source(FILE), "static int walk_machos_in_dir(")
        for token in ("int (^macho_fat_walk)", "errno = 0;",
                      "if (errno != 0) status = errno;",
                      "if (!full_path)", "status = ENOMEM;",
                      "lstat(full_path, &st)", "if (!fat) status = ENOEXEC;",
                      "status = macho_fat_walk(full_path, fat);",
                      "status = walk_machos_in_dir(full_path, macho_fat_walk, true);",
                      "if (closedir(dir) != 0 && status == 0)",
                      "if (status != 0) break;"):
            self.assertIn(token, body)
        self.assertNotIn("stat(full_path, &st)", body.replace("lstat(full_path, &st)", ""))

    def test_resources_are_filtered_before_parsing(self):
        body = extract(source(FILE), "static int walk_machos_in_dir(")
        self.assertLess(body.index("file_has_macho_magic("),
                        body.index("fat_init_from_path("))
        self.assertIn("if (status == 0 && isMacho)", body)
        self.assertIn("S_ISREG(st.st_mode)", body)

    def test_directory_retains_rc9_per_file_policy(self):
        body = extract(source(FILE), "int directory_collect_untrusted_cdhashes_by_path(")
        self.assertIn("file_collect_untrusted_cdhashes_by_path(path,", body)
        self.assertNotIn("fat_collect_untrusted_cdhashes(", body)
        self.assertIn("thiscdhashCount > UINT32_MAX - cdhashCount", body)
        self.assertIn("(size_t)newCount * sizeof(cdhash_t)", body)
        self.assertLess(body.index("free(cdhashes);\n\t\treturn collectionStatus;"),
                        body.index("*cdhashesOut = cdhashes;"))

    def test_upload_requires_complete_collection_and_always_cleans_up(self):
        for anchor in ("int jb_trustcache_add_file(", "int jb_trustcache_add_directory("):
            body = extract(source(FILE), anchor)
            self.assertIn("if (status == 0 && cdhashCount > 0)", body)
            self.assertIn("free(cdhashes);\n\treturn status;", body)

    def test_native_regression_is_required_by_ci(self):
        self.assertIn("python3 tests/test_rc9_trustcache_directory.py --native",
                      source(".github/workflows/roothide.yml"))


PREFIX = r'''
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef uint8_t cdhash_t[20];
typedef struct { int placeholder; } Fat;
static Fat parsedFat;
static int allocations, openFiles, openDirs, openFats;
static int allocCalls, growCalls, dirCalls, parseCalls, collectCalls, addCalls;
static int failAllocation, failGrowth, failDirAt, failParseAt, failCollectAt;
static int readDirAfter, oversizedCountAt, collectError, addStatus;
static bool failStat, failOpen, failRead, interruptRead, failClose, failCloseDir;
static bool skipHashes, emptyAllocation;
static size_t maxRead;
static uint32_t addedCount;
static char fixtures[32][PATH_MAX];
static bool fixtureIsDir[32];
static size_t fixtureCount;

static void remember(const char *path, bool isDir) {
    assert(fixtureCount < 32 && strlen(path) < PATH_MAX);
    strcpy(fixtures[fixtureCount], path);
    fixtureIsDir[fixtureCount++] = isDir;
}
static void path_join(char *out, const char *dir, const char *name) {
    int n = snprintf(out, PATH_MAX, "%s/%s", dir, name);
    assert(n > 0 && n < PATH_MAX);
}
static void write_raw(const char *path, const void *data, size_t size) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600); assert(fd >= 0);
    if (size) assert(write(fd, data, size) == (ssize_t)size);
    assert(close(fd) == 0);
}
static void make_file(char *out, const char *dir, const char *name,
                      const void *data, size_t size) {
    path_join(out, dir, name); write_raw(out, data, size); remember(out, false);
}
static void cleanup(void) {
    while (fixtureCount) {
        size_t i = --fixtureCount;
        assert((fixtureIsDir[i] ? rmdir(fixtures[i]) : unlink(fixtures[i])) == 0);
    }
}
static void *test_malloc(size_t size) {
    if (allocCalls++ == failAllocation) { errno = ENOMEM; return NULL; }
    void *p = malloc(size); assert(p); allocations++; return p;
}
static void test_free(void *p) {
    if (p) { assert(allocations > 0); allocations--; free(p); }
}
static void *test_realloc(void *p, size_t size) {
    if (growCalls++ == failGrowth) { errno = ENOMEM; return NULL; }
    bool isNew = p == NULL;
    void *next = realloc(p, size); assert(next);
    if (isNew) allocations++;
    return next;
}
static DIR *test_opendir(const char *path) {
    if (dirCalls++ == failDirAt) { errno = EACCES; return NULL; }
    DIR *dir = opendir(path);
    if (dir) openDirs++;
    return dir;
}
static struct dirent *test_readdir(DIR *dir) {
    if (readDirAfter >= 0 && collectCalls >= readDirAfter) { errno = EIO; return NULL; }
    return readdir(dir);
}
static int test_closedir(DIR *dir) {
    assert(openDirs > 0); openDirs--;
    assert(closedir(dir) == 0);
    errno = ENOSPC;
    return failCloseDir ? -1 : 0;
}
static int test_lstat(const char *path, struct stat *st) {
    if (failStat) { errno = ENOENT; return -1; }
    return lstat(path, st);
}
static int test_open(const char *path, int flags) {
    assert(flags == (O_RDONLY | O_CLOEXEC));
    if (failOpen) { errno = EACCES; return -1; }
    int fd = open(path, flags);
    if (fd >= 0) openFiles++;
    return fd;
}
static ssize_t test_read(int fd, void *data, size_t size) {
    if (interruptRead) { interruptRead = false; errno = EINTR; return -1; }
    if (failRead) { errno = EIO; return -1; }
    if (size > maxRead) size = maxRead;
    return read(fd, data, size);
}
static int test_close(int fd) {
    assert(openFiles > 0); openFiles--;
    assert(close(fd) == 0);
    errno = EBADF;
    return failClose ? -1 : 0;
}
static Fat *fat_init_from_path(const char *path) {
    assert(path);
    if (parseCalls++ == failParseAt) { errno = EINVAL; return NULL; }
    openFats++; return &parsedFat;
}
static void fat_free(Fat *fat) {
    assert(fat == &parsedFat && openFats > 0); openFats--; errno = EBADF;
}
static int file_collect_untrusted_cdhashes_by_path(const char *path,
        cdhash_t **hashes, uint32_t *count) {
    assert(path); collectCalls++; *hashes = NULL; *count = 0;
    if (skipHashes && !emptyAllocation) return 0;
    *hashes = test_malloc(sizeof(cdhash_t));
    if (!*hashes) return ENOMEM;
    memset(*hashes, collectCalls, sizeof(cdhash_t));
    if (collectCalls == failCollectAt) return collectError;
    if (!skipHashes) *count = collectCalls == oversizedCountAt ? UINT32_MAX : 1;
    errno = EACCES; /* Successful helpers must not masquerade as readdir failure. */
    return 0;
}
static int jb_trustcache_add_cdhashes(cdhash_t *hashes, uint32_t count) {
    assert(hashes && count > 0); addCalls++; addedCount = count; return addStatus;
}
static void reset(void) {
    assert(!allocations && !openFiles && !openDirs && !openFats);
    allocCalls = growCalls = dirCalls = parseCalls = collectCalls = addCalls = 0;
    failAllocation = failGrowth = failDirAt = failParseAt = -1;
    failCollectAt = readDirAfter = oversizedCountAt = -1;
    collectError = EACCES; addStatus = 0; addedCount = 0;
    failStat = failOpen = failRead = interruptRead = failClose = failCloseDir = false;
    skipHashes = emptyAllocation = false; maxRead = SIZE_MAX; errno = 0;
}
#define malloc test_malloc
#define free test_free
#define realloc test_realloc
#define opendir test_opendir
#define readdir test_readdir
#define closedir test_closedir
#define lstat(...) test_lstat(__VA_ARGS__)
#define open test_open
#define read test_read
#define close test_close
'''

MAIN = r'''
static void expect_failure(const char *dir, bool recurse, int status) {
    cdhash_t *hashes = (void *)(uintptr_t)1; uint32_t count = 99;
    assert(directory_collect_untrusted_cdhashes_by_path(dir, recurse, &hashes, &count) == status);
    assert(!hashes && !count && !allocations && !openFiles && !openDirs && !openFats);
    assert(!addCalls);
}
int main(void) {
    char root[] = "/tmp/rc9-directory-XXXXXX";
    assert(mkdtemp(root)); remember(root, true);
    char first[PATH_MAX], second[PATH_MAX], resource[PATH_MAX], shortFile[PATH_MAX];
    char empty[PATH_MAX], sub[PATH_MAX], nested[PATH_MAX], link[PATH_MAX], fifo[PATH_MAX];
    uint32_t magic = MH_MAGIC_64, plain = 0x12345678;
    make_file(first, root, "first.dylib", &magic, sizeof(magic));
    make_file(second, root, "second.dylib", &magic, sizeof(magic));
    make_file(resource, root, "resource", &plain, sizeof(plain));
    make_file(shortFile, root, "short", &magic, 2);
    make_file(empty, root, "empty", NULL, 0);
    path_join(sub, root, "sub"); assert(mkdir(sub, 0700) == 0); remember(sub, true);
    make_file(nested, sub, "nested.dylib", &magic, sizeof(magic));
    path_join(link, root, "link"); assert(symlink(first, link) == 0); remember(link, false);
    path_join(fifo, root, "fifo"); assert(mkfifo(fifo, 0600) == 0); remember(fifo, false);

    uint32_t magics[] = {MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64,
                        FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64};
    bool isMacho;
    for (size_t i = 0; i < sizeof(magics) / sizeof(magics[0]); i++) {
        reset(); write_raw(first, &magics[i], sizeof(magics[i]));
        maxRead = 1; interruptRead = true;
        assert(file_has_macho_magic(first, &isMacho) == 0 && isMacho);
    }
    write_raw(first, &magic, sizeof(magic));
    const char *resources[] = {resource, shortFile, empty};
    for (size_t i = 0; i < 3; i++) {
        reset(); isMacho = true;
        assert(file_has_macho_magic(resources[i], &isMacho) == 0 && !isMacho);
    }
    reset(); failOpen = true;
    assert(file_has_macho_magic(first, &isMacho) == EACCES && !isMacho);
    reset(); failRead = failClose = true;
    assert(file_has_macho_magic(first, &isMacho) == EIO && !isMacho);
    reset(); failClose = true;
    assert(file_has_macho_magic(first, &isMacho) == EBADF && !isMacho);

    cdhash_t *hashes; uint32_t count;
    reset();
    assert(directory_collect_untrusted_cdhashes_by_path(NULL, false, &hashes, &count) == EINVAL);
    assert(directory_collect_untrusted_cdhashes_by_path(root, false, NULL, &count) == EINVAL);
    assert(directory_collect_untrusted_cdhashes_by_path(root, false, &hashes, NULL) == EINVAL);
    reset();
    assert(directory_collect_untrusted_cdhashes_by_path(root, false, &hashes, &count) == 0);
    assert(count == 2 && collectCalls == 2 && parseCalls == 2 && dirCalls == 1);
    free(hashes);
    reset();
    assert(directory_collect_untrusted_cdhashes_by_path(root, true, &hashes, &count) == 0);
    assert(count == 3 && collectCalls == 3 && parseCalls == 3 && dirCalls == 2);
    free(hashes);
    reset();
    assert(directory_collect_untrusted_cdhashes_by_path(sub, false, &hashes, &count) == 0);
    assert(count == 1); free(hashes);
    reset(); skipHashes = true;
    assert(directory_collect_untrusted_cdhashes_by_path(root, true, &hashes, &count) == 0);
    assert(!hashes && !count && !allocations);

    reset(); failDirAt = 0; expect_failure(root, true, EACCES);
    reset(); failDirAt = 1; expect_failure(root, true, EACCES);
    reset(); readDirAfter = 0; expect_failure(root, true, EIO);
    reset(); readDirAfter = 1; expect_failure(root, false, EIO);
    assert(collectCalls == 1 && growCalls == 1);
    reset(); failStat = true; expect_failure(root, true, ENOENT);
    reset(); failOpen = true; expect_failure(root, false, EACCES);
    reset(); failRead = true; expect_failure(root, false, EIO);
    reset(); failClose = true; expect_failure(root, false, EBADF);
    reset(); failCloseDir = true; expect_failure(root, false, ENOSPC);
    assert(collectCalls == 2);
    reset(); failParseAt = 0; expect_failure(root, true, ENOEXEC);
    reset(); failParseAt = 1; expect_failure(root, false, ENOEXEC);
    assert(collectCalls == 1);
    reset(); failParseAt = 0; failCloseDir = true; expect_failure(root, false, ENOEXEC);
    reset(); failAllocation = 0; expect_failure(root, false, ENOMEM);
    reset(); failGrowth = 0; expect_failure(root, false, ENOMEM);
    reset(); failGrowth = 1; expect_failure(root, false, ENOMEM);
    assert(collectCalls == 2);
    reset(); failCollectAt = 2; expect_failure(root, false, EACCES);
    assert(collectCalls == 2);
    reset(); oversizedCountAt = 2; expect_failure(root, false, EOVERFLOW);
    assert(collectCalls == 2 && growCalls == 1);

    reset(); failDirAt = 1;
    assert(jb_trustcache_add_directory(root, true) == EACCES && !addCalls);
    reset(); failCollectAt = 2;
    assert(jb_trustcache_add_directory(root, false) == EACCES && !addCalls);
    reset(); addStatus = EBUSY;
    assert(jb_trustcache_add_directory(root, true) == EBUSY);
    assert(addCalls == 1 && addedCount == 3 && !allocations);
    reset();
    assert(jb_trustcache_add_directory(root, false) == 0);
    assert(addCalls == 1 && addedCount == 2 && !allocations);
    reset(); skipHashes = true;
    assert(jb_trustcache_add_directory(root, true) == 0 && !addCalls && !allocations);
    reset(); failCollectAt = 1;
    assert(jb_trustcache_add_file(first) == EACCES && !addCalls && !allocations);
    reset(); addStatus = EBUSY;
    assert(jb_trustcache_add_file(first) == EBUSY && addCalls == 1 && !allocations);
    reset(); skipHashes = emptyAllocation = true;
    assert(jb_trustcache_add_file(first) == 0 && !addCalls && !allocations);
    reset();
    assert(jb_trustcache_add_file(first) == 0 && addCalls == 1 && !allocations);
    reset(); cleanup();
    puts("PASS: real directory traversal, Mach-O magic, recursive errors, partial cleanup and no upload on failure");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    code = "\n".join((
        PREFIX,
        *(extract(source(FILE), anchor) for anchor in (
            "static int file_has_macho_magic(",
            "static int walk_machos_in_dir(",
            "int directory_collect_untrusted_cdhashes_by_path(",
            "int jb_trustcache_add_file(",
            "int jb_trustcache_add_directory(",
        )),
        MAIN,
    ))
    with tempfile.TemporaryDirectory(prefix="rc9-trustcache-directory-") as tmp:
        path = Path(tmp) / "directory.c"
        binary = Path(tmp) / "directory-test"
        path.write_text(code, encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-fblocks", "-Wall", "-Wextra",
                        "-Werror", "-Wno-unused-parameter", "-O1", "-g",
                        "-fsanitize=address,undefined", str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(DirectoryCollectionContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
