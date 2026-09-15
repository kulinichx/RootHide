#ifndef RC_INJECT_POLICY_CACHE_H
#define RC_INJECT_POLICY_CACHE_H

#include <stdbool.h>
#include <sys/stat.h>
#include <xpc/xpc.h>
#include <os/lock.h>

typedef struct {
    os_unfair_lock lock;
    bool metadataValid;
    dev_t device;
    ino_t inode;
    off_t fileSize;
    struct timespec fileMtime;
    xpc_object_t dictionary;
} RCInjectPolicyCache;

#define RC_INJECT_POLICY_CACHE_INIT { \
    .lock = OS_UNFAIR_LOCK_INIT, \
    .metadataValid = false, \
    .device = 0, \
    .inode = 0, \
    .fileSize = 0, \
    .fileMtime = { .tv_sec = 0, .tv_nsec = 0 }, \
    .dictionary = NULL \
}

// Returns a retained XPC dictionary snapshot. The caller must xpc_release()
// the returned object. NULL means the current file is missing, empty, invalid,
// or is not an XPC dictionary.
xpc_object_t rc_inject_policy_cache_copy_dictionary(RCInjectPolicyCache *cache,
                                                    const char *path);

// Explicit invalidation hook for future callers. Normal operation does not
// require it because metadata changes are detected on the next lookup.
void rc_inject_policy_cache_invalidate(RCInjectPolicyCache *cache);

#endif
