#!/usr/bin/env python3
"""Host-only fault injection for the *real source* ready-ACK client routine.

Runs outside Apple SDK. The XPC response transport and server delivery are mocks.
A committed server reply is not proof of a live Mach receive right.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
client = (ROOT / 'BaseBin/libjailbreak/src/jbclient_roothide.c').read_text()
server = (ROOT / 'BaseBin/libjailbreak/src/roothider/jailbreakd.c').read_text()
handler = (ROOT / 'BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c').read_text()
daemon = (ROOT / 'BaseBin/jailbreakd/src/main.m').read_text()


def extract_function(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError(f'unterminated source function: {signature}')


real_client = extract_function(client, 'static int jbclient_jailbreakd_report_readiness(bool ready)')
real_server_ready = extract_function(server, 'int jailbreakdServerPortCheckinReady(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)')
real_server_abort = extract_function(server, 'int jailbreakdServerPortCheckinAbort(pid_t pid, const char *token, jailbreakd_checkin_ticket_t *ticket)')
real_server_complete = extract_function(server, 'int jailbreakdServerPortCheckinComplete(const jailbreakd_checkin_ticket_t *ticket)')
real_handler = extract_function(handler, 'static int roothide_jailbreakd_ready(')

# Tie fault injection to the current production protocol rather than a copied toy routine.
assert 'for (unsigned int attempt = 0; attempt < 3; attempt++)' in real_client
assert 'xpc_get_type(xreply) == XPC_TYPE_DICTIONARY' in real_client
assert 'JBS_ROOTHIDE_JAILBREAKD_READY' in real_client
assert 'xpc_dictionary_get_value(xreply, "result")' in real_client
assert 'unsetenv("JAILBREAKD_CHECKIN_TOKEN")' in real_client
assert '__jailbreakd_port_ready' in real_server_ready and '__jailbreakd_ready_pid' in real_server_ready
assert '__jailbreakd_port_ready || !__jailbreakd_checkin_in_progress' in real_server_abort
assert 'if (alreadyComplete) return 0;' in real_server_complete
assert 'jailbreakdServerPortCheckinAbort(pid, checkinToken, &ticket)' in real_handler
assert 'jailbreakdServerPortCheckinComplete(&ticket)' in real_handler
assert 'dispatch_source_cancel(source);' in daemon
assert 'if (jbclient_jailbreakd_ready() != 0)' in daemon
assert 'if (jbclient_jailbreakd_checkin_failed() != 0)' in daemon

harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct MockXpc {
    int type;
    int64_t result;
    bool ready;
    const char *token;
    struct MockXpc *value;
} *xpc_object_t;

enum {
    XPC_TYPE_DICTIONARY=100, XPC_TYPE_INT64=101, XPC_TYPE_STRING=102,
    JBS_DOMAIN_ROOTHIDE=7, JBS_ROOTHIDE_JAILBREAKD_READY=10,
    MODE_NORMAL=0, MODE_DROP_FIRST=1, MODE_DROP_TWO=2, MODE_DROP_ALL=3,
    MODE_MALFORMED_FIRST=4, MODE_MALFORMED_ALL=5, MODE_REJECTED=6,
    MODE_NONDICT_FIRST=7, MODE_NO_RESULT_FIRST=8
};

static int mode;
static int client_token_present;
static int request_count;
static int ready_deliveries;
static int abort_deliveries;
static int mock_server_ready;
static int reject_server_result;
static const char token_value[] = "0123456789abcdef0123456789abcdef";

static char *fake_getenv(const char *name)
{
    assert(strcmp(name,"JAILBREAKD_CHECKIN_TOKEN") == 0);
    return client_token_present ? (char *)token_value : NULL;
}
static int fake_unsetenv(const char *name)
{
    assert(strcmp(name,"JAILBREAKD_CHECKIN_TOKEN") == 0);
    client_token_present = 0;
    return 0;
}
#define getenv fake_getenv
#define unsetenv fake_unsetenv

static xpc_object_t xpc_dictionary_create_empty(void)
{
    xpc_object_t o = calloc(1, sizeof(struct MockXpc));
    if (o) o->type = XPC_TYPE_DICTIONARY;
    return o;
}
static void xpc_dictionary_set_string(xpc_object_t o, const char *name, const char *value)
{
    assert(o && strcmp(name,"checkin-token") == 0);
    o->token = value;
}
static void xpc_dictionary_set_bool(xpc_object_t o, const char *name, bool value)
{
    assert(o && strcmp(name,"ready") == 0);
    o->ready = value;
}
static xpc_object_t xpc_dictionary_get_value(xpc_object_t o, const char *name)
{
    assert(o && o->type == XPC_TYPE_DICTIONARY && strcmp(name,"result") == 0);
    return o->value;
}
static int xpc_get_type(xpc_object_t o) { assert(o); return o->type; }
static int64_t xpc_dictionary_get_int64(xpc_object_t o, const char *name)
{
    assert(o && o->value && o->value->type == XPC_TYPE_INT64 && strcmp(name,"result") == 0);
    return o->value->result;
}
static void xpc_release(xpc_object_t o)
{
    if (o) { free(o->value); free(o); }
}

/* The simulated server commits first, then may drop an ACK. It models
 * idempotence of repeat READY with the same identity, but NOT Mach, dispatch,
 * PID reuse, or a real transport. */
static xpc_object_t jbserver_xpc_send(uint64_t domain, uint64_t action, xpc_object_t args)
{
    assert(domain == JBS_DOMAIN_ROOTHIDE && action == JBS_ROOTHIDE_JAILBREAKD_READY);
    assert(args && args->token && strcmp(args->token,token_value) == 0);
    ++request_count;
    if (args->ready) {
        ++ready_deliveries;
        if (!reject_server_result) mock_server_ready = 1;
    } else {
        ++abort_deliveries;
    }
    int server_result = reject_server_result ? -1 : (!args->ready && mock_server_ready ? -1 : 0);
    if (mode == MODE_DROP_ALL ||
        (mode == MODE_DROP_FIRST && request_count == 1) ||
        (mode == MODE_DROP_TWO && request_count <= 2)) return NULL;

    xpc_object_t reply = xpc_dictionary_create_empty();
    assert(reply);
    if (mode == MODE_NONDICT_FIRST && request_count == 1)
        reply->type = XPC_TYPE_STRING;
    if (!(mode == MODE_NO_RESULT_FIRST && request_count == 1)) {
        reply->value = calloc(1, sizeof(struct MockXpc));
        assert(reply->value);
        reply->value->type = ((mode == MODE_MALFORMED_ALL) ||
                              (mode == MODE_MALFORMED_FIRST && request_count == 1))
                             ? XPC_TYPE_STRING : XPC_TYPE_INT64;
        reply->value->result = server_result;
    }
    return reply;
}
/* INSERT_CLIENT_FUNCTION */

static void reset_case(int requested_mode)
{
    mode = requested_mode;
    client_token_present = 1;
    request_count = 0;
    ready_deliveries = 0;
    abort_deliveries = 0;
    mock_server_ready = 0;
    reject_server_result = 0;
}
static void test_normal_reply(void)
{
    reset_case(MODE_NORMAL);
    assert(jbclient_jailbreakd_report_readiness(true) == 0);
    assert(mock_server_ready && request_count == 1 && client_token_present == 0);
    puts("NORMAL_ACK=PASS requests=1");
}
static void test_one_lost_reply(void)
{
    reset_case(MODE_DROP_FIRST);
    assert(jbclient_jailbreakd_report_readiness(true) == 0);
    assert(mock_server_ready && request_count == 2 && client_token_present == 0);
    puts("FIRST_REPLY_LOST=PASS requests=2");
}
static void test_two_lost_replies(void)
{
    reset_case(MODE_DROP_TWO);
    assert(jbclient_jailbreakd_report_readiness(true) == 0);
    assert(mock_server_ready && request_count == 3 && client_token_present == 0);
    puts("BOTH_REPLIES_LOST_THIRD_SUCCEEDS=PASS requests=3");
}
static void test_all_replies_lost(void)
{
    reset_case(MODE_DROP_ALL);
    assert(jbclient_jailbreakd_report_readiness(true) != 0);
    assert(mock_server_ready && request_count == 3 && client_token_present == 1);
    mode=MODE_NORMAL;
    assert(jbclient_jailbreakd_report_readiness(false) != 0);
    assert(mock_server_ready && abort_deliveries == 1);
    puts("ALL_THREE_REPLIES_LOST=KNOWN_RISK requests=3 abort_rejected=1");
}
static void test_malformed_then_good(void)
{
    reset_case(MODE_MALFORMED_FIRST);
    assert(jbclient_jailbreakd_report_readiness(true) == 0);
    assert(mock_server_ready && request_count == 2 && client_token_present == 0);
    puts("MALFORMED_FIRST_REPLY_RECOVERS=PASS requests=2");
}
static void test_all_malformed(void)
{
    reset_case(MODE_MALFORMED_ALL);
    assert(jbclient_jailbreakd_report_readiness(true) != 0);
    assert(request_count == 3 && client_token_present == 1);
    puts("ALL_MALFORMED_REPLIES=KNOWN_RISK requests=3");
}
static void test_nondictionary_then_good(void)
{
    reset_case(MODE_NONDICT_FIRST);
    assert(jbclient_jailbreakd_report_readiness(true) == 0);
    assert(request_count == 2 && client_token_present == 0);
    puts("NON_DICTIONARY_FIRST_REPLY_RECOVERS=PASS requests=2");
}
static void test_missing_result_then_good(void)
{
    reset_case(MODE_NO_RESULT_FIRST);
    assert(jbclient_jailbreakd_report_readiness(true) == 0);
    assert(request_count == 2 && client_token_present == 0);
    puts("MISSING_RESULT_FIRST_REPLY_RECOVERS=PASS requests=2");
}
static void test_explicit_server_rejection(void)
{
    reset_case(MODE_REJECTED);
    reject_server_result = 1;
    assert(jbclient_jailbreakd_report_readiness(true) != 0);
    assert(!mock_server_ready && request_count == 1 && client_token_present == 1);
    puts("EXPLICIT_REJECTION=PASS requests=1");
}
static void test_missing_token_no_delivery(void)
{
    reset_case(MODE_NORMAL);
    client_token_present = 0;
    assert(jbclient_jailbreakd_report_readiness(true) != 0);
    assert(request_count == 0 && !mock_server_ready);
    puts("MISSING_TOKEN=PASS requests=0");
}
static void test_checkin_failed_ack(void)
{
    reset_case(MODE_NORMAL);
    assert(jbclient_jailbreakd_report_readiness(false) == 0);
    assert(request_count == 1 && abort_deliveries == 1 && client_token_present == 1);
    puts("CHECKIN_ABORT_NORMAL=PASS requests=1");
}
int main(void)
{
    test_normal_reply();
    test_one_lost_reply();
    test_two_lost_replies();
    test_all_replies_lost();
    test_malformed_then_good();
    test_all_malformed();
    test_nondictionary_then_good();
    test_missing_result_then_good();
    test_explicit_server_rejection();
    test_missing_token_no_delivery();
    test_checkin_failed_ack();
    return 0;
}
'''

with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    src = td / 'ready_ack.c'
    exe = td / 'ready_ack'
    src.write_text(harness.replace('/* INSERT_CLIENT_FUNCTION */', real_client))
    subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('P2_HOST_FAULT_INJECTION=PASS (source-extracted client; simulated XPC/server transport)')
