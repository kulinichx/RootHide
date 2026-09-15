#include "RCInjectPolicyCache.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

extern xpc_object_t xpc_create_from_plist(const void *buf, size_t len);

static bool cache_metadata_matches(const RCInjectPolicyCache *cache, const struct stat *s)
{
    return cache->metadataValid &&
           cache->device == s->st_dev &&
           cache->inode == s->st_ino &&
           cache->fileSize == s->st_size &&
           cache->fileMtime.tv_sec == s->st_mtimespec.tv_sec &&
           cache->fileMtime.tv_nsec == s->st_mtimespec.tv_nsec;
}

static void cache_replace_locked(RCInjectPolicyCache *cache,
                                 const struct stat *s,
                                 xpc_object_t dictionary)
{
    if (cache->dictionary) {
        xpc_release(cache->dictionary);
    }

    cache->metadataValid = true;
    cache->device = s->st_dev;
    cache->inode = s->st_ino;
    cache->fileSize = s->st_size;
    cache->fileMtime = s->st_mtimespec;
    cache->dictionary = dictionary;
}

static void cache_clear_locked(RCInjectPolicyCache *cache)
{
    if (cache->dictionary) {
        xpc_release(cache->dictionary);
        cache->dictionary = NULL;
    }

    cache->metadataValid = false;
    cache->device = 0;
    cache->inode = 0;
    cache->fileSize = 0;
    cache->fileMtime = (struct timespec){ .tv_sec = 0, .tv_nsec = 0 };
}

xpc_object_t rc_inject_policy_cache_copy_dictionary(RCInjectPolicyCache *cache,
                                                    const char *path)
{
    if (!cache || !path) {
        return NULL;
    }

    xpc_object_t snapshot = NULL;

    os_unfair_lock_lock(&cache->lock);

    struct stat pathStat = {};
    if (stat(path, &pathStat) != 0) {
        cache_clear_locked(cache);
        os_unfair_lock_unlock(&cache->lock);
        return NULL;
    }

    if (cache_metadata_matches(cache, &pathStat)) {
        if (cache->dictionary) {
            snapshot = xpc_retain(cache->dictionary);
        }
        os_unfair_lock_unlock(&cache->lock);
        return snapshot;
    }

    // Cache empty files as an invalid snapshot. This avoids repeatedly trying
    // to mmap/parse the same incomplete atomic-write intermediate state.
    if (pathStat.st_size <= 0) {
        cache_replace_locked(cache, &pathStat, NULL);
        os_unfair_lock_unlock(&cache->lock);
        return NULL;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        cache_clear_locked(cache);
        os_unfair_lock_unlock(&cache->lock);
        return NULL;
    }

    // fstat() the opened descriptor so the metadata we cache belongs to the
    // exact file object that is parsed even if the path is atomically replaced.
    struct stat fileStat = {};
    if (fstat(fd, &fileStat) != 0 || fileStat.st_size <= 0) {
        close(fd);
        if (fileStat.st_size <= 0 && fileStat.st_ino != 0) {
            cache_replace_locked(cache, &fileStat, NULL);
        } else {
            cache_clear_locked(cache);
        }
        os_unfair_lock_unlock(&cache->lock);
        return NULL;
    }

    void *addr = mmap(NULL, fileStat.st_size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
    close(fd);
    if (addr == MAP_FAILED) {
        cache_clear_locked(cache);
        os_unfair_lock_unlock(&cache->lock);
        return NULL;
    }

    xpc_object_t parsed = xpc_create_from_plist(addr, fileStat.st_size);
    munmap(addr, fileStat.st_size);

    if (parsed && xpc_get_type(parsed) != XPC_TYPE_DICTIONARY) {
        xpc_release(parsed);
        parsed = NULL;
    }

    // parsed may intentionally be NULL. Keeping the metadata in that case
    // caches a parse failure until the file itself changes.
    cache_replace_locked(cache, &fileStat, parsed);

    if (cache->dictionary) {
        snapshot = xpc_retain(cache->dictionary);
    }

    os_unfair_lock_unlock(&cache->lock);
    return snapshot;
}

void rc_inject_policy_cache_invalidate(RCInjectPolicyCache *cache)
{
    if (!cache) {
        return;
    }

    os_unfair_lock_lock(&cache->lock);
    cache_clear_locked(cache);
    os_unfair_lock_unlock(&cache->lock);
}
