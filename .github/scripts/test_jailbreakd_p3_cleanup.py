#!/usr/bin/env python3
"""Host-only fault injection of the actual unregistered-child cleanup helper.

Mocks signal, waitpid, and delayed scheduling; does not validate iOS process
reparenting, launchd, or real Mach/XPC behavior.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
text = (root / 'BaseBin/libjailbreak/src/roothider/jailbreakd.c').read_text()
signature = 'static void terminateUnregisteredJailbreakdChild(pid_t pid)'
start = text.index(signature)
brace = text.index('{', start)
depth = 0
for i in range(brace, len(text)):
    if text[i] == '{':
        depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            actual_function = text[start:i + 1]
            break
else:
    raise AssertionError('unbalanced cleanup function')

assert 'terminateUnregisteredJailbreakdChild(pid);' in text
assert 'scheduleJailbreakdParentReap(pid, 50);' in actual_function

harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#define SIGKILL 9
#define WNOHANG 1
#define JBLogError(...) ((void)0)
typedef int pid_t;
static int kill_mode, wait_mode, kill_calls, wait_calls, schedules;
static unsigned int scheduled_retries;
static int mock_kill(pid_t pid, int sig) {
    assert(pid == 123 && sig == SIGKILL);
    ++kill_calls;
    if (kill_mode == 1 && kill_calls == 1) { errno = EINTR; return -1; }
    if (kill_mode == 2) { errno = EPERM; return -1; }
    return 0;
}
static pid_t mock_waitpid(pid_t pid, int *status, int options) {
    assert(pid == 123 && status && options == WNOHANG);
    ++wait_calls;
    if (wait_mode == 1) return 0;
    if (wait_mode == 2) { errno = ECHILD; return -1; }
    if (wait_mode == 3 && wait_calls == 1) { errno = EINTR; return -1; }
    return pid;
}
static void scheduleJailbreakdParentReap(pid_t pid, unsigned int retries) {
    assert(pid == 123);
    ++schedules;
    scheduled_retries = retries;
}
#define kill mock_kill
#define waitpid mock_waitpid
/* INSERT_REAL_FUNCTION */
static void reset(void) {
    kill_mode=wait_mode=kill_calls=wait_calls=schedules=0;
    scheduled_retries=0;
    errno=0;
}
int main(void) {
    reset(); wait_mode=1;
    terminateUnregisteredJailbreakdChild(123);
    assert(kill_calls == 1 && wait_calls == 1 && schedules == 1 && scheduled_retries == 50);
    puts("STILL_RUNNING_SCHEDULED=PASS");
    reset();
    terminateUnregisteredJailbreakdChild(123);
    assert(kill_calls == 1 && wait_calls == 1 && schedules == 0);
    puts("IMMEDIATE_REAP=PASS");
    reset(); kill_mode=1; wait_mode=3;
    terminateUnregisteredJailbreakdChild(123);
    assert(kill_calls == 2 && wait_calls == 2 && schedules == 0);
    puts("INTERRUPTED_RETRY=PASS");
    reset(); wait_mode=2;
    terminateUnregisteredJailbreakdChild(123);
    assert(kill_calls == 1 && wait_calls == 1 && schedules == 0);
    puts("ALREADY_REAPED=PASS");
    reset(); kill_mode=2; wait_mode=1;
    terminateUnregisteredJailbreakdChild(123);
    assert(kill_calls == 1 && wait_calls == 1 && schedules == 1);
    puts("KILL_ERROR_DEFERRED_CHECK=PASS");
    reset(); terminateUnregisteredJailbreakdChild(0);
    assert(kill_calls == 0 && wait_calls == 0 && schedules == 0);
    puts("INVALID_PID_GUARDED=PASS");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as workdir:
    path = Path(workdir)
    source = path / 'p3_cleanup.c'
    binary = path / 'p3_cleanup'
    source.write_text(harness.replace('/* INSERT_REAL_FUNCTION */', actual_function))
    subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('P3_HOST_CLEANUP_TEST=PASS (source-extracted helper; mocked POSIX calls)')
