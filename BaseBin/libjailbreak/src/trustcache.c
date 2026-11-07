#include "trustcache.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include "kernel.h"
#include "info.h"
#include "primitives.h"

static pthread_mutex_t gJbTrustcacheLock = PTHREAD_MUTEX_INITIALIZER;
static bool _jb_trustcache_contains_cdhash_locked(cdhash_t hash);

void _trustcache_file_init(trustcache_file_v1 *file)
{
	memset(file, 0, sizeof(*file));
	file->version = 1;
	uuid_generate(file->uuid);
}

// iOS 16:
// ppl_trust_cache_rt has trustcache runtime
// **(ppl_trust_cache_rt+0x20) seems to have the loaded trustcache linked list
// trustcache struct changed, "next" is still at +0x0, but "this" is at +0x20

static int _trustcache_list_get_start_address(uint64_t *addressOut)
{
	if (!addressOut) return EINVAL;
	*addressOut = 0;

	uint64_t address = ksymbol(pmap_image4_trust_caches);
	if (address) { // iOS <=15
		*addressOut = address;
		return 0;
	}

	uint64_t runtime = ksymbol(ppl_trust_cache_rt);
	if (!runtime) runtime = ksymbol_txm(txm_trustcache_root);
	if (!runtime) return ENOTSUP;

	int result = kreadbuf(runtime + 0x20, addressOut, sizeof(*addressOut));
	if (result != 0) return result;
	if (!*addressOut) return EFAULT;
	return 0;
}

static int _trustcache_list_get_start(uint64_t *startOut)
{
	if (!startOut) return EINVAL;
	*startOut = 0;

	uint64_t address = 0;
	int result = _trustcache_list_get_start_address(&address);
	if (result != 0) return result;
	return kreadbuf(address, startOut, sizeof(*startOut));
}

static int _trustcache_list_enumerate(void (^enumerateBlock)(uint64_t tcKaddr, bool *stop))
{
	uint64_t curTC = 0;
	int result = _trustcache_list_get_start(&curTC);
	if (result != 0) return result;

	while (curTC != 0) {
		bool stop = false;
		enumerateBlock(curTC, &stop);
		if (stop) break;
		result = kreadbuf(curTC + koffsetof(trustcache, nextptr), &curTC, sizeof(curTC));
		if (result != 0) return result;
	}
	return 0;
}

static int _trustcache_restore_pointer(uint64_t address, uint64_t originalValue, uint64_t writtenValue)
{
	uint64_t currentValue = 0;
	int result = kreadbuf(address, &currentValue, sizeof(currentValue));
	if (result != 0) return result;
	if (currentValue == originalValue) return 0;
	if (currentValue != writtenValue) return EBUSY;
	return kwrite64(address, originalValue);
}

int trustcache_list_insert(uint64_t tcToInsert)
{
	if (!tcToInsert) return EINVAL;

	if (ksymbol(SPTMArgs)) {
		__block uint64_t lastTC = 0;
		int result = _trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
			lastTC = tcKaddr;
		});
		if (result != 0) return result;
		if (!lastTC) return ENOENT;

		if (koffsetof(trustcache, prevptr)) {
			result = kwrite64(tcToInsert + koffsetof(trustcache, prevptr), lastTC);
			if (result != 0) return result;
		}

		uint64_t nextAddress = lastTC + koffsetof(trustcache, nextptr);
		result = kwrite64(nextAddress, tcToInsert);
		if (result != 0) {
			int rollbackResult = _trustcache_restore_pointer(nextAddress, 0, tcToInsert);
			return rollbackResult != 0 ? rollbackResult : result;
		}
		return 0;
	}

	uint64_t startAddress = 0, previousStartTC = 0, previousPrev = 0;
	int result = _trustcache_list_get_start_address(&startAddress);
	if (result != 0) return result;
	result = kreadbuf(startAddress, &previousStartTC, sizeof(previousStartTC));
	if (result != 0) return result;

	uint64_t previousPrevAddress = previousStartTC && koffsetof(trustcache, prevptr)
		? previousStartTC + koffsetof(trustcache, prevptr) : 0;
	if (previousPrevAddress) {
		result = kreadbuf(previousPrevAddress, &previousPrev, sizeof(previousPrev));
		if (result != 0) return result;
	}

	result = kwrite64(tcToInsert + koffsetof(trustcache, nextptr), previousStartTC);
	if (result != 0) return result;
	if (previousPrevAddress) {
		result = kwrite64(previousPrevAddress, tcToInsert);
		if (result != 0) {
			int rollbackResult = _trustcache_restore_pointer(previousPrevAddress, previousPrev, tcToInsert);
			return rollbackResult != 0 ? rollbackResult : result;
		}
	}

	result = kwrite64(startAddress, tcToInsert);
	if (result != 0) {
		int rollbackResult = _trustcache_restore_pointer(startAddress, previousStartTC, tcToInsert);
		if (rollbackResult != 0) return rollbackResult;
		if (previousPrevAddress) {
			rollbackResult = _trustcache_restore_pointer(previousPrevAddress, previousPrev, tcToInsert);
			if (rollbackResult != 0) return rollbackResult;
		}
	}
	return result;
}

int trustcache_list_remove(uint64_t tcKaddr)
{
	if (!tcKaddr) return EINVAL;

	uint64_t startAddress = 0, curTC = 0;
	int result = _trustcache_list_get_start_address(&startAddress);
	if (result != 0) return result;
	result = kreadbuf(startAddress, &curTC, sizeof(curTC));
	if (result != 0) return result;

	uint64_t previousAddress = startAddress;
	uint64_t previousTC = 0;
	while (curTC && curTC != tcKaddr) {
		previousTC = curTC;
		previousAddress = curTC + koffsetof(trustcache, nextptr);
		result = kreadbuf(previousAddress, &curTC, sizeof(curTC));
		if (result != 0) return result;
	}
	if (!curTC) return ENOENT;

	uint64_t nextTC = 0, nextPrev = 0;
	result = kreadbuf(tcKaddr + koffsetof(trustcache, nextptr), &nextTC, sizeof(nextTC));
	if (result != 0) return result;
	uint64_t nextPrevAddress = nextTC && koffsetof(trustcache, prevptr)
		? nextTC + koffsetof(trustcache, prevptr) : 0;
	if (nextPrevAddress) {
		result = kreadbuf(nextPrevAddress, &nextPrev, sizeof(nextPrev));
		if (result != 0) return result;
	}

	result = kwrite64(previousAddress, nextTC);
	if (result != 0) {
		int rollbackResult = _trustcache_restore_pointer(previousAddress, tcKaddr, nextTC);
		return rollbackResult != 0 ? rollbackResult : result;
	}
	if (nextPrevAddress) {
		result = kwrite64(nextPrevAddress, previousTC);
		if (result != 0) {
			int rollbackResult = _trustcache_restore_pointer(nextPrevAddress, nextPrev, previousTC);
			int forwardResult = _trustcache_restore_pointer(previousAddress, tcKaddr, nextTC);
			if (forwardResult != 0) return forwardResult;
			if (rollbackResult != 0) return rollbackResult;
		}
	}
	return result;
}

int _trustcache_file_sort_entry_comparator_v1(const void * vp1, const void * vp2)
{
	trustcache_entry_v1* tc1 = (trustcache_entry_v1*)vp1;
	trustcache_entry_v1* tc2 = (trustcache_entry_v1*)vp2;
	return memcmp(tc1->hash, tc2->hash, sizeof(cdhash_t));
}

void _trustcache_file_sort(trustcache_file_v1 *file)
{
	qsort(file->entries, file->length, sizeof(trustcache_entry_v1), _trustcache_file_sort_entry_comparator_v1);
}

static int _is_jb_trustcache(uint64_t tcKaddr, bool *isJbOut)
{
	if (!isJbOut) return EINVAL;
	*isJbOut = false;

	uint64_t file = 0;
	int result = kreadbuf(tcKaddr + koffsetof(trustcache, fileptr), &file, sizeof(file));
	if (result != 0) return result;
	if (file == tcKaddr + offsetof(jb_trustcache, file)) {
		// If there is exactly one 8-byte value between the kpage start and the trustcache file,
		// Check if that matches against the JB_MAGIC
		// This is a 100% accurate way of determining whether this entry is a jb_trustcache or not
		uint64_t magic = 0;
		result = kreadbuf(tcKaddr + offsetof(jb_trustcache, magic), &magic, sizeof(magic));
		if (result != 0) return result;
		*isJbOut = magic == JB_MAGIC;
	}
	return 0;
}

static int _jb_trustcache_enumerate(void (^enumerateBlock)(uint64_t jbTcKaddr, bool *stop))
{
	__block int identifyResult = 0;
	int result = _trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		bool isJb = false;
		identifyResult = _is_jb_trustcache(tcKaddr, &isJb);
		if (identifyResult != 0) {
			*stop = true;
			return;
		}
		if (isJb) enumerateBlock(tcKaddr, stop);
	});
	return result != 0 ? result : identifyResult;
}

void jb_trustcache_clear(void)
{
	pthread_mutex_lock(&gJbTrustcacheLock);
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		kwrite64(jbTcKaddr + offsetof(jb_trustcache, file.length), 0);
	});
	pthread_mutex_unlock(&gJbTrustcacheLock);
}

static int _jb_trustcache_grow(uint64_t *jbTcKernOut)
{
	if (!jbTcKernOut) return EINVAL;
	*jbTcKernOut = 0;

	uint64_t jbTcKern = 0;
	int result = kalloc(&jbTcKern, JB_TRUSTCACHE_SIZE);
	if (result != 0) return result;
	if (!jbTcKern) return ENOMEM;

	jb_trustcache header = {0};
	jb_trustcache *jbTc = &header;
	_trustcache_file_init(&jbTc->file);
	jbTc->magic = JB_MAGIC;
	*(uint64_t *)(jbTc->trustcache + koffsetof(trustcache, fileptr)) = (jbTcKern + offsetof(jb_trustcache, file));
	if (koffsetof(trustcache, size)) {
		*(uint64_t *)(jbTc->trustcache + koffsetof(trustcache, size)) = JB_TRUSTCACHE_SIZE;
	}
	if (koffsetof(trustcache, type)) {
		*(uint64_t *)(jbTc->trustcache + koffsetof(trustcache, type)) = 0x5;
	}
	result = kwritebuf(jbTcKern, jbTc, sizeof(*jbTc));
	if (result != 0) {
		kfree(jbTcKern, JB_TRUSTCACHE_SIZE);
		return result;
	}

	result = trustcache_list_insert(jbTcKern);
	// A failed list write may have published the page, so retain it.
	if (result != 0) return result;
	*jbTcKernOut = jbTcKern;
	return 0;
}

int jb_trustcache_add_entries(struct trustcache_entry_v1 *entries, uint32_t entryCount)
{
	if (entryCount == 0) return 0;
	if (!entries) return EINVAL;

	int result = 0;
	trustcache_entry_v1 *filtered = NULL;
	jb_trustcache *page = NULL;

	pthread_mutex_lock(&gJbTrustcacheLock);

	filtered = calloc(entryCount, sizeof(*filtered));
	if (!filtered) {
		result = -1;
		goto out;
	}

	uint32_t filteredCount = 0;
	for (uint32_t i = 0; i < entryCount; i++) {
		bool duplicateInBatch = false;
		for (uint32_t j = 0; j < filteredCount; j++) {
			if (memcmp(filtered[j].hash, entries[i].hash, sizeof(cdhash_t)) == 0) {
				duplicateInBatch = true;
				break;
			}
		}
		if (duplicateInBatch) continue;

		/*
		 * Recheck RootHide's dynamic trustcaches while holding the same lock
		 * used for append/clear. This closes the concurrent add race without
		 * depending on stale positives from unrelated trustcache sources.
		 */
		if (_jb_trustcache_contains_cdhash_locked(entries[i].hash)) continue;

		filtered[filteredCount++] = entries[i];
	}

	if (filteredCount == 0) goto out;

	page = malloc(JB_TRUSTCACHE_SIZE);
	if (!page) {
		result = -1;
		goto out;
	}

	uint32_t consumed = 0;
	while (consumed < filteredCount) {
		__block uint64_t freeJbTcKaddr = 0;
		__block uint32_t freeJbTcCurrentLength = 0;

		__block int lengthResult = 0;
		int enumerateResult = _jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
			uint32_t length = 0;
			lengthResult = kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.length), &length, sizeof(length));
			if (lengthResult != 0 || length > JB_TRUSTCACHE_ENTRY_COUNT) {
				if (lengthResult == 0) lengthResult = EINVAL;
				*stop = true;
				return;
			}
			if (length < JB_TRUSTCACHE_ENTRY_COUNT) {
				freeJbTcKaddr = jbTcKaddr;
				freeJbTcCurrentLength = length;
				*stop = true;
			}
		});
		if (enumerateResult != 0) {
			result = enumerateResult;
			break;
		}
		if (lengthResult != 0) {
			result = lengthResult;
			break;
		}

		if (freeJbTcKaddr == 0) {
			freeJbTcCurrentLength = 0;
			result = _jb_trustcache_grow(&freeJbTcKaddr);
			if (result != 0) {
				break;
			}
		}

		uint32_t capacity = JB_TRUSTCACHE_ENTRY_COUNT - freeJbTcCurrentLength;
		if (capacity == 0) {
			result = EINVAL;
			break;
		}

		uint32_t remaining = filteredCount - consumed;
		uint32_t chunk = remaining < capacity ? remaining : capacity;

		result = kreadbuf(freeJbTcKaddr, page, JB_TRUSTCACHE_SIZE);
		if (result != 0) break;
		if (page->file.length != freeJbTcCurrentLength) {
			result = EBUSY;
			break;
		}

		for (uint32_t i = 0; i < chunk; i++) {
			page->file.entries[freeJbTcCurrentLength + i] = filtered[consumed + i];
		}

		page->file.length = freeJbTcCurrentLength + chunk;
		_trustcache_file_sort(&page->file);
		result = kwritebuf(freeJbTcKaddr, page, JB_TRUSTCACHE_SIZE);
		if (result != 0) break;
		consumed += chunk;
	}

out:
	free(page);
	free(filtered);
	pthread_mutex_unlock(&gJbTrustcacheLock);
	return result;
}

int jb_trustcache_add_cdhashes(cdhash_t *hashes, uint32_t hashCount)
{
	if (hashCount == 0) return 0;
	if (!hashes) return -1;
	struct trustcache_entry_v1 *entries = calloc(hashCount, sizeof(*entries));
	if (!entries) return -1;
	for (uint32_t i = 0; i < hashCount; i++) {
		memcpy(entries[i].hash, hashes[i], sizeof(cdhash_t));
		entries[i].hash_type = 1;
		entries[i].flags = 0;
	}
	int result = jb_trustcache_add_entries(entries, hashCount);
	free(entries);
	return result;
}

int jb_trustcache_add_entry(struct trustcache_entry_v1 entry)
{
	return jb_trustcache_add_entries(&entry, 1);
}


/*int jb_trustcache_add_file(const char *filePath)
{
	
}

int jb_trustcache_add_directory(const char *directoryPath)
{

}*/

xpc_object_t jb_trustcache_info(void)
{
	xpc_object_t arr = xpc_array_create_empty();
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		uuid_t uuid;
		kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.uuid), (void *)uuid, sizeof(uuid));
		uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));

		xpc_object_t tcDict = xpc_dictionary_create_empty();
		xpc_dictionary_set_data(tcDict, "uuid", &uuid, sizeof(uuid));

		xpc_object_t hashesArr = xpc_array_create_empty();
		for (int i = 0; i < length; i++) {
			trustcache_entry_v1 entry;
			kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.entries[i]), &entry, sizeof(entry));
			xpc_array_set_data(hashesArr, XPC_ARRAY_APPEND, &entry.hash, sizeof(entry.hash));
		}
		xpc_dictionary_set_value(tcDict, "cdhashes", hashesArr);
		xpc_release(hashesArr);

		xpc_array_append_value(arr, tcDict);
		xpc_release(tcDict);
	});
	return arr;
}

void jb_trustcache_debug_print(FILE *f)
{
	__block int i = 0;
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		uuid_t uuid;
		kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.uuid), (void *)uuid, sizeof(uuid));
		uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));

		uint32_t *uuidData = (uint32_t *)uuid;
		fprintf(f, "Jailbreak TrustCache %d <%08x%08x%08x%08x> (length: %u) (kaddr: 0x%llx):\n", i++, htonl(uuidData[0]), htonl(uuidData[1]), htonl(uuidData[2]), htonl(uuidData[3]), length, jbTcKaddr);
		
		for (uint32_t j = 0; j < length; j++) {
			trustcache_entry_v1 entry;
			kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.entries[j]), &entry, sizeof(entry));
			fprintf(f, "| ");
			for (uint32_t k = 0; k < sizeof(cdhash_t); k++) {
				fprintf(f, "%02x", entry.hash[k]);
			}
			fprintf(f, "\n");
		}
	});


	/////////////////////////////////////////////////////////////////
	_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		bool isJb = false;
		if (_is_jb_trustcache(tcKaddr, &isJb) != 0 || isJb) return;

		uint64_t tcFileKaddr = kread64(tcKaddr + koffsetof(trustcache, fileptr));
		uint32_t length = kread32(tcFileKaddr + offsetof(trustcache_file_v1, length));
		if (length == 0) return;
	
		uuid_t uuid;
		kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, uuid), (void *)uuid, sizeof(uuid));

		uint32_t *uuidData = (uint32_t *)uuid;
		fprintf(f, "TrustCache File <%08x%08x%08x%08x> (length: %u) (kaddr: 0x%llx):\n", htonl(uuidData[0]), htonl(uuidData[1]), htonl(uuidData[2]), htonl(uuidData[3]), length, tcFileKaddr);
		
		for (uint32_t j = 0; j < length; j++) {
			trustcache_entry_v1 entry;
			kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, entries[j]), &entry, sizeof(entry));
			fprintf(f, "| ");
			for (uint32_t k = 0; k < sizeof(cdhash_t); k++) {
				fprintf(f, "%02x", entry.hash[k]);
			}
			fprintf(f, "\n");
		}
	});
	
}

int trustcache_file_upload(trustcache_file_v1 *tc)
{
	if (!tc) return EINVAL;
	const uint64_t maxEntries = (JB_TRUSTCACHE_SIZE - ksizeof(trustcache) - sizeof(trustcache_file_v1))
		/ sizeof(trustcache_entry_v1);
	if (tc->length > maxEntries) return EINVAL;

	uint64_t tcSize = ksizeof(trustcache) + sizeof(trustcache_file_v1) + (tc->length * sizeof(trustcache_entry_v1));
	if (tcSize > JB_TRUSTCACHE_SIZE) return EINVAL;

	// Check if there is already a TrustCache with the same UUID
	__block uint64_t existingTcKaddr = 0;
	__block int lookupResult = 0;
	int result = _trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		uint64_t tcFileKaddr = 0;
		lookupResult = kreadbuf(tcKaddr + koffsetof(trustcache, fileptr), &tcFileKaddr, sizeof(tcFileKaddr));
		if (lookupResult == 0 && !tcFileKaddr) lookupResult = EFAULT;
		uuid_t tcFileUUID;
		if (lookupResult == 0) {
			lookupResult = kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, uuid), tcFileUUID, sizeof(tcFileUUID));
		}
		if (lookupResult != 0) {
			*stop = true;
			return;
		}
		if (memcmp(tcFileUUID, tc->uuid, sizeof(tcFileUUID)) == 0) {
			existingTcKaddr = tcKaddr;
			*stop = true;
		}
	});
	if (result != 0) return result;
	if (lookupResult != 0) return lookupResult;

	// If so, we want to either replace it or remove it
	if (existingTcKaddr != 0) {
		bool isJb = false;
		result = _is_jb_trustcache(existingTcKaddr, &isJb);
		if (result != 0) return result;
		if (isJb) {
			// There is something terribly wrong, abort
			return EINVAL;
		}

		uint64_t prevTcFile = 0;
		uint32_t prevTcLength = 0;
		result = kreadbuf(existingTcKaddr + koffsetof(trustcache, fileptr), &prevTcFile, sizeof(prevTcFile));
		if (result != 0) return result;
		if (!prevTcFile) return EFAULT;
		result = kreadbuf(prevTcFile + offsetof(trustcache_file_v1, length), &prevTcLength, sizeof(prevTcLength));
		if (result != 0) return result;
		if (prevTcLength > maxEntries) return EINVAL;
		uint64_t prevTcSize = ksizeof(trustcache) + sizeof(trustcache_file_v1) + (prevTcLength * sizeof(trustcache_entry_v1));
		if (prevTcSize == tcSize) {
			// If size is the same this is simple, just replace the file data
			return kwritebuf(prevTcFile, tc, tcSize - ksizeof(trustcache));
		}
		else {
			// If not, it gets more complicated and hacky...
			// We can't take a lock (at least not yet??) to ensure nothing accesses the original TrustCache after we freed it
			// So we do the next best thing, we remove it from the linked list and wait a bit before freeing it, hoping that any
			// outstanding reads on the memory would be done by then
			result = trustcache_list_remove(existingTcKaddr);
			if (result != 0) return result;
			usleep(10000); // hope for current accesses to finish if there are any (new accesses won't come as we removed the list entry)
			(void)kfree(existingTcKaddr, prevTcSize);
			// now just fall through and make this function add the new TrustCache
		}
	}

	uint64_t tcKaddr = 0;
	result = kalloc(&tcKaddr, tcSize);
	if (result != 0) return result;
	if (!tcKaddr) return ENOMEM;

	// kalloc is not guaranteed to be zeroed, make sure trustcache head is zeroed
	char nullBuf[ksizeof(trustcache)];
	memset(nullBuf, 0, sizeof(nullBuf));
	result = kwritebuf(tcKaddr, nullBuf, sizeof(nullBuf));

	uint64_t tcFileKaddr = tcKaddr + ksizeof(trustcache);
	if (result == 0) result = kwritebuf(tcFileKaddr, tc, tcSize - ksizeof(trustcache));

	if (result == 0) result = kwrite64(tcKaddr + koffsetof(trustcache, fileptr), tcFileKaddr);
	if (result == 0 && koffsetof(trustcache, size)) {
		result = kwrite64(tcKaddr + koffsetof(trustcache, size), tcSize);
	}
	if (result == 0 && koffsetof(trustcache, type)) {
		result = kwrite64(tcKaddr + koffsetof(trustcache, type), 0x5);
	}
	if (result != 0) {
		(void)kfree(tcKaddr, tcSize);
		return result;
	}

	// Insertion may have partially published the allocation; retain it on error.
	return trustcache_list_insert(tcKaddr);
}

int trustcache_file_upload_with_uuid(trustcache_file_v1 *tc, uuid_t uuid)
{
	if (!tc || !uuid) return EINVAL;
	memcpy(tc->uuid, uuid, sizeof(uuid_t));
	return trustcache_file_upload(tc);
}

int trustcache_file_build_from_cdhashes(cdhash_t *CDHashes, uint32_t CDHashCount, trustcache_file_v1 **tcOut)
{
	if (!tcOut) return -1;
	*tcOut = NULL;
	if (!CDHashes || CDHashCount == 0) return -1;
	size_t payloadSize, tcSize;
	if (__builtin_mul_overflow((size_t)CDHashCount, sizeof(trustcache_entry_v1), &payloadSize) ||
	    __builtin_add_overflow(sizeof(trustcache_file_v1), payloadSize, &tcSize)) return -1;
	trustcache_file_v1 *file = malloc(tcSize);
	if (!file) return -1;
	_trustcache_file_init(file);

	file->length = CDHashCount;
	for (uint32_t i = 0; i < CDHashCount; i++) {
		memcpy(file->entries[i].hash, CDHashes[i], sizeof(cdhash_t));
		file->entries[i].hash_type = 2;
		file->entries[i].flags = 0;
	}
	_trustcache_file_sort(file);

	*tcOut = file;
	return 0;
}

static int trustcache_read_full(int fd, void *buffer, size_t size)
{
	size_t offset = 0;
	while (offset < size) {
		ssize_t amount = read(fd, (uint8_t *)buffer + offset, size - offset);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) return -1;
		offset += (size_t)amount;
	}
	return 0;
}

int trustcache_file_build_from_path(const char *filePath, trustcache_file_v1 **tcOut)
{
	if (!tcOut) return -1;
	*tcOut = NULL;
	if (!filePath) return -1;
	int fd = open(filePath, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	int result = -1;
	trustcache_file_v1 *file = NULL;
	struct stat s = {0};
	if (fstat(fd, &s) != 0 || !S_ISREG(s.st_mode) ||
	    s.st_size < (off_t)sizeof(trustcache_file_v1) || (uintmax_t)s.st_size > SIZE_MAX) goto out;

	// Validate the fixed header before allocating based on an untrusted file size.
	trustcache_file_v1 header;
	if (trustcache_read_full(fd, &header, sizeof(header)) != 0 || header.version != 1) goto out;
	size_t tcSize = (size_t)s.st_size;
	size_t payloadSize = tcSize - sizeof(header);
	if (payloadSize % sizeof(trustcache_entry_v1) != 0 ||
	    header.length != payloadSize / sizeof(trustcache_entry_v1)) goto out;

	file = malloc(tcSize);
	if (!file) goto out;
	memcpy(file, &header, sizeof(header));
	if (trustcache_read_full(fd, file->entries, payloadSize) != 0) goto out;
	*tcOut = file;
	file = NULL;
	result = 0;
out:
	free(file);
	close(fd);
	return result;
}

bool trustcache_contains_cdhash(uint64_t tcKaddr, cdhash_t CDHash)
{
	uint64_t tcFileKaddr = kread64(tcKaddr + koffsetof(trustcache, fileptr));
	uint32_t length = kread32(tcFileKaddr + offsetof(trustcache_file_v1, length));
	if (length == 0) return false;

	int32_t left = 0;
	int32_t right = length - 1;

	while (left <= right) {
		int32_t mid = (left + right) / 2;
		cdhash_t itCDHash;
		kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, entries[mid].hash), itCDHash, CS_CDHASH_LEN);
		int32_t cmp = memcmp(CDHash, itCDHash, CS_CDHASH_LEN);
		if (cmp == 0) {
			return true;
		}
		if (cmp < 0) {
			right = mid - 1;
		} else {
			left = mid + 1;
		}
	}
	return false;
}

static bool _jb_trustcache_contains_cdhash_locked(cdhash_t hash)
{
	__block bool found = false;
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		if (trustcache_contains_cdhash(jbTcKaddr, hash)) {
			found = true;
			*stop = true;
		}
	});
	return found;
}

bool is_cdhash_trustcached(cdhash_t CDHash)
{
	__block bool inTrustCache = false;
	_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		bool inThisTrustCache = trustcache_contains_cdhash(tcKaddr, CDHash);
		if (inThisTrustCache) {
			inTrustCache = true;
			*stop = true;
		}
	});
	return inTrustCache;
}
