#include <xpc/xpc.h>
#include <stdbool.h>
#include <unistd.h>

#include "RCInjectPolicyCache.h"
#include "../libjailbreak.h"

static RCInjectPolicyCache injectPolicyCache = RC_INJECT_POLICY_CACHE_INIT;
static RCInjectPolicyCache gatePolicyCache = RC_INJECT_POLICY_CACHE_INIT;

static bool roothide_isTweakInjectionEnabled(void)
{
    // Unified gate: 1) Dopamine safe_mode (.safe_mode file) 2) Relaxin plist key.
    // Either disabled => no tweak injection. Default YES if both absent.
    if (access(JBROOT_PATH("/basebin/.safe_mode"), F_OK) == 0) return false;
    // Gate lives in RootHideConfig.plist under key "tweakInjectionEnabled".
    // Missing or invalid entry = enabled (default YES), matching Relaxin 0.5.4 behavior.
    static const char *gatePath = NULL;
    if (!gatePath)
        gatePath = JBROOT_PATH("/var/mobile/Library/RootHide/RootHideConfig.plist");
    xpc_object_t dict = rc_inject_policy_cache_copy_dictionary(&gatePolicyCache, gatePath);
    if (!dict)
        return true;
    xpc_object_t val = xpc_dictionary_get_value(dict, "tweakInjectionEnabled");
    if (!val) {
        xpc_release(dict);
        return true;
    }
    bool isBool = (xpc_get_type(val) == XPC_TYPE_BOOL);
    bool enabled = isBool ? xpc_bool_get_value(val) : true;
    xpc_release(dict);
    return enabled;
}

bool zqbb_wantsInject(const char *execName, const char *injectPath)
{
    if (!execName || !injectPath) {
        return false;
    }

    if (!roothide_isTweakInjectionEnabled())
        return false;

    xpc_object_t xplist =
        rc_inject_policy_cache_copy_dictionary(&injectPolicyCache, injectPath);
    if (!xplist) {
        return false;
    }

    bool result = xpc_dictionary_get_bool(xplist, execName);
    xpc_release(xplist);

    return result;
}
