#include "_zqbb.h"
#include "RCInjectPolicyCache.h"

static RCInjectPolicyCache injectPolicyCache = RC_INJECT_POLICY_CACHE_INIT;
static RCInjectPolicyCache systemInjectPolicyCache = RC_INJECT_POLICY_CACHE_INIT;

bool zqbb_wantInject(const char *execName, const char *injectPath)
{
    if (!execName || !injectPath) {
        return false;
    }

    xpc_object_t xplist =
        rc_inject_policy_cache_copy_dictionary(&injectPolicyCache, injectPath);
    if (!xplist) {
        return false;
    }

    bool result = xpc_dictionary_get_bool(xplist, execName);
    xpc_release(xplist);

    return result;
}

bool zqbb_isWhiteList(const char *path)
{
    if (!path) {
        return false;
    }

    const char *systemInjectPath =
        JBROOT_PATH("/var/mobile/Library/RootHide/cn.zqbb.inject.system.plist");

    xpc_object_t xplist =
        rc_inject_policy_cache_copy_dictionary(&systemInjectPolicyCache,
                                               systemInjectPath);
    if (!xplist) {
        return false;
    }

    __block bool found = false;

    xpc_dictionary_apply(xplist, ^bool(const char *key, xpc_object_t value) {
        if (xpc_get_type(value) == XPC_TYPE_BOOL &&
            xpc_bool_get_value(value) &&
            strstr(path, key)) {
            found = true;
            return false;
        }

        return true;
    });

    xpc_release(xplist);
    return found;
}
