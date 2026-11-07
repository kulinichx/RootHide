"""JBServer descriptor/ABI-slot regressions using the real C dispatcher.

--native mocks XPC and handlers, without kernel or device validation.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_rc9_services import extract, source


FILE = "BaseBin/libjailbreak/src/jbserver.c"
HEADER = "BaseBin/libjailbreak/src/jbserver.h"


class IPCDispatchContracts(unittest.TestCase):
    def test_descriptor_indices_and_handler_slots_are_separate(self):
        body = extract(source(FILE), "int jbserver_received_xpc_message(")
        self.assertIn("slots[argCount] = slotCount;", body)
        self.assertIn("action->args[descIdx]", body)
        self.assertIn("size_t i = slots[descIdx];", body)
        self.assertIn("args[i+1] = &argsOut[i+1];", body)
        self.assertIn("width > JBSERVER_MAX_ARGS - slotCount", body)
        self.assertNotIn("action->args[i+1].name", body)

    def test_reply_exists_before_handlers_or_fd_duplication(self):
        body = extract(source(FILE), "int jbserver_received_xpc_message(")
        self.assertIn("if (!xreply) return -1;", body)
        reply = body.index("xpc_dictionary_create_reply(xmsg)")
        guard = body.index("if (!xreply) return -1;")
        self.assertLess(reply, guard)
        self.assertLess(guard, body.index("xpc_dictionary_dup_fd("))
        self.assertLess(guard, body.index("int result = handler("))

    def test_output_fd_defaults_to_invalid_and_wire_layout_is_preserved(self):
        body = extract(source(FILE), "int jbserver_received_xpc_message(")
        self.assertIn("argsOut[i] = (void *)(intptr_t)-1", body)
        self.assertIn("if (fd >= 0)", body)
        header = source(HEADER)
        self.assertIn("jbserver_arg *args;", header)
        self.assertIn("struct jbserver_action actions[];", header)
        self.assertIn("for (uint64_t i = 1;", body)

    def test_native_regression_is_required_by_existing_ci(self):
        self.assertIn("python3 tests/test_rc9_ipc_dispatch.py --native",
                      source(".github/workflows/roothide.yml"))

    def test_existing_domain_tables_fit_eight_slots_without_layout_changes(self):
        root = Path(__file__).resolve().parents[1]
        files = sorted((root / "BaseBin/launchdhook/src/jbserver").glob("jbdomain_*.c"))
        files.append(root / "BaseBin/libjailbreak/src/jbserver_boomerang.c")
        action_count = 0
        for path in files:
            text = path.read_text(encoding="utf-8")
            tables = re.findall(r"\.args\s*=\s*\(jbserver_arg\[\]\)\s*\{(.*?)\n\s*\}", text, re.S)
            self.assertEqual(len(tables), len(re.findall(r"\.args\s*=", text)), path.name)
            for table in tables:
                types = re.findall(r"\.type\s*=\s*(JBS_TYPE_\w+)", table)
                slots = sum(2 if kind == "JBS_TYPE_DATA" else 1 for kind in types)
                self.assertLessEqual(slots, 8, (path.name, table))
                action_count += 1
        self.assertGreater(action_count, 20)

    def test_short_descriptor_arrays_have_an_explicit_terminator(self):
        root = Path(__file__).resolve().parents[1]
        files = sorted((root / "BaseBin/launchdhook/src/jbserver").glob("jbdomain_*.c"))
        files.append(root / "BaseBin/libjailbreak/src/jbserver_boomerang.c")
        for path in files:
            text = path.read_text(encoding="utf-8")
            tables = re.findall(r"\.args\s*=\s*\(jbserver_arg\[\]\)\s*\{(.*?)\n\s*\}", text, re.S)
            for table in tables:
                types = re.findall(r"\.type\s*=\s*(JBS_TYPE_\w+)", table)
                if len(types) < 8:
                    self.assertRegex(table, r"\{\s*0\s*\}\s*,?\s*$",
                                     f"{path.name}: short compound array must terminate in bounds")

    def test_jetsam_failed_live_update_does_not_persist_false_success(self):
        settings = source("Application/Dopamine/UI/Settings/DOSettingsController.m")
        setter = extract(settings, "- (void)setJetsamMultiplier:")
        apply = setter.index('jbclient_platform_jbsettings_set_double_verified("jetsamMultiplier"')
        guard = setter.index("if (result != 0)")
        persist = setter.index("setPreferenceValue:value forKey:")
        self.assertLess(apply, guard)
        self.assertLess(guard, setter.index("return;"))
        self.assertLess(setter.index("return;"), persist)
        self.assertIn('DOLocalizedString(@"Jetsam_Apply_Failed_Body"), result', setter)
        presenter = extract(settings, "- (void)presentJetsamErrorWithTitle:")
        self.assertIn("self.navigationController.topViewController ?: self", presenter)
        self.assertIn("[presenter presentViewController:alert", presenter)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", presenter)
        self.assertIn("((NSNumber *)value).doubleValue / 2", setter)


NATIVE_PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef struct { uint32_t pid; } audit_token_t;
typedef struct TestXPC { int type; uint64_t domain, action; double number; bool flag; } *xpc_object_t;
enum { XPC_TYPE_DICTIONARY = 1, XPC_TYPE_DOUBLE = 2, XPC_TYPE_BOOL = 3 };
static struct TestXPC message = {.type=XPC_TYPE_DICTIONARY, .domain=1, .action=1};
static struct TestXPC reply = {.type=XPC_TYPE_DICTIONARY};
static struct TestXPC value = {.type=XPC_TYPE_DOUBLE};
static xpc_object_t serializedObject;
static const char *requestedKey = "text";
static struct {
    struct { double jetsamMultiplier; bool markAppsAsDebugged; } jailbreakSettings;
} gSystemInfo;
#define jbsetting(key) (gSystemInfo.jailbreakSettings.key)
static bool blocked, allowed = true, canReply = true;
static int handlerCalls, replies, releases, fdDuplicates, closeCalls, closedFd = -1;
static int outFd = -1;
static int64_t handlerResult;
static uint64_t outNumber;
static bool outBool;
static const char *data = "signature";
static size_t serializedLength;
static char serializedData[32];
static int xpc_get_type(xpc_object_t object) { assert(object); return object->type; }
static xpc_object_t xpc_double_create(double number) {
    value.type = XPC_TYPE_DOUBLE; value.number = number; return &value;
}
static double xpc_double_get_value(xpc_object_t object) {
    assert(object && object->type == XPC_TYPE_DOUBLE); return object->number;
}
static xpc_object_t xpc_bool_create(bool flag) {
    value.type = XPC_TYPE_BOOL; value.flag = flag; return &value;
}
static bool xpc_bool_get_value(xpc_object_t object) {
    assert(object && object->type == XPC_TYPE_BOOL); return object->flag;
}
static bool roothide_handle_xpc_msg(xpc_object_t object) { assert(object == &message); return blocked; }
static xpc_object_t xpc_dictionary_get_value(xpc_object_t object, const char *key) {
    assert(object == &message);
    (void)key; return &value;
}
static uint64_t xpc_dictionary_get_uint64(xpc_object_t object, const char *key) {
    assert(object == &message);
    if (!strcmp(key, "jb-domain")) return object->domain;
    if (!strcmp(key, "action")) return object->action;
    return 77;
}
static void xpc_dictionary_get_audit_token(xpc_object_t object, audit_token_t *token) {
    assert(object == &message); token->pid = 42;
}
static xpc_object_t xpc_dictionary_create_reply(xpc_object_t object) {
    assert(object == &message); return canReply ? &reply : NULL;
}
static bool xpc_dictionary_get_bool(xpc_object_t object, const char *key) {
    assert(object == &message && !strcmp(key, "attach")); return true;
}
static int xpc_dictionary_dup_fd(xpc_object_t object, const char *key) {
    assert(object == &message && !strcmp(key, "input")); ++fdDuplicates; return 65;
}
static const char *xpc_dictionary_get_string(xpc_object_t object, const char *key) {
    assert(object == &message); (void)key; return requestedKey;
}
static const void *xpc_dictionary_get_data(xpc_object_t object, const char *key, size_t *length) {
    assert(object == &message && !strcmp(key, "data")); *length = strlen(data); return data;
}
static xpc_object_t xpc_dictionary_get_array(xpc_object_t object, const char *key) {
    assert(object == &message); (void)key; return &value;
}
static xpc_object_t xpc_dictionary_get_dictionary(xpc_object_t object, const char *key) {
    return xpc_dictionary_get_array(object, key);
}
static void xpc_dictionary_set_bool(xpc_object_t object, const char *key, bool flag) {
    assert(object == &reply); (void)key; outBool = flag;
}
static void xpc_dictionary_set_uint64(xpc_object_t object, const char *key, uint64_t number) {
    assert(object == &reply); (void)key; outNumber = number;
}
static void xpc_dictionary_set_fd(xpc_object_t object, const char *key, int fd) {
    assert(object == &reply); (void)key; outFd = fd;
}
static void xpc_dictionary_set_string(xpc_object_t object, const char *key, const char *text) {
    assert(object == &reply && text); (void)key;
}
static void xpc_dictionary_set_data(xpc_object_t object, const char *key, const void *bytes, size_t length) {
    assert(object == &reply && length <= sizeof(serializedData)); (void)key;
    serializedLength = length; memcpy(serializedData, bytes, length);
}
static void xpc_dictionary_set_value(xpc_object_t object, const char *key, xpc_object_t other) {
    assert(object == &reply && other); (void)key; serializedObject = other;
}
static void xpc_dictionary_set_int64(xpc_object_t object, const char *key, int64_t result) {
    assert(object == &reply && !strcmp(key, "result")); handlerResult = result;
}
static void xpc_pipe_routine_reply(xpc_object_t object) { assert(object == &reply); ++replies; }
static void xpc_release(xpc_object_t object) { assert(object); ++releases; }
static int test_close(int fd) { ++closeCalls; closedFd = fd; return 0; }
#define close test_close
static bool permitted(audit_token_t token) { assert(token.pid == 42); return allowed; }
'''

NATIVE_HANDLERS = r'''
static int mode;
static int handler(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    ++handlerCalls; (void)a5; (void)a6; (void)a7;
    if (mode == 0) {
        assert(((audit_token_t *)a0)->pid == 42 && (uintptr_t)a1 == 77);
        assert(a2 == data && (uintptr_t)a3 == strlen(data) && (uintptr_t)a4 == 1);
    } else if (mode == 1) {
        void *bytes = malloc(3); assert(bytes); memcpy(bytes, "abc", 3);
        *(void **)a0 = bytes; *(size_t *)a1 = 3; *(bool *)a2 = true;
    } else if (mode == 2) {
        assert((intptr_t)*(void **)a0 == -1); /* Failure must not implicitly close stdin. */
    } else if (mode == 3) {
        *(void **)a0 = (void *)(intptr_t)9;
    } else if (mode == 4) {
        assert((intptr_t)a0 == 65);
    } else if (mode == 5) {
        assert((uintptr_t)a0 == 77 && (uintptr_t)a7 == 77);
    } else if (mode == 6) {
        assert((uintptr_t)a0 == 77 && a1 == data && (uintptr_t)a2 == strlen(data));
        *(void **)a3 = (void *)(uintptr_t)123;
    } else if (mode == 7) {
        return jbsettings_get(a0, a1);
    } else {
        assert(mode == 8);
        return jbsettings_set(a0, a1);
    }
    return -23;
}
static struct jbserver_domain domain = {
    .permissionHandler = permitted,
    .actions = {{.handler = handler, .args = NULL}, {0}},
};
static struct jbserver_domain *domains[] = {&domain, NULL};
static struct jbserver_impl server = {.maxDomain = 1, .domains = domains};
static void reset(jbserver_arg *args, int nextMode) {
    mode = nextMode; domain.actions[0].args = args;
    handlerCalls = replies = releases = fdDuplicates = closeCalls = 0;
    closedFd = outFd = -1; outBool = false; serializedLength = 0; outNumber = 0;
    blocked = false; allowed = canReply = true; message.domain = message.action = 1;
}
static void success(void) {
    assert(jbserver_received_xpc_message(&server, &message) == 0);
    assert(handlerCalls == 1 && replies == 1 && releases == 1 && handlerResult == -23);
}
int main(void) {
    jbserver_arg settingsGet[] = { __PRODUCTION_SETTINGS_GET_ARGS__ };
    jbserver_arg settingsSet[] = { __PRODUCTION_SETTINGS_SET_ARGS__ };
    requestedKey = "jetsamMultiplier";
    for (int option = 2; option <= 8; option++) {
        reset(settingsSet, 8);
        xpc_double_create((double)option / 2.0);
        assert(jbserver_received_xpc_message(&server, &message) == 0);
        assert(handlerCalls == 1 && replies == 1 && handlerResult == 0);
        assert(gSystemInfo.jailbreakSettings.jetsamMultiplier == (double)option / 2.0);
        reset(settingsGet, 7); serializedObject = NULL;
        assert(jbserver_received_xpc_message(&server, &message) == 0);
        assert(handlerCalls == 1 && replies == 1 && handlerResult == 0 && releases == 2);
        assert(serializedObject && xpc_get_type(serializedObject) == XPC_TYPE_DOUBLE);
        assert(xpc_double_get_value(serializedObject) * 2.0 == option);
    }
    requestedKey = "markAppsAsDebugged";
    for (int enabled = 0; enabled <= 1; enabled++) {
        reset(settingsSet, 8); xpc_bool_create(enabled);
        assert(jbserver_received_xpc_message(&server, &message) == 0 && handlerResult == 0);
        reset(settingsGet, 7); serializedObject = NULL;
        assert(jbserver_received_xpc_message(&server, &message) == 0 && handlerResult == 0);
        assert(serializedObject && xpc_bool_get_value(serializedObject) == (bool)enabled);
    }
    requestedKey = "text";
    jbserver_arg trustFile[] = {
        {"caller-token", JBS_TYPE_CALLER_TOKEN, false}, {"fd", JBS_TYPE_UINT64, false},
        {"data", JBS_TYPE_DATA, false}, {"attach", JBS_TYPE_BOOL, false}, {0}};
    reset(trustFile, 0); success();
    jbserver_arg output[] = {{"data", JBS_TYPE_DATA, true}, {"flag", JBS_TYPE_BOOL, true}, {0}};
    reset(output, 1); success();
    assert(outBool && serializedLength == 3 && !memcmp(serializedData, "abc", 3));
    jbserver_arg dataLast[] = {{"number", JBS_TYPE_UINT64, false}, {"data", JBS_TYPE_DATA, false},
        {"output", JBS_TYPE_UINT64, true}, {0}};
    reset(dataLast, 6); success(); assert(outNumber == 123);
    jbserver_arg fdOut[] = {{"output", JBS_TYPE_FD, true}, {0}};
    reset(fdOut, 2); success(); assert(closeCalls == 0 && outFd == -1);
    reset(fdOut, 3); success(); assert(closeCalls == 1 && closedFd == 9 && outFd == 9);
    jbserver_arg fdIn[] = {{"input", JBS_TYPE_FD, false}, {0}};
    reset(fdIn, 4); success(); assert(fdDuplicates == 1 && closeCalls == 1 && closedFd == 65);
    reset(fdIn, 4); canReply = false;
    assert(jbserver_received_xpc_message(&server, &message) == -1);
    assert(handlerCalls == 0 && replies == 0 && fdDuplicates == 0 && closeCalls == 0);
    jbserver_arg full[8];
    for (int i = 0; i < 8; i++) full[i] = (jbserver_arg){"number", JBS_TYPE_UINT64, false};
    reset(full, 5); success();
    full[7] = (jbserver_arg){"data", JBS_TYPE_DATA, false};
    reset(full, 5);
    assert(jbserver_received_xpc_message(&server, &message) == -1 && handlerCalls == 0 && replies == 0);
    jbserver_arg invalid[] = {{"bad", (jbserver_type)99, false}, {0}};
    reset(invalid, 0);
    assert(jbserver_received_xpc_message(&server, &message) == -1 && handlerCalls == 0);
    invalid[0] = (jbserver_arg){"bad", JBS_TYPE_CALLER_TOKEN, true};
    assert(jbserver_received_xpc_message(&server, &message) == -1 && handlerCalls == 0);
    reset(NULL, 0);
    assert(jbserver_received_xpc_message(&server, &message) == -1 && handlerCalls == 0);
    reset(trustFile, 0); blocked = true;
    assert(jbserver_received_xpc_message(&server, &message) == -2 && handlerCalls == 0);
    reset(trustFile, 0); allowed = false;
    assert(jbserver_received_xpc_message(&server, &message) == -2 && handlerCalls == 0);
    reset(trustFile, 0); message.domain = UINT64_MAX;
    assert(jbserver_received_xpc_message(&server, &message) == -1 && handlerCalls == 0);
    reset(trustFile, 0); message.action = UINT64_MAX;
    assert(jbserver_received_xpc_message(&server, &message) == -1 && handlerCalls == 0);
    assert(jbserver_received_xpc_message(&server, NULL) == -1);
    assert(jbserver_received_xpc_message(NULL, &message) == -1);
    puts("PASS: real JBServer DATA/FD dispatch, production settings tables and handlers, all seven jetsam round-trips, JIT round-trips, permissions, bounds and no-reply failures; XPC mocked, no UIKit/device execution");
    return 0;
}
'''


def native_tests():
    compiler = shutil.which("clang")
    if not compiler:
        raise SystemExit("--native requires clang; no native tests were run")
    header = source(HEADER)
    types = header[header.index("#define JBSERVER_MAX_ARGS"):header.index("extern struct jbserver_impl")]
    dispatcher = extract(source(FILE), "int jbserver_received_xpc_message(")
    settings_handlers = "\n".join(extract(
        source("BaseBin/launchdhook/src/jbserver/jbsettings.c"), anchor
    ) for anchor in ("int jbsettings_get(", "int jbsettings_set("))
    native_handlers = NATIVE_HANDLERS
    for domain, handler, placeholder in (
        ("systemwide", "jbsettings_get", "__PRODUCTION_SETTINGS_GET_ARGS__"),
        ("platform", "jbsettings_set", "__PRODUCTION_SETTINGS_SET_ARGS__"),
    ):
        text = source(f"BaseBin/launchdhook/src/jbserver/jbdomain_{domain}.c")
        match = re.search(
            rf"\.handler\s*=\s*{handler},\s*\.args\s*=\s*\(jbserver_arg\[\]\)\s*\{{(.*?)\n\s*\}}",
            text, re.S)
        if not match:
            raise SystemExit(f"Missing production settings descriptor: {domain}/{handler}")
        native_handlers = native_handlers.replace(placeholder, match.group(1))
    with tempfile.TemporaryDirectory(prefix="rc9-ipc-dispatch-") as tmp:
        path = Path(tmp) / "dispatcher.c"
        binary = Path(tmp) / "dispatcher-test"
        path.write_text("\n".join((NATIVE_PREFIX, types, dispatcher, settings_handlers,
                                   native_handlers)), encoding="utf-8")
        subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-O1", "-g", "-fsanitize=address,undefined",
                        str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    options = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(IPCDispatchContracts))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if options.native:
        native_tests()
    else:
        print("Source contracts only; run --native on a clang host.")
