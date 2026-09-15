#include <xpc/xpc.h>
#include <stdbool.h>
#include <string.h>

#include "RCInjectPolicyCache.h"

static RCInjectPolicyCache whitelistPolicyCache = RC_INJECT_POLICY_CACHE_INIT;

bool zqbb_isWhiteListForSystem(const char *path, const char *injectSystemPath)
{
    if (!path || !injectSystemPath) {
        return false;
    }

    xpc_object_t xplist =
        rc_inject_policy_cache_copy_dictionary(&whitelistPolicyCache,
                                               injectSystemPath);
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
