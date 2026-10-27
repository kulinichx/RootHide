#include <xpc/xpc.h>
#include <stdbool.h>

#include "RCInjectPolicyCache.h"

static RCInjectPolicyCache injectPolicyCache = RC_INJECT_POLICY_CACHE_INIT;

bool zqbb_wantsInject(const char *execName, const char *injectPath)
{
    if (!execName || !injectPath) {
        return false;
    }

    // Match ZQBB: membership controls the RootHide environment, not tweaks.
    // Safe mode and the global tweak toggle are enforced by TweakLoader's gate.
    xpc_object_t xplist =
        rc_inject_policy_cache_copy_dictionary(&injectPolicyCache, injectPath);
    if (!xplist) {
        return false;
    }

    bool result = xpc_dictionary_get_bool(xplist, execName);
    xpc_release(xplist);

    return result;
}
