#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JBD_PATH = ROOT / "BaseBin/libjailbreak/src/roothider/jailbreakd.c"
DOMAIN_PATH = ROOT / "BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c"
source = JBD_PATH.read_text()
domain_source = DOMAIN_PATH.read_text()


def extract_function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise RuntimeError(f"unterminated function: {signature}")


global_start = source.index("static bool __firstLoad = false;")
global_end = source.index("#define JAILBREAKD_CLIENT_PORT_FAST_GET", global_start)
globals_block = source[global_start:global_end]
function_signatures = [
    "static int destroyLocalJailbreakdServerPortLocked(void)",
    "int registerServerPort()",
    "int jailbreakdServerPortCheckinComplete(void)",
    "void jailbreakdServerPortCheckinFailed(void)",
    "static void jailbreakdServerPortCheckinTimedOut(uint64_t generation)",
    "mach_port_t jailbreakdClientPortFastGet()",
    "int initJailbreakd(bool firstLoad)",
    "mach_port_t reactiveJailbreakdPort()",
    "mach_port_t jailbreakdServerPort()",
    "mach_port_t jailbreakdClientPort()",
]
functions = "\n\n".join(extract_function(source, signature) for signature in function_signatures)
checkin = extract_function(domain_source, "static int roothide_jailbreakd_checkin(")
lookup = extract_function(domain_source, "static int roothide_jailbreakd_lookup(")

# Keep the cross-file check-in order under test as well as compiling the real lifecycle C.
recv_create_at = checkin.index("*portOut = xpc_mach_recv_create(port);")
recv_failure_at = checkin.index("if (!*portOut)", recv_create_at)
ready_at = checkin.index("jailbreakdServerPortCheckinComplete()", recv_failure_at)
failed_at = checkin.index("jailbreakdServerPortCheckinFailed();", recv_failure_at)
assert recv_create_at < recv_failure_at < failed_at < ready_at
assert "xpc_release(*portOut);" in checkin[ready_at:]
assert "MACH_PORT_VALID(port)" in lookup and "xpc_mach_send_create(port)" in lookup
spawn_start = source.index("int spawnJailbreakd()")
spawn_end = source.index("int initJailbreakd(bool firstLoad)", spawn_start)
spawn_source = source[spawn_start:spawn_end]
assert "scheduleJailbreakdServerPortCheckinWatchdog();" in spawn_source
assert spawn_source.index("if (ret != 0)") < spawn_source.index("scheduleJailbreakdServerPortCheckinWatchdog();")

if "--static-only" in sys.argv[1:]:
    print("PASS: jailbreakd check-in/readiness/watchdog source contract")
    raise SystemExit(0)

harness = r'''#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <pthread.h>

typedef uint32_t mach_port_t;
typedef int kern_return_t;
enum {
    KERN_SUCCESS = 0,
    KERN_FAILURE = 5,
    KERN_INVALID_RIGHT = 17,
    MACH_PORT_RIGHT_RECEIVE = 1,
    MACH_PORT_RIGHT_SEND = 2,
    MACH_MSG_TYPE_MAKE_SEND = 20,
    HOST_LOCAL_NODE = 0,
    HOST_LAUNCHCTL_PORT = 4,
};
#define MACH_PORT_NULL ((mach_port_t)0)
#define MACH_PORT_VALID(port) ((port) != MACH_PORT_NULL)
#define JAILBREAKD_CLIENT_PORT_FAST_GET
static void fake_log(const char *format, ...) { (void)format; }
#define JBLogDebug(...) fake_log(__VA_ARGS__)
#define JBLogError(...) fake_log(__VA_ARGS__)
#define roothide_stage_log(...) fake_log(__VA_ARGS__)

typedef struct {
    bool allocated;
    bool receive;
    bool send;
    bool dead;
    int send_refs;
    int destroy_count;
} fake_port_t;

enum { MAX_FAKE_PORTS = 512 };
static fake_port_t fake_ports[MAX_FAKE_PORTS];
static mach_port_t next_port = 100;
static mach_port_t host_special_port = MACH_PORT_NULL;
static bool fail_allocate;
static bool fail_insert_right;
static bool fail_host_set;
static int launchd_pid = 1;
static int spawn_result;
static int spawn_calls;
static int lookup_calls;
static mach_port_t lookup_result = 700;

static pid_t fake_getpid(void) { return (pid_t)launchd_pid; }
#define getpid fake_getpid
#define sleep(seconds) do { (void)(seconds); } while (0)

static mach_port_t mach_task_self(void) { return 1; }
static mach_port_t mach_host_self(void) { return 2; }
static kern_return_t mach_port_allocate(mach_port_t task, int right, mach_port_t *port)
{
    (void)task; (void)right;
    if (fail_allocate || next_port >= MAX_FAKE_PORTS) return KERN_FAILURE;
    *port = next_port++;
    fake_ports[*port] = (fake_port_t){ .allocated = true, .receive = true };
    return KERN_SUCCESS;
}
static kern_return_t mach_port_insert_right(mach_port_t task, mach_port_t name,
                                             mach_port_t poly, int disposition)
{
    (void)task; (void)poly; (void)disposition;
    if (fail_insert_right || name >= MAX_FAKE_PORTS || !fake_ports[name].allocated)
        return KERN_FAILURE;
    fake_ports[name].send = true;
    fake_ports[name].send_refs = 1;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_destroy(mach_port_t task, mach_port_t name)
{
    (void)task;
    if (name == MACH_PORT_NULL || name >= MAX_FAKE_PORTS) return KERN_INVALID_RIGHT;
    fake_ports[name].destroy_count++;
    fake_ports[name].allocated = false;
    fake_ports[name].receive = false;
    fake_ports[name].send = false;
    fake_ports[name].dead = true;
    fake_ports[name].send_refs = 0;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_mod_refs(mach_port_t task, mach_port_t name,
                                         int right, int delta)
{
    (void)task;
    if (right != MACH_PORT_RIGHT_SEND || name == MACH_PORT_NULL ||
        name >= MAX_FAKE_PORTS || !fake_ports[name].allocated ||
        !fake_ports[name].send || fake_ports[name].dead)
        return KERN_INVALID_RIGHT;
    fake_ports[name].send_refs += delta;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_deallocate(mach_port_t task, mach_port_t name)
{
    (void)task;
    if (name < MAX_FAKE_PORTS && fake_ports[name].send_refs > 0)
        fake_ports[name].send_refs--;
    return KERN_SUCCESS;
}
static kern_return_t host_set_special_port(mach_port_t host, int which, mach_port_t name)
{
    (void)host; (void)which;
    if (fail_host_set) return KERN_FAILURE;
    if (name == MACH_PORT_NULL || name >= MAX_FAKE_PORTS ||
        !fake_ports[name].allocated || !fake_ports[name].send || fake_ports[name].dead)
        return KERN_INVALID_RIGHT;
    host_special_port = name;
    return KERN_SUCCESS;
}
static kern_return_t host_get_special_port(mach_port_t host, int node, int which,
                                            mach_port_t *name)
{
    (void)host; (void)node; (void)which;
    *name = host_special_port;
    if (host_special_port == MACH_PORT_NULL) return KERN_FAILURE;
    if (host_special_port < MAX_FAKE_PORTS) fake_ports[host_special_port].send_refs++;
    return KERN_SUCCESS;
}
static const char *mach_error_string(kern_return_t error)
{
    (void)error;
    return "mock";
}
static int spawnJailbreakd(void)
{
    spawn_calls++;
    return spawn_result;
}
static mach_port_t jbclient_jailbreakd_lookup(void)
{
    lookup_calls++;
    return lookup_result;
}

'''

main = r'''static void reset_case(void)
{
    memset(fake_ports, 0, sizeof(fake_ports));
    next_port = 100;
    host_special_port = MACH_PORT_NULL;
    fail_allocate = false;
    fail_insert_right = false;
    fail_host_set = false;
    launchd_pid = 1;
    spawn_result = 0;
    spawn_calls = 0;
    lookup_calls = 0;
    lookup_result = 700;
    __firstLoad = false;
    __jailbreakd_initialized = false;
    __jailbreakd_port_ready = false;
    __jailbreakd_port_generation = 0;
    gJailbreakdPort = MACH_PORT_NULL;
}

static void test_unready_port_is_not_returned_and_becomes_ready_after_checkin(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    assert(candidate != MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(host_special_port == MACH_PORT_NULL);
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 1);

    assert(jailbreakdServerPortCheckinComplete() == 0);
    assert(__jailbreakd_port_ready);
    assert(host_special_port == candidate);
    jailbreakdServerPortCheckinTimedOut(__jailbreakd_port_generation);
    assert(gJailbreakdPort == candidate); /* an expired timer cannot revoke a checked-in port */
    assert(jailbreakdClientPort() == candidate);

    launchd_pid = 4242;
    assert(jailbreakdClientPort() == candidate);
    assert(lookup_calls == 0);
}

static void test_initial_spawn_failure_rolls_back_and_retries(void)
{
    reset_case();
    spawn_result = 71;
    assert(initJailbreakd(true) == 71);
    assert(__jailbreakd_initialized);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(host_special_port == MACH_PORT_NULL);
    assert(fake_ports[100].destroy_count == 1);

    spawn_result = 0;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    mach_port_t candidate = gJailbreakdPort;
    assert(candidate != MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(spawn_calls == 2);
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 2); /* do not spawn a second daemon while check-in is pending */

    assert(jailbreakdServerPortCheckinComplete() == 0);
    assert(jailbreakdClientPort() == candidate);
}

static void test_checkin_failure_discards_only_the_unready_candidate(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    jailbreakdServerPortCheckinFailed();
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[candidate].destroy_count == 1);
    assert(host_special_port == MACH_PORT_NULL);
}

static void test_startup_timeout_discards_failed_candidate_and_allows_retry(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    uint64_t generation = __jailbreakd_port_generation;

    jailbreakdServerPortCheckinTimedOut(generation);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[candidate].destroy_count == 1);
    assert(host_special_port == MACH_PORT_NULL);

    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(gJailbreakdPort != MACH_PORT_NULL);
    assert(gJailbreakdPort != candidate);
    assert(spawn_calls == 2);
}

static void test_stale_timeout_cannot_discard_a_new_generation(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    uint64_t stale_generation = __jailbreakd_port_generation;
    jailbreakdServerPortCheckinFailed();
    assert(registerServerPort() == 0);
    mach_port_t current_candidate = gJailbreakdPort;
    assert(__jailbreakd_port_generation != stale_generation);

    jailbreakdServerPortCheckinTimedOut(stale_generation);
    assert(gJailbreakdPort == current_candidate);
    assert(fake_ports[current_candidate].destroy_count == 0);
    assert(!__jailbreakd_port_ready);
}

static void test_failed_restart_rolls_back_and_retry_waits_for_checkin(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    assert(jailbreakdServerPortCheckinComplete() == 0);
    mach_port_t old_port = gJailbreakdPort;
    fake_ports[old_port].send = false;
    fake_ports[old_port].receive = false;
    fake_ports[old_port].dead = true;

    spawn_result = 72;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[old_port + 1].destroy_count == 1);
    assert(host_special_port == old_port); /* no unverified special-port clearing */

    spawn_result = 0;
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    mach_port_t new_port = gJailbreakdPort;
    assert(new_port == old_port + 2);
    assert(!__jailbreakd_port_ready);
    assert(host_special_port == old_port);
    assert(jailbreakdClientPort() == MACH_PORT_NULL);
    assert(spawn_calls == 3);

    assert(jailbreakdServerPortCheckinComplete() == 0);
    assert(host_special_port == new_port);
    assert(jailbreakdClientPort() == new_port);
}

static void test_dead_fast_special_port_falls_back_to_launchd_lookup(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    assert(jailbreakdServerPortCheckinComplete() == 0);
    mach_port_t old_port = gJailbreakdPort;
    fake_ports[old_port].send = false;
    fake_ports[old_port].receive = false;
    fake_ports[old_port].dead = true;
    launchd_pid = 4242;
    lookup_result = 777;

    assert(jailbreakdClientPortFastGet() == MACH_PORT_NULL);
    assert(jailbreakdClientPort() == lookup_result);
    assert(lookup_calls == 1);
}

static void test_special_port_publish_failure_keeps_xpc_lookup_available(void)
{
    reset_case();
    assert(initJailbreakd(true) == 0);
    mach_port_t candidate = gJailbreakdPort;
    fail_host_set = true;
    assert(jailbreakdServerPortCheckinComplete() == 0);
    assert(__jailbreakd_port_ready);
    assert(host_special_port == MACH_PORT_NULL);
    assert(jailbreakdClientPort() == candidate);

    launchd_pid = 4242;
    lookup_result = 778;
    assert(jailbreakdClientPort() == lookup_result);
    assert(lookup_calls == 1);
}

static void test_insert_right_failure_does_not_leave_a_candidate(void)
{
    reset_case();
    fail_insert_right = true;
    assert(initJailbreakd(true) == -1);
    assert(gJailbreakdPort == MACH_PORT_NULL);
    assert(!__jailbreakd_initialized);
    assert(!__jailbreakd_port_ready);
    assert(fake_ports[100].destroy_count == 1);
    assert(spawn_calls == 0);
}

int main(void)
{
    test_unready_port_is_not_returned_and_becomes_ready_after_checkin();
    test_initial_spawn_failure_rolls_back_and_retries();
    test_checkin_failure_discards_only_the_unready_candidate();
    test_startup_timeout_discards_failed_candidate_and_allows_retry();
    test_stale_timeout_cannot_discard_a_new_generation();
    test_failed_restart_rolls_back_and_retry_waits_for_checkin();
    test_dead_fast_special_port_falls_back_to_launchd_lookup();
    test_special_port_publish_failure_keeps_xpc_lookup_available();
    test_insert_right_failure_does_not_leave_a_candidate();
    return 0;
}
'''

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    c_file = directory / "jailbreakd_lifecycle.c"
    executable = directory / "jailbreakd_lifecycle"
    c_file.write_text(harness + globals_block + "\n" + functions + "\n" + main)
    subprocess.run(
        ["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
         "-fsanitize=address,undefined", str(c_file), "-o", str(executable)],
        check=True,
    )
    subprocess.run([str(executable)], check=True)

print("PASS: jailbreakd ready-gate, startup timeout, rollback, restart, and dead-port fallback")
