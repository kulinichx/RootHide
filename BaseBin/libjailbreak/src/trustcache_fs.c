#include "trustcache_fs.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include "signatures.h"
#include "trustcache.h"


static int file_has_macho_magic(const char *path, bool *isMachoOut)
{
	*isMachoOut = false;
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return errno ? errno : EIO;

	uint32_t magic = 0;
	size_t size = 0;
	int status = 0;
	while (size < sizeof(magic)) {
		ssize_t n = read(fd, (char *)&magic + size, sizeof(magic) - size);
		if (n < 0 && errno == EINTR) continue;
		if (n < 0) {
			status = errno ? errno : EIO;
			break;
		}
		if (n == 0) break;
		size += (size_t)n;
	}
	if (close(fd) != 0 && status == 0) status = errno ? errno : EIO;
	if (status != 0) return status;

	/* Resources may be skipped; a marked Mach-O that fails parsing may not. */
	*isMachoOut = size == sizeof(magic) &&
		(magic == MH_MAGIC || magic == MH_CIGAM ||
		 magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
		 magic == FAT_MAGIC || magic == FAT_CIGAM ||
		 magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
	return 0;
}

static int walk_machos_in_dir(const char *dir_path, int (^macho_fat_walk)(const char *path, Fat *fat), bool recurse)
{
	DIR *dir = opendir(dir_path);
	if (!dir) return errno ? errno : EIO;

	int status = 0;
	for (;;) {
		errno = 0;
		struct dirent *entry = readdir(dir);
		if (!entry) {
			if (errno != 0) status = errno;
			break;
		}
		if (strcmp(entry->d_name, ".") == 0 ||
			strcmp(entry->d_name, "..") == 0) continue;

		size_t pathLength = strlen(dir_path);
		size_t nameLength = strlen(entry->d_name);
		if (nameLength > SIZE_MAX - 2 || pathLength > SIZE_MAX - nameLength - 2) {
			status = EOVERFLOW;
			break;
		}
		size_t full_path_size = pathLength + nameLength + 2;
		char *full_path = malloc(full_path_size);
		if (!full_path) {
			status = ENOMEM;
			break;
		}
		int written = snprintf(full_path, full_path_size, "%s/%s", dir_path, entry->d_name);
		if (written < 0 || (size_t)written >= full_path_size) {
			free(full_path);
			status = ENAMETOOLONG;
			break;
		}

		struct stat st;
		if (lstat(full_path, &st) != 0) status = errno ? errno : EIO;
		else if (S_ISDIR(st.st_mode) && recurse) {
			status = walk_machos_in_dir(full_path, macho_fat_walk, true);
		}
		else if (S_ISREG(st.st_mode)) {
			bool isMacho = false;
			status = file_has_macho_magic(full_path, &isMacho);
			if (status == 0 && isMacho) {
				Fat *fat = fat_init_from_path(full_path);
				if (!fat) status = ENOEXEC;
				else {
					status = macho_fat_walk(full_path, fat);
					fat_free(fat);
				}
			}
		}
		/* Do not follow symlinks, devices, sockets or non-recursive directories. */

		free(full_path);
		if (status != 0) break;
	}
	if (closedir(dir) != 0 && status == 0) status = errno ? errno : EIO;
	return status;
}

int directory_collect_untrusted_cdhashes_by_path(const char *directoryPath, bool recursive, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut)
{
	if (!directoryPath || !cdhashesOut || !cdhashCountOut) return EINVAL;
	*cdhashesOut = NULL;
	*cdhashCountOut = 0;

	__block cdhash_t *cdhashes = NULL;
	__block uint32_t cdhashCount = 0;

	int collectionStatus = walk_machos_in_dir(directoryPath, ^int(const char *path, Fat *fat){
		cdhash_t *thisCdhashes = NULL;
		uint32_t thiscdhashCount = 0;
		int status = file_collect_untrusted_cdhashes_by_path(path, &thisCdhashes, &thiscdhashCount);
		if (status != 0) {
			free(thisCdhashes);
			return status;
		}
		if (thiscdhashCount != 0) {
			if (thiscdhashCount > UINT32_MAX - cdhashCount) {
				free(thisCdhashes);
				return EOVERFLOW;
			}
			uint32_t newCount = cdhashCount + thiscdhashCount;
			cdhash_t *newCdhashes = realloc(cdhashes, (size_t)newCount * sizeof(cdhash_t));
			if (!newCdhashes) {
				free(thisCdhashes);
				return ENOMEM;
			}
			cdhashes = newCdhashes;
			memcpy(&cdhashes[cdhashCount], thisCdhashes, sizeof(cdhash_t) * thiscdhashCount);
			cdhashCount = newCount;
		}
		free(thisCdhashes);
		return 0;
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
	if (status == 0 && cdhashCount > 0) {
		status = jb_trustcache_add_cdhashes(cdhashes, cdhashCount);
	}
	free(cdhashes);
	return status;
}

int jb_trustcache_add_directory(const char *directoryPath, bool recursive)
{
	cdhash_t *cdhashes = NULL;
	uint32_t cdhashCount = 0;

	int status = directory_collect_untrusted_cdhashes_by_path(directoryPath, recursive, &cdhashes, &cdhashCount);
	if (status == 0 && cdhashCount > 0) {
		status = jb_trustcache_add_cdhashes(cdhashes, cdhashCount);
	}
	free(cdhashes);
	return status;
}
