#include "RCInjectPolicyCache.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern xpc_object_t xpc_create_from_plist(const void *buf, size_t len);

_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2,
               "Injection policy state requires lock-free pointers");

static bool cache_metadata_matches(const RCInjectPolicyCacheState *state,
                                   const struct stat *s)
{
    return state->metadataValid &&
           state->device == s->st_dev &&
           state->inode == s->st_ino &&
           state->mode == s->st_mode &&
           state->fileSize == s->st_size &&
           state->fileMtime.tv_sec == s->st_mtimespec.tv_sec &&
           state->fileMtime.tv_nsec == s->st_mtimespec.tv_nsec &&
           state->fileCtime.tv_sec == s->st_ctimespec.tv_sec &&
           state->fileCtime.tv_nsec == s->st_ctimespec.tv_nsec;
}

static void cache_set_metadata_locked(RCInjectPolicyCacheState *state,
                                      const struct stat *s)
{
    state->metadataValid = true;
    state->device = s->st_dev;
    state->inode = s->st_ino;
    state->mode = s->st_mode;
    state->fileSize = s->st_size;
    state->fileMtime = s->st_mtimespec;
    state->fileCtime = s->st_ctimespec;
}

static void cache_replace_locked(RCInjectPolicyCacheState *state,
                                 const struct stat *s,
                                 xpc_object_t dictionary)
{
    if (state->dictionary) {
        xpc_release(state->dictionary);
    }
    cache_set_metadata_locked(state, s);
    state->dictionary = dictionary;
}

static void cache_clear_locked(RCInjectPolicyCacheState *state)
{
    if (state->dictionary) {
        xpc_release(state->dictionary);
        state->dictionary = NULL;
    }

    state->metadataValid = false;
    state->device = 0;
    state->inode = 0;
    state->mode = 0;
    state->fileSize = 0;
    state->fileMtime = (struct timespec){ .tv_sec = 0, .tv_nsec = 0 };
    state->fileCtime = (struct timespec){ .tv_sec = 0, .tv_nsec = 0 };
}

// A child must not touch a cache lock that may have been held by a vanished
// parent thread. Publish fresh state and leave the inherited state untouched.
static RCInjectPolicyCacheState *cache_current_state(RCInjectPolicyCache *cache)
{
    pid_t owner = getpid();
    RCInjectPolicyCacheState *state =
        atomic_load_explicit(&cache->state, memory_order_acquire);
    if (state && state->owner == owner) return state;

    RCInjectPolicyCacheState *fresh = calloc(1, sizeof(*fresh));
    if (!fresh) return NULL;
    fresh->owner = owner;
    fresh->lock = OS_UNFAIR_LOCK_INIT;

    if (atomic_compare_exchange_strong_explicit(&cache->state, &state, fresh,
                                                memory_order_acq_rel,
                                                memory_order_acquire)) {
        // The replaced state may contain an inherited locked mutex and XPC
        // references. It is intentionally left alone in the child process.
        return fresh;
    }

    free(fresh);
    return state && state->owner == owner ? state : NULL;
}

static xpc_object_t cache_load_dictionary(const char *path,
                                          struct stat *observed,
                                          bool *stable)
{
    *stable = false;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return NULL;

    struct stat before = {};
    if (fstat(fd, &before) != 0) {
        close(fd);
        return NULL;
    }
    if (!S_ISREG(before.st_mode) || before.st_size <= 0 ||
        (uintmax_t)before.st_size > SIZE_MAX) {
        *observed = before;
        *stable = true;
        close(fd);
        return NULL;
    }

    size_t length = (size_t)before.st_size;
    void *data = malloc(length);
    if (!data) {
        close(fd);
        return NULL;
    }

    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, (char *)data + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (size_t)count;
    }

    struct stat after = {};
    bool complete = offset == length && fstat(fd, &after) == 0 &&
                    cache_metadata_matches(&(RCInjectPolicyCacheState){
                        .metadataValid = true,
                        .device = before.st_dev,
                        .inode = before.st_ino,
                        .mode = before.st_mode,
                        .fileSize = before.st_size,
                        .fileMtime = before.st_mtimespec,
                        .fileCtime = before.st_ctimespec,
                    }, &after);
    close(fd);

    xpc_object_t parsed = NULL;
    if (complete) {
        *observed = after;
        *stable = true;
        parsed = xpc_create_from_plist(data, length);
        if (parsed && xpc_get_type(parsed) != XPC_TYPE_DICTIONARY) {
            xpc_release(parsed);
            parsed = NULL;
        }
    }

    free(data);
    return parsed;
}

xpc_object_t rc_inject_policy_cache_copy_dictionary(RCInjectPolicyCache *cache,
                                                    const char *path)
{
    if (!cache || !path) {
        return NULL;
    }

    RCInjectPolicyCacheState *state = cache_current_state(cache);
    if (!state) {
        struct stat observed;
        bool stable;
        return cache_load_dictionary(path, &observed, &stable);
    }

    xpc_object_t snapshot = NULL;

    os_unfair_lock_lock(&state->lock);

    struct stat pathStat = {};
    if (stat(path, &pathStat) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) {
            cache_clear_locked(state);
        }
        snapshot = state->dictionary ? xpc_retain(state->dictionary) : NULL;
        os_unfair_lock_unlock(&state->lock);
        return snapshot;
    }
    if (!S_ISREG(pathStat.st_mode)) {
        cache_clear_locked(state);
        os_unfair_lock_unlock(&state->lock);
        return NULL;
    }

    if (cache_metadata_matches(state, &pathStat)) {
        if (state->dictionary) {
            snapshot = xpc_retain(state->dictionary);
        }
        os_unfair_lock_unlock(&state->lock);
        return snapshot;
    }

    struct stat observed = {};
    bool stable;
    xpc_object_t parsed = cache_load_dictionary(path, &observed, &stable);
    if (stable) {
        if (parsed) {
            cache_replace_locked(state, &observed, parsed);
        }
        else {
            cache_set_metadata_locked(state, &observed);
        }
    }
    else if (parsed) {
        xpc_release(parsed);
    }

    if (state->dictionary) {
        snapshot = xpc_retain(state->dictionary);
    }

    os_unfair_lock_unlock(&state->lock);
    return snapshot;
}

void rc_inject_policy_cache_invalidate(RCInjectPolicyCache *cache)
{
    if (!cache) {
        return;
    }

    RCInjectPolicyCacheState *state = cache_current_state(cache);
    if (!state) return;

    os_unfair_lock_lock(&state->lock);
    cache_clear_locked(state);
    os_unfair_lock_unlock(&state->lock);
}
