"""Fork handshake regressions extracted from production C.

--native runs fault-injection tests and real host pipe/fork integration.
The Darwin raw syscall assembly and iOS permission fixup still need Apple
compilation and device validation; the host permission server is a test double.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


MAIN = "BaseBin/forkfix/src/main.c"
ASM = "BaseBin/forkfix/src/syscall.S"
HEADER = "BaseBin/forkfix/src/syscall.h"


class ForkfixContracts(unittest.TestCase):
    def test_pipes_belong_to_each_fork_and_partial_setup_is_cleaned(self):
        text = source(MAIN)
        self.assertNotIn("int childToParentPipe[2]", text)
        self.assertNotIn("int parentToChildPipe[2]", text)
        body = extract(text, "pid_t forkfix___fork(void)")
        self.assertIn("struct fork_pipes pipes = {{-1, -1}, {-1, -1}};", body)
        setup = extract(text, "static int open_pipes(")
        self.assertEqual(setup.count("F_SETNOSIGPIPE"), 2)
        self.assertIn("close_pipes(pipes);", setup)
        cleanup = extract(text, "static void close_pipes(")
        self.assertEqual(cleanup.count("close_pipe_end("), 4)
        self.assertNotIn("||", cleanup)

    def test_handshake_checks_raw_errors_interrupts_and_eof(self):
        body = extract(source(MAIN), "static int handshake_byte(")
        self.assertIn("transferred == -EINTR", body)
        self.assertIn("transferred == 1", body)
        self.assertIn("(int)-transferred", body)
        self.assertIn("transferred == 0 ? EPIPE : EIO", body)
        for name in ("read", "write"):
            asm = source(ASM).split(f"_ffsys_{name}:", 1)[1].split("\tret", 1)[0]
            self.assertIn("cneg x0, x0, cs", asm)

    def test_failed_fixup_cannot_release_child_or_abort_parent(self):
        text = source(MAIN)
        parent = extract(text, "static int parent_fixup(")
        self.assertLess(parent.index("jbclient_mach_fork_fix"), parent.index(", true)"))
        body = extract(text, "pid_t forkfix___fork(void)")
        self.assertIn("if (child_fixup(&pipes) != 0) ffsys_exit(127);", body)
        self.assertIn("kill(pid, SIGKILL);", body)
        self.assertIn("waitpid(pid, NULL, 0) < 0 && errno == EINTR", body)
        self.assertNotIn("abort(", body)
        self.assertIn("__attribute__((noreturn)) void ffsys_exit(int status);", source(HEADER))
        self.assertIn("_ffsys_exit:", source(ASM))

    def test_native_regressions_and_focused_target_are_in_ci(self):
        workflow = source(".github/workflows/roothide.yml")
        self.assertIn("python3 tests/test_rc9_forkfix.py --native", workflow)
        self.assertIn("make -C BaseBin forkfix", workflow)
        self.assertIn("artifacts/forkfix.dylib", workflow)


MOCK_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/types.h>

enum { F_SETNOSIGPIPE = 123 };
static bool live[128], exitArmed, nested;
static int nextFd, pipeCalls, pipeFailure, flagCalls, flagFailure, closeCalls, closeFailure;
static int forkCalls, forkResult, reads, writes, fixes, fixError, kills, waits, waitInterrupts;
static int readScript[8], writeScript[8], readCount, writeCount, depth, exitStatus;
static jmp_buf exitJump;
pid_t forkfix___fork(void);

static void reset(void) {
    memset(live, 0, sizeof(live));
    nextFd = 10; pipeCalls = flagCalls = closeCalls = forkCalls = 0;
    pipeFailure = flagFailure = closeFailure = -1;
    forkResult = 42; reads = writes = fixes = fixError = kills = waits = waitInterrupts = 0;
    readCount = writeCount = depth = 0; exitArmed = nested = false; exitStatus = -1;
    errno = 0;
}
static void assert_closed(void) {
    for (int i = 0; i < 128; i++) assert(!live[i]);
}
static int mock_pipe(int fds[2]) {
    if (pipeCalls++ == pipeFailure) { errno = EMFILE; return -1; }
    assert(nextFd + 2 < 128);
    fds[0] = nextFd++; fds[1] = nextFd++;
    live[fds[0]] = live[fds[1]] = true;
    return 0;
}
static int mock_fcntl(int fd, int command, int value) {
    assert(live[fd] && command == F_SETNOSIGPIPE && value == 1);
    if (flagCalls++ == flagFailure) { errno = EINVAL; return -1; }
    return 0;
}
static int ffsys_close(int fd) {
    assert(fd >= 0 && fd < 128 && live[fd]);
    live[fd] = false; closeCalls++;
    errno = EBADF; /* Detect loss of a saved error during cleanup. */
    return fd == closeFailure ? EIO : 0;
}
static pid_t ffsys_fork(void) {
    forkCalls++;
    if (nested && !depth) {
        depth++;
        assert(forkfix___fork() == 42);
        depth--;
        for (int i = 10; i < 14; i++) assert(live[i]);
    }
    if (forkResult < 0) errno = EAGAIN;
    return forkResult;
}
static ssize_t ffsys_read(int fd, void *data, size_t length) {
    assert(live[fd] && data && length == 1);
    int result = reads < readCount ? readScript[reads] : 1;
    reads++;
    if (result == 1) *(char *)data = ' ';
    return result;
}
static ssize_t ffsys_write(int fd, const void *data, size_t length) {
    assert(live[fd] && data && length == 1);
    int result = writes < writeCount ? writeScript[writes] : 1;
    writes++;
    return result;
}
static int64_t jbclient_mach_fork_fix(pid_t pid) {
    assert(pid == 42 && reads > 0 && fixes == writes);
    fixes++; return fixError;
}
static int mock_kill(pid_t pid, int sig) {
    assert(pid == 42 && sig == SIGKILL); kills++; return 0;
}
static pid_t mock_waitpid(pid_t pid, int *status, int flags) {
    assert(pid == 42 && !status && !flags); waits++;
    if (waits <= waitInterrupts) { errno = EINTR; return -1; }
    return pid;
}
__attribute__((noreturn)) static void ffsys_exit(int status) {
    assert(exitArmed); exitStatus = status;
    memset(live, 0, sizeof(live)); /* Kernel closes descriptors on exit. */
    longjmp(exitJump, 1);
}
#define pipe mock_pipe
#define fcntl mock_fcntl
#define kill mock_kill
#define waitpid mock_waitpid
'''

MOCK_MAIN = r'''
int main(void) {
    for (int failure = 0; failure < 2; failure++) {
        reset(); pipeFailure = failure;
        assert(forkfix___fork() == -1 && errno == EMFILE);
        assert(forkCalls == 0 && closeCalls == failure * 2); assert_closed();
        reset(); flagFailure = failure;
        assert(forkfix___fork() == -1 && errno == EINVAL);
        assert(forkCalls == 0 && closeCalls == 4); assert_closed();
    }
    reset(); forkResult = -1;
    assert(forkfix___fork() == -1 && errno == EAGAIN);
    assert(reads == 0 && writes == 0 && closeCalls == 4); assert_closed();

    reset();
    assert(forkfix___fork() == 42);
    assert(reads == 1 && writes == 1 && fixes == 1 && kills == 0 && closeCalls == 4);
    assert_closed();
    reset(); readScript[0] = writeScript[0] = -EINTR; readCount = writeCount = 1;
    assert(forkfix___fork() == 42 && reads == 2 && writes == 2); assert_closed();

    const int failures[] = {0, -EIO, -EBADF, 2};
    for (size_t i = 0; i < sizeof(failures) / sizeof(failures[0]); i++) {
        int expected = failures[i] == 0 ? EPIPE : failures[i] < 0 ? -failures[i] : EIO;
        reset(); readScript[0] = failures[i]; readCount = 1; waitInterrupts = 2;
        assert(forkfix___fork() == -1 && errno == expected);
        assert(fixes == 0 && writes == 0 && kills == 1 && waits == 3);
        assert_closed();
        reset(); writeScript[0] = failures[i]; writeCount = 1;
        assert(forkfix___fork() == -1 && errno == expected);
        assert(fixes == 1 && kills == 1 && waits == 1); assert_closed();
    }
    reset(); fixError = 99;
    assert(forkfix___fork() == -1 && errno == EIO);
    assert(fixes == 1 && writes == 0 && kills == 1 && waits == 1); assert_closed();

    reset(); forkResult = 0;
    assert(forkfix___fork() == 0 && fixes == 0 && reads == 1 && writes == 1);
    assert_closed();
    for (int failedWrite = 0; failedWrite < 2; failedWrite++) {
        reset(); forkResult = 0; exitArmed = true;
        if (failedWrite) { writeScript[0] = -EPIPE; writeCount = 1; }
        else { readScript[0] = 0; readCount = 1; }
        if (setjmp(exitJump) == 0) {
            (void)forkfix___fork(); assert(false);
        }
        assert(exitStatus == 127 && fixes == 0 && kills == 0); assert_closed();
    }
    reset(); closeFailure = 10;
    assert(forkfix___fork() == 42 && closeCalls == 4); assert_closed();

    reset();
    struct fork_pipes first = {{-1, -1}, {-1, -1}};
    struct fork_pipes second = {{-1, -1}, {-1, -1}};
    assert(open_pipes(&first) == 0 && open_pipes(&second) == 0);
    close_pipes(&first); close_pipes(&first);
    assert(closeCalls == 4);
    for (int fd = 14; fd < 18; fd++) assert(live[fd]);
    close_pipes(&second); assert_closed();
    reset(); nested = true;
    assert(forkfix___fork() == 42 && forkCalls == 2 && closeCalls == 8);
    assert_closed();
    puts("PASS: fork pipe setup, isolated calls, raw errors, EINTR, EOF, cleanup and child rejection");
    return 0;
}
'''

HOST_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>

static int fixError;
static pid_t ffsys_fork(void) { return fork(); }
static int ffsys_close(int fd) { return close(fd); }
static ssize_t ffsys_read(int fd, void *data, size_t n) {
    ssize_t r = read(fd, data, n); return r < 0 ? -errno : r;
}
static ssize_t ffsys_write(int fd, const void *data, size_t n) {
    ssize_t r = write(fd, data, n); return r < 0 ? -errno : r;
}
__attribute__((noreturn)) static void ffsys_exit(int status) { _exit(status); }
static int64_t jbclient_mach_fork_fix(pid_t pid) {
    assert(pid > 0); return fixError;
}
'''

HOST_MAIN = r'''
int main(void) {
    alarm(20);
    for (int i = 0; i < 16; i++) {
        pid_t child = forkfix___fork();
        assert(child >= 0);
        if (child == 0) _exit(0);
        int status = 0;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    fixError = EIO;
    assert(forkfix___fork() == -1 && errno == EIO);
    int status = 0;
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    puts("PASS: real host pipes/fork success and failed fixup reaping (permission server mocked)");
    return 0;
}
'''


def production_functions():
    text = source(MAIN)
    return "\n".join((
        extract(text, "struct fork_pipes {") + ";",
        *(extract(text, anchor) for anchor in (
            "static void close_pipe_end(",
            "static void close_pipes(",
            "static int open_pipes(",
            "static int handshake_byte(",
            "static int child_fixup(",
            "static int parent_fixup(",
            "pid_t forkfix___fork(void)",
        )),
    ))


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    with tempfile.TemporaryDirectory(prefix="rc9-forkfix-") as tmp:
        for name, prefix, main in (
            ("faults", MOCK_PREFIX, MOCK_MAIN),
            ("host", HOST_PREFIX, HOST_MAIN),
        ):
            path = Path(tmp) / f"{name}.c"
            binary = Path(tmp) / name
            path.write_text("\n".join((prefix, production_functions(), main)), encoding="utf-8")
            subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                            "-O1", "-g", "-fsanitize=address,undefined",
                            str(path), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ForkfixContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on macOS.")
