#include "_zqbb.h"
#include "RCInjectPolicyCache.h"
#include <limits.h>
#include <unistd.h>

static RCInjectPolicyCache injectPolicyCache = RC_INJECT_POLICY_CACHE_INIT;
static RCInjectPolicyCache systemInjectPolicyCache = RC_INJECT_POLICY_CACHE_INIT;

bool roothide_isTweakInjectionEnabled(void)
{
    if (access(JBROOT_PATH("/basebin/.safe_mode"), F_OK) == 0) return false;

    // Keep RC9's manager toggle at the TweakLoader boundary. Disabling tweaks
    // must not turn a whitelisted app into a RootHide-blacklisted process.
    static RCInjectPolicyCache gatePolicyCache = RC_INJECT_POLICY_CACHE_INIT;
    // JBROOT_PATH uses an alloca buffer: it must not outlive this call.
    const char *gatePath =
        JBROOT_PATH("/var/mobile/Library/RootHide/RootHideConfig.plist");
    xpc_object_t dict = rc_inject_policy_cache_copy_dictionary(&gatePolicyCache, gatePath);
    if (!dict) return true;

    xpc_object_t value = xpc_dictionary_get_value(dict, "tweakInjectionEnabled");
    bool enabled = !value || xpc_get_type(value) != XPC_TYPE_BOOL ||
        xpc_bool_get_value(value);
    xpc_release(dict);
    return enabled;
}

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
        if (*key && xpc_get_type(value) == XPC_TYPE_BOOL &&
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

// Match ZQBB's per-path Jetsam addend plist and its 10 MB fallback.
// Keep RC9's lock-protected metadata cache and owned-XPC-reference discipline.
int zqbb_getJetsamAddend(const char *path)
{
    if (!path) return 10;

    static RCInjectPolicyCache jetsamAddendPolicyCache = RC_INJECT_POLICY_CACHE_INIT;
    const char *configPath =
        JBROOT_PATH("/var/mobile/Library/RootHide/cn.zqbb.jetsam.addend.plist");
    xpc_object_t plist =
        rc_inject_policy_cache_copy_dictionary(&jetsamAddendPolicyCache, configPath);
    if (!plist) return 10;

    __block int result = 10;
    xpc_dictionary_apply(plist, ^bool(const char *key, xpc_object_t value) {
        if (*key && xpc_get_type(value) == XPC_TYPE_INT64) {
            int64_t amount = xpc_int64_get_value(value);
            if (amount > 0 && amount <= INT_MAX && strstr(path, key)) {
                result = (int)amount;
                return false;
            }
        }
        return true;
    });

    xpc_release(plist);
    return result;
}
