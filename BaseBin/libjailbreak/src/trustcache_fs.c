#include "trustcache_fs.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include "signatures.h"
#include "trustcache.h"


void walk_machos_in_dir(const char *dir_path, void (^macho_fat_walk)(const char *path, Fat *fat), bool recurse)
{
    DIR *dir = opendir(dir_path);
    if (!dir) {
        perror(dir_path);
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        /* Skip the current- and parent-directory entries */
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0)
            continue;

        /* Build the full path */
		size_t full_path_size = strlen(dir_path) + strlen(entry->d_name) + 2;
        char *full_path = malloc(full_path_size);
        int written = snprintf(full_path, full_path_size, "%s/%s", dir_path, entry->d_name);

        struct stat st;
        if (lstat(full_path, &st) != 0) {
            perror(full_path);
			free(full_path);
            continue;
        }

        if (S_ISDIR(st.st_mode) && recurse) {
            /* Recurse into sub-directory */
            walk_machos_in_dir(full_path, macho_fat_walk, recurse);
        } else if (S_ISREG(st.st_mode)) {
            /* Regular file – check for Mach-O magic */
			Fat *fat = fat_init_from_path(full_path);
			if (fat) {
				macho_fat_walk(full_path, fat);
				fat_free(fat);
			}
        }
        /* Symlinks, devices, sockets, etc. are silently ignored */

		free(full_path);
    }

    closedir(dir);
}

int directory_collect_untrusted_cdhashes_by_path(const char *directoryPath, bool recursive, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut)
{
	if (!directoryPath || !cdhashesOut || !cdhashCountOut) return EINVAL;
	*cdhashesOut = NULL;
	*cdhashCountOut = 0;

	__block cdhash_t *cdhashes = NULL;
	__block uint32_t cdhashCount = 0;
	__block int collectionStatus = 0;

	walk_machos_in_dir(directoryPath, ^(const char *path, Fat *fat){
		if (collectionStatus != 0) return;
		printf("Collecting cdhash of %s\n", path);
		cdhash_t *thisCdhashes = NULL;
		uint32_t thiscdhashCount = 0;
		collectionStatus = file_collect_untrusted_cdhashes_by_path(path, &thisCdhashes, &thiscdhashCount);
		if (collectionStatus != 0) {
			free(thisCdhashes);
			return;
		}
		if (thiscdhashCount != 0) {
			if (thiscdhashCount > UINT32_MAX - cdhashCount) {
				collectionStatus = EOVERFLOW;
				free(thisCdhashes);
				return;
			}
			uint32_t newCount = cdhashCount + thiscdhashCount;
			cdhash_t *newCdhashes = realloc(cdhashes, newCount * sizeof(cdhash_t));
			if (!newCdhashes) {
				collectionStatus = ENOMEM;
				free(thisCdhashes);
				return;
			}
			cdhashes = newCdhashes;
			memcpy(&cdhashes[cdhashCount], thisCdhashes, sizeof(cdhash_t) * thiscdhashCount);
			cdhashCount = newCount;
		}
		free(thisCdhashes);
	}, recursive);

	if (collectionStatus != 0) {
		free(cdhashes);
		return collectionStatus;
	}

	*cdhashesOut = cdhashes;
	*cdhashCountOut = cdhashCount;
	return 0;
}

int jb_trustcache_add_file(const char *filePath)
{
	cdhash_t *cdhashes = NULL;
	uint32_t cdhashCount = 0;
	int status = file_collect_untrusted_cdhashes_by_path(filePath, &cdhashes, &cdhashCount);
	if (status != 0) return status;

	if (cdhashes && cdhashCount > 0) {
		jb_trustcache_add_cdhashes(cdhashes, cdhashCount);
		free(cdhashes);
	}

	return 0;
}

int jb_trustcache_add_directory(const char *directoryPath, bool recursive)
{
	cdhash_t *cdhashes = NULL;
	uint32_t cdhashCount = 0;

	int status = directory_collect_untrusted_cdhashes_by_path(directoryPath, recursive, &cdhashes, &cdhashCount);
	if (status != 0) return status;
	if (cdhashes && cdhashCount > 0) {
		printf("Added %u cdhashes\n", cdhashCount);
		jb_trustcache_add_cdhashes(cdhashes, cdhashCount);
		free(cdhashes);
	}

	return 0;
}
