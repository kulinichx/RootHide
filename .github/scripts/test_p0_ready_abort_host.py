#!/usr/bin/env python3
"""Host-only tests compiling selected REAL P0 READY/ABORT functions with Mach stubs.

No iOS runtime/SDK: does not prove XPC transport timing or kernel port semantics.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'BaseBin/libjailbreak/src/roothider/jailbreakd.c').read_text()

def function(signature):
    start = SOURCE.index(signature)
    left = SOURCE.index('{', start)
    depth = 0
    for i in range(left, len(SOURCE)):
        if SOURCE[i] == '{':
            depth += 1
        elif SOURCE[i] == '}':
            depth -= 1
            if depth == 0:
                return SOURCE[start:i + 1]
    raise AssertionError(signature)

signatures = [
    'static int destroyLocalJailbreakdServerPortLocked(void)',
    'static void advanceJailbreakdPortGenerationLocked(void)',
    'int jailbreakdServerPortCheckinReady(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)',
    'int jailbreakdServerPortCheckinAbort(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)',
    'static bool jailbreakdCheckinTicketMatchesLocked(const jailbreakd_checkin_ticket_t *ticket)',
    'int jailbreakdServerPortCheckinComplete(const jailbreakd_checkin_ticket_t *ticket)',
    'void jailbreakdServerPortCheckinFailed(const jailbreakd_checkin_ticket_t *ticket)',
]
actual_functions = '\n\n'.join(function(sig) for sig in signatures)

harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

typedef unsigned int mach_port_t;
typedef int kern_return_t;
#define MACH_PORT_NULL 0
#define MACH_PORT_VALID(p) ((p) != MACH_PORT_NULL)
#define MACH_PORT_RIGHT_RECEIVE 1
#define KERN_SUCCESS 0
#define HOST_LAUNCHCTL_PORT 9
#define JAILBREAKD_CLIENT_PORT_FAST_GET
#define JBLogError(...) do {} while (0)
#define getpid() (1)

typedef struct { pid_t pid; uint64_t generation; mach_port_t port; } jailbreakd_checkin_ticket_t;
static bool __jailbreakd_initialized = true;
static bool __jailbreakd_port_ready = false;
static bool __jailbreakd_port_published = false;
static pthread_mutex_t __jailbreakd_port_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t __jailbreakd_port_generation = 7;
static pid_t __jailbreakd_expected_pid = 123;
static pid_t __jailbreakd_child_pid = 123;
static bool __jailbreakd_candidate_pending = true;
static bool __jailbreakd_checkin_in_progress = true;
static char __jailbreakd_checkin_token[33] = "0123456789abcdef0123456789abcdef";
static pid_t __jailbreakd_ready_pid = 0;
static uint64_t __jailbreakd_ready_generation = 0;
static char __jailbreakd_ready_token[33] = {0};
static mach_port_t gJailbreakdPort = 500;
static unsigned int publish_count, revoke_count, destroy_count, kill_count;
static pid_t killed_pid;
static mach_port_t published_port;

static mach_port_t mach_host_self(void) { return 66; }
static mach_port_t mach_task_self(void) { return 22; }
static kern_return_t mach_port_deallocate(mach_port_t task, mach_port_t port)
{ (void)task; (void)port; return KERN_SUCCESS; }
static kern_return_t host_set_special_port(mach_port_t host, int slot, mach_port_t port)
{
    assert(host == 66 && slot == HOST_LAUNCHCTL_PORT);
    if (port == MACH_PORT_NULL) {
        ++revoke_count;
        assert(!__jailbreakd_port_ready);
    } else {
        ++publish_count;
        /* The new publication must not predate the launchd READY flag. */
        assert(__jailbreakd_port_ready && __jailbreakd_ready_pid == 123);
        assert(port == gJailbreakdPort);
    }
    published_port = port;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_destroy(mach_port_t task, mach_port_t port)
{ assert(task == 22 && port == gJailbreakdPort); ++destroy_count; return KERN_SUCCESS; }
static const char *mach_error_string(kern_return_t kr)
{ (void)kr; return "mock"; }
static void terminateJailbreakdChild(pid_t pid)
{ if (pid > 1) { ++kill_count; killed_pid = pid; } }
static void scheduleJailbreakdReadyLivenessWatchdog(uint64_t generation)
{ assert(generation != 0); }

/* INSERT_SOURCE */

static const char TOKEN[] = "0123456789abcdef0123456789abcdef";
static void test_ready_rollback(void)
{
    jailbreakd_checkin_ticket_t ready = {0};
    assert(jailbreakdServerPortCheckinReady(123, TOKEN, &ready) == 0);
    assert(ready.pid == 123 && ready.port == 500 && ready.generation == 7);
    assert(jailbreakdServerPortCheckinComplete(&ready) == 0);
    assert(__jailbreakd_port_ready && publish_count == 1 && published_port == 500);
    assert(__jailbreakd_ready_pid == 123);
    jailbreakd_checkin_ticket_t dup = {0};
    assert(jailbreakdServerPortCheckinReady(123, TOKEN, &dup) == 0);
    assert(jailbreakdServerPortCheckinComplete(&dup) == 0);
    assert(publish_count == 1); /* duplicate READY does not publish again */

    jailbreakd_checkin_ticket_t abort = {0};
    assert(jailbreakdServerPortCheckinAbort(124, TOKEN, &abort) != 0);
    assert(jailbreakdServerPortCheckinAbort(123, "ffffffffffffffffffffffffffffffff", &abort) != 0);
    assert(__jailbreakd_port_ready && published_port == 500);
    assert(jailbreakdServerPortCheckinAbort(123, TOKEN, &abort) == 0);
    jailbreakdServerPortCheckinFailed(&abort);
    assert(!__jailbreakd_port_ready && !__jailbreakd_candidate_pending);
    assert(gJailbreakdPort == 0 && published_port == 0);
    assert(__jailbreakd_ready_pid == 0 && __jailbreakd_ready_generation == 0);
    assert(__jailbreakd_ready_token[0] == 0);
    assert(revoke_count == 1 && destroy_count == 1 && !__jailbreakd_port_published);
    assert(kill_count == 1 && killed_pid == 123);
    assert(__jailbreakd_port_generation == 8);
    puts("READY_RETRY_AND_ABORT_COMMITTED=PASS");
}
static void test_stale_ticket_isolation(void)
{
    jailbreakd_checkin_ticket_t stale = {123, 7, 500};
    __jailbreakd_expected_pid = 555;
    __jailbreakd_child_pid = 555;
    __jailbreakd_candidate_pending = true;
    __jailbreakd_checkin_in_progress = true;
    gJailbreakdPort = 600;
    strcpy(__jailbreakd_checkin_token, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    jailbreakdServerPortCheckinFailed(&stale);
    assert(gJailbreakdPort == 600 && __jailbreakd_port_generation == 8);
    assert(jailbreakdServerPortCheckinAbort(123, TOKEN, &stale) != 0);
    jailbreakd_checkin_ticket_t current = {0};
    assert(jailbreakdServerPortCheckinAbort(555, __jailbreakd_checkin_token, &current) == 0);
    jailbreakdServerPortCheckinFailed(&current);
    assert(gJailbreakdPort == 0 && __jailbreakd_port_generation == 9);
    assert(revoke_count == 1 && destroy_count == 2);
    assert(kill_count == 2 && killed_pid == 555);
    puts("STALE_TICKET_ISOLATION_AND_PENDING_ABORT=PASS");
}
static void test_revoke_during_restart(void)
{
    /* The READY flag can be cleared after a crashed daemon is detected,
     * while its host special port remains published until teardown. */
    __jailbreakd_port_ready = false;
    __jailbreakd_port_published = true;
    gJailbreakdPort = 700;
    assert(destroyLocalJailbreakdServerPortLocked() == 0);
    assert(gJailbreakdPort == 0 && !__jailbreakd_port_published);
    assert(revoke_count == 2 && destroy_count == 3);
    puts("RESTART_REVOKES_STALE_PUBLISHED_PORT=PASS");
}
int main(void)
{
    test_ready_rollback();
    test_stale_ticket_isolation();
    test_revoke_during_restart();
    puts("READY_ABORT_HOST_TESTS=PASS");
    return 0;
}
'''
code = harness.replace('/* INSERT_SOURCE */', actual_functions)
with tempfile.TemporaryDirectory(prefix='p0_ready_') as directory:
    path = pathlib.Path(directory) / 'host.c'
    binary = pathlib.Path(directory) / 'host'
    path.write_text(code)
    command = ['clang', '-std=c11', '-D_DEFAULT_SOURCE', '-Wall', '-Wextra', '-Werror',
               '-Wno-unused-function', '-fsanitize=address,undefined', '-pthread', str(path), '-o', str(binary)]
    subprocess.run(command, check=True)
    subprocess.run([str(binary)], check=True)
