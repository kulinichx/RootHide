#import "info.h"
#import "primitives.h"
#import "translation.h"
#import "kernel.h"
#import "util.h"
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>
#import <errno.h>
#import <limits.h>
#import <stdint.h>
#import <string.h>

static CFNumberRef CFNUM64(uint64_t value)
{
	return CFNumberCreate(NULL, kCFNumberSInt64Type, (void *)&value);
}

static bool IOSurface_target_address(uint64_t base, uint64_t offset, uint64_t *address)
{
	if (!base || !address) {
		errno = EFAULT;
		return false;
	}
	if (base > UINT64_MAX - offset) {
		errno = EOVERFLOW;
		return false;
	}
	*address = base + offset;
	return true;
}

static bool IOSurface_read_bytes(uint64_t address, void *output, size_t size)
{
	if (!address || !output || !size) {
		errno = EFAULT;
		return false;
	}
	if ((uint64_t)size > UINT64_MAX - address) {
		errno = EOVERFLOW;
		return false;
	}
	memset(output, 0, size);
	if (kreadbuf(address, output, size) != 0) {
		errno = EIO;
		return false;
	}
	errno = 0;
	return true;
}

static bool IOSurface_read_u64(uint64_t address, uint64_t *value)
{
	if (!value) {
		errno = EFAULT;
		return false;
	}
	*value = 0;
	return IOSurface_read_bytes(address, value, sizeof(*value));
}

static bool IOSurface_read_u32(uint64_t address, uint32_t *value)
{
	if (!value) {
		errno = EFAULT;
		return false;
	}
	*value = 0;
	return IOSurface_read_bytes(address, value, sizeof(*value));
}

static uint64_t IOSurface_read_ptr(uint64_t address)
{
	uint64_t value = 0;
	return IOSurface_read_u64(address, &value) ? UNSIGN_PTR(value) : 0;
}

static bool IOSurface_kernel_pointer(uint64_t value)
{
	return value >= 0xffff000000000000ULL && value != 0xffffffffffffffffULL;
}

static bool IOSurface_object_is_surface(uint64_t candidate)
{
	if (!IOSurface_kernel_pointer(candidate)) return false;
	uint64_t mdOffset = koffsetof(IOSurface, memoryDescriptor);
	if (!mdOffset) mdOffset = 0x20;
	uint64_t mdAddress = 0;
	if (!IOSurface_target_address(candidate, mdOffset, &mdAddress)) return false;
	uint64_t descriptor = IOSurface_read_ptr(mdAddress);
	if (!IOSurface_kernel_pointer(descriptor)) return false;
	uint64_t rangesAddress = 0;
	if (!IOSurface_target_address(descriptor, 0x60, &rangesAddress)) return false;
	return IOSurface_kernel_pointer(IOSurface_read_ptr(rangesAddress));
}

static int IOSurface_write(uint64_t address, const void *value, size_t size)
{
	if (!address || !value || !size) {
		errno = EFAULT;
		return -1;
	}
	if ((uint64_t)size > UINT64_MAX - address) {
		errno = EOVERFLOW;
		return -1;
	}
	if (kwritebuf(address, value, size) != 0) {
		errno = EIO;
		return -1;
	}
	errno = 0;
	return 0;
}

uint64_t IOSurfaceRootUserClient_get_surfaceClientById(uint64_t rootUserClient, uint32_t surfaceId)
{
	uint64_t arrayAddress = 0;
	if (!IOSurface_target_address(rootUserClient, 0x118, &arrayAddress)) return 0;
	uint64_t surfaceClientsArray = IOSurface_read_ptr(arrayAddress);
	if (!surfaceClientsArray) return 0;
	uint64_t offset = sizeof(uint64_t) * (uint64_t)surfaceId;
	uint64_t entryAddress = 0;
	if (!IOSurface_target_address(surfaceClientsArray, offset, &entryAddress)) return 0;
	return IOSurface_read_ptr(entryAddress);
}

uint64_t IOSurfaceClient_get_surface(uint64_t surfaceClient)
{
	uint64_t address = 0;
	return IOSurface_target_address(surfaceClient, 0x40, &address) ? IOSurface_read_ptr(address) : 0;
}

uint64_t IOSurfaceSendRight_get_surface(uint64_t surfaceSendRight)
{
	errno = 0;
	if (!surfaceSendRight) {
		errno = EFAULT;
		return 0;
	}
	uint8_t buf[0x30] = {0};
	uint64_t readOffset = 0;
	uint64_t readSize = 0;
	bool bufferedRead = gPrimitives.krwMinSafeReadSize > 0x8;
	uint64_t surface = 0;
	if (bufferedRead) {
		if (gPrimitives.krwMinSafeReadSize > 0x20) {
			errno = ERANGE;
			return 0;
		}
		// ClearSword reads 0x20-byte windows even for smaller kreadbuf sizes.
		// Keep the read inside the existing 0x30-byte SendRight inspection window.
		readSize = 0x20;
		readOffset = sizeof(buf) - readSize;
		uint64_t readAddress = 0;
		if (readOffset > 0x18 || !IOSurface_target_address(surfaceSendRight, readOffset, &readAddress)) return 0;
		if (!IOSurface_read_bytes(readAddress, buf, (size_t)readSize)) return 0;
		uint64_t value = 0;
		memcpy(&value, &buf[0x18 - readOffset], sizeof(value));
		surface = UNSIGN_PTR(value);
	} else {
		uint64_t address = 0;
		if (!IOSurface_target_address(surfaceSendRight, 0x18, &address)) return 0;
		surface = IOSurface_read_ptr(address);
	}
	if (IOSurface_object_is_surface(surface)) return surface;
	// Probe only fields whose full pointer fits in the bounded 0x30-byte window.
	// For minimum-window KRW primitives, reuse the captured bytes instead of
	// issuing 8-byte reads that the backend widens past the SendRight object.
	static const uint64_t probeOffsets[] = { 0x20, 0x28, 0x10 };
	for (size_t i = 0; i < sizeof(probeOffsets) / sizeof(probeOffsets[0]); i++) {
		uint64_t candidate = 0;
		if (bufferedRead) {
			if (probeOffsets[i] < readOffset || probeOffsets[i] > readOffset + readSize - sizeof(candidate)) continue;
			memcpy(&candidate, &buf[probeOffsets[i] - readOffset], sizeof(candidate));
			candidate = UNSIGN_PTR(candidate);
		} else {
			uint64_t address = 0;
			if (!IOSurface_target_address(surfaceSendRight, probeOffsets[i], &address)) continue;
			candidate = IOSurface_read_ptr(address);
		}
		if (IOSurface_object_is_surface(candidate)) return candidate;
	}
	errno = EFAULT;
	return 0;
}
uint64_t IOSurface_get_ranges(uint64_t surface)
{
	uint64_t offset = koffsetof(IOSurface, ranges);
	uint64_t address = 0;
	if (!offset || !IOSurface_target_address(surface, offset, &address)) {
		if (!offset) errno = EFAULT;
		return 0;
	}
	return IOSurface_read_ptr(address);
}

int IOSurface_set_ranges(uint64_t surface, uint64_t ranges)
{
	uint64_t offset = koffsetof(IOSurface, ranges);
	uint64_t address = 0;
	if (!offset || !IOSurface_target_address(surface, offset, &address)) {
		if (!offset) errno = EFAULT;
		return -1;
	}
	return IOSurface_write(address, &ranges, sizeof(ranges));
}

uint64_t IOSurface_get_memoryDescriptor(uint64_t surface)
{
	uint64_t offset = koffsetof(IOSurface, memoryDescriptor);
	uint64_t address = 0;
	if (!offset || !IOSurface_target_address(surface, offset, &address)) {
		if (!offset) errno = EFAULT;
		return 0;
	}
	return IOSurface_read_ptr(address);
}

uint64_t IOMemoryDescriptor_get_ranges(uint64_t memoryDescriptor)
{
	uint64_t address = 0;
	return IOSurface_target_address(memoryDescriptor, 0x60, &address) ? IOSurface_read_ptr(address) : 0;
}

int IOMemoryDescriptor_set_ranges(uint64_t memoryDescriptor, uint64_t ranges)
{
	uint64_t address = 0;
	if (!IOSurface_target_address(memoryDescriptor, 0x60, &address)) return -1;
	return IOSurface_write(address, &ranges, sizeof(ranges));
}

uint64_t IOMemorydescriptor_get_size(uint64_t memoryDescriptor)
{
	uint64_t value = 0;
	uint64_t address = 0;
	return IOSurface_target_address(memoryDescriptor, 0x50, &address) && IOSurface_read_u64(address, &value) ? value : 0;
}

int IOMemoryDescriptor_set_size(uint64_t memoryDescriptor, uint64_t size)
{
	uint64_t address = 0;
	if (!IOSurface_target_address(memoryDescriptor, 0x50, &address)) return -1;
	return IOSurface_write(address, &size, sizeof(size));
}

int IOMemoryDescriptor_set_wired(uint64_t memoryDescriptor, bool wired)
{
	uint8_t value = wired ? 1 : 0;
	uint64_t address = 0;
	if (!IOSurface_target_address(memoryDescriptor, 0x88, &address)) return -1;
	return IOSurface_write(address, &value, sizeof(value));
}

uint32_t IOMemoryDescriptor_get_flags(uint64_t memoryDescriptor)
{
	uint32_t value = 0;
	uint64_t address = 0;
	return IOSurface_target_address(memoryDescriptor, 0x20, &address) && IOSurface_read_u32(address, &value) ? value : 0;
}

int IOMemoryDescriptor_set_flags(uint64_t memoryDescriptor, uint32_t flags)
{
	uint64_t address = 0;
	if (!IOSurface_target_address(memoryDescriptor, 0x20, &address)) return -1;
	return IOSurface_write(address, &flags, sizeof(flags));
}

int IOMemoryDescriptor_set_memRef(uint64_t memoryDescriptor, uint64_t memRef)
{
	uint64_t address = 0;
	if (!IOSurface_target_address(memoryDescriptor, 0x28, &address)) return -1;
	return IOSurface_write(address, &memRef, sizeof(memRef));
}

uint64_t IOSurface_get_rangeCount(uint64_t surface)
{
	uint64_t offset = koffsetof(IOSurface, rangeCount);
	uint32_t value = 0;
	uint64_t address = 0;
	if (!offset) {
		errno = EFAULT;
		return 0;
	}
	return IOSurface_target_address(surface, offset, &address) && IOSurface_read_u32(address, &value) ? value : 0;
}

int IOSurface_set_rangeCount(uint64_t surface, uint32_t rangeCount)
{
	uint64_t offset = koffsetof(IOSurface, rangeCount);
	uint64_t address = 0;
	if (!offset) {
		errno = EFAULT;
		return -1;
	}
	if (!IOSurface_target_address(surface, offset, &address)) return -1;
	return IOSurface_write(address, &rangeCount, sizeof(rangeCount));
}

uint64_t IOSurface_port_getSendRight(mach_port_t surfaceMachPort)
{
	errno = 0;
	if (!MACH_PORT_VALID(surfaceMachPort)) {
		errno = EINVAL;
		return 0;
	}
	uint64_t surfaceSendRight = task_get_ipc_port_kobject(task_self(), surfaceMachPort);
	if (!surfaceSendRight) {
		errno = EFAULT;
		return 0;
	}
	uint64_t objectOffset = koffsetof(IOMachPort, object);
	if (!objectOffset) {
		errno = EFAULT;
		return 0;
	}
	if (objectOffset > 0x100 - sizeof(uint64_t)) {
		errno = ERANGE;
		return 0;
	}
	uint64_t zoneSize = objectOffset + sizeof(uint64_t);
	if (gPrimitives.krwMinSafeReadSize > 0x8) {
		uint8_t buf[0x100];
		uint64_t readSize = gPrimitives.krwMinSafeReadSize;
		if (readSize < sizeof(uint64_t) || readSize > zoneSize || readSize > sizeof(buf)) {
			errno = ERANGE;
			return 0;
		}
		uint64_t readOffset = zoneSize - readSize;
		uint64_t readAddress = 0;
		if (readOffset > objectOffset || !IOSurface_target_address(surfaceSendRight, readOffset, &readAddress)) return 0;
		if (!IOSurface_read_bytes(readAddress, buf, (size_t)readSize)) return 0;
		uint64_t value = 0;
		memcpy(&value, &buf[objectOffset - readOffset], sizeof(value));
		surfaceSendRight = UNSIGN_PTR(value);
	} else {
		uint64_t address = 0;
		if (!IOSurface_target_address(surfaceSendRight, objectOffset, &address)) return 0;
		surfaceSendRight = IOSurface_read_ptr(address);
	}
	if (!IOSurface_kernel_pointer(surfaceSendRight)) {
		errno = EFAULT;
		return 0;
	}
	return surfaceSendRight;
}

static mach_port_t IOSurface_map_getSurfacePort(uint64_t magic, uint32_t cacheMode)
{
	NSMutableDictionary *properties = [@{
		(__bridge NSString *)kIOSurfaceWidth : @120,
		(__bridge NSString *)kIOSurfaceHeight : @120,
		(__bridge NSString *)kIOSurfaceBytesPerElement : @4,
	} mutableCopy];
	if (!properties) {
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}
	if (cacheMode != 0) {
		properties[(__bridge NSString *)kIOSurfaceCacheMode] = @(cacheMode);
	}
	IOSurfaceRef surfaceRef = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
	if (!surfaceRef) {
		errno = EIO;
		return MACH_PORT_NULL;
	}
	void *baseAddress = IOSurfaceGetBaseAddress(surfaceRef);
	if (!baseAddress) {
		IOSurfaceDecrementUseCount(surfaceRef);
		CFRelease(surfaceRef);
		errno = EFAULT;
		return MACH_PORT_NULL;
	}
	memcpy(baseAddress, &magic, sizeof(magic));
	mach_port_t port = IOSurfaceCreateMachPort(surfaceRef);
	IOSurfaceDecrementUseCount(surfaceRef);
	CFRelease(surfaceRef);
	if (!MACH_PORT_VALID(port)) {
		errno = EIO;
		return MACH_PORT_NULL;
	}
	return port;
}

struct IOSurfaceMapCleanup {
	uint64_t descriptor;
	uint64_t originalRanges;
	uint64_t *fakeRanges;
};

struct IOSurfaceMapSnapshot {
	uint64_t ranges;
	uint64_t rangeValues[2];
	uint64_t size;
	uint64_t descriptor18;
	uint64_t descriptor70;
	uint64_t descriptor90;
	uint64_t memRef;
	uint32_t flags;
	uint8_t wired;
};

static struct IOSurfaceMapCleanup *gMapCleanups;
static size_t gMapCleanupCount;

static bool IOSurface_map_read_field(uint64_t descriptor, uint64_t offset, void *value, size_t size)
{
	uint64_t address = 0;
	return IOSurface_target_address(descriptor, offset, &address) && IOSurface_read_bytes(address, value, size);
}

static int IOSurface_map_write_field(uint64_t descriptor, uint64_t offset, const void *value, size_t size)
{
	uint64_t address = 0;
	if (!IOSurface_target_address(descriptor, offset, &address)) return -1;
	return IOSurface_write(address, value, size);
}

static bool IOSurface_map_capture(uint64_t descriptor, struct IOSurfaceMapSnapshot *snapshot)
{
	if (!snapshot) {
		errno = EINVAL;
		return false;
	}
	memset(snapshot, 0, sizeof(*snapshot));
	snapshot->ranges = IOMemoryDescriptor_get_ranges(descriptor);
	if (!snapshot->ranges) {
		if (!errno) errno = EFAULT;
		return false;
	}
	if ((gPrimitives.krwMinSafeReadSize <= 0x10 &&
	     !IOSurface_read_bytes(snapshot->ranges, snapshot->rangeValues, sizeof(snapshot->rangeValues))) ||
	    !IOSurface_map_read_field(descriptor, 0x50, &snapshot->size, sizeof(snapshot->size)) ||
	    !IOSurface_map_read_field(descriptor, 0x18, &snapshot->descriptor18, sizeof(snapshot->descriptor18)) ||
	    !IOSurface_map_read_field(descriptor, 0x70, &snapshot->descriptor70, sizeof(snapshot->descriptor70)) ||
	    !IOSurface_map_read_field(descriptor, 0x90, &snapshot->descriptor90, sizeof(snapshot->descriptor90)) ||
	    !IOSurface_map_read_field(descriptor, 0x28, &snapshot->memRef, sizeof(snapshot->memRef)) ||
	    !IOSurface_map_read_field(descriptor, 0x20, &snapshot->flags, sizeof(snapshot->flags)) ||
	    !IOSurface_map_read_field(descriptor, 0x88, &snapshot->wired, sizeof(snapshot->wired))) {
		return false;
	}
	return true;
}

static bool IOSurface_map_restore(uint64_t descriptor, const struct IOSurfaceMapSnapshot *snapshot)
{
	bool restored = true;
	if (IOMemoryDescriptor_set_ranges(descriptor, snapshot->ranges) != 0) restored = false;
	if (gPrimitives.krwMinSafeReadSize <= 0x10 &&
	    IOSurface_write(snapshot->ranges, snapshot->rangeValues, sizeof(snapshot->rangeValues)) != 0) restored = false;
	if (IOSurface_map_write_field(descriptor, 0x50, &snapshot->size, sizeof(snapshot->size)) != 0) restored = false;
	if (IOSurface_map_write_field(descriptor, 0x18, &snapshot->descriptor18, sizeof(snapshot->descriptor18)) != 0) restored = false;
	if (IOSurface_map_write_field(descriptor, 0x70, &snapshot->descriptor70, sizeof(snapshot->descriptor70)) != 0) restored = false;
	if (IOSurface_map_write_field(descriptor, 0x90, &snapshot->descriptor90, sizeof(snapshot->descriptor90)) != 0) restored = false;
	if (IOMemoryDescriptor_set_memRef(descriptor, snapshot->memRef) != 0) restored = false;
	if (IOMemoryDescriptor_set_flags(descriptor, snapshot->flags) != 0) restored = false;
	if (IOMemoryDescriptor_set_wired(descriptor, snapshot->wired != 0) != 0) restored = false;
	return restored;
}

int IOSurface_map_withCacheMode(uint64_t pa, uint64_t size, void **uaddr, uint32_t cacheMode)
{
	errno = 0;
	if (!uaddr || !size) {
		errno = EINVAL;
		return -1;
	}
	*uaddr = NULL;
	if (pa > UINT64_MAX - size) {
		errno = EOVERFLOW;
		return -1;
	}

	mach_port_t surfaceMachPort = MACH_PORT_NULL;
	uint64_t surfaceSendRight = 0;
	uint64_t surface = 0;
	uint64_t desc = 0;
	uint64_t *fakeRanges = NULL;
	uint64_t fakeRangesKaddr = 0;
	IOSurfaceRef mappedSurfaceRef = NULL;
	struct IOSurfaceMapSnapshot snapshot = {0};
	bool snapshotReady = false;
	bool modificationsStarted = false;
	bool fakeRangePath = gPrimitives.krwMinSafeReadSize > 0x10;

	surfaceMachPort = IOSurface_map_getSurfacePort(1337, cacheMode);
	if (!MACH_PORT_VALID(surfaceMachPort)) {
		if (!errno) errno = EIO;
		goto fail;
	}
	surfaceSendRight = IOSurface_port_getSendRight(surfaceMachPort);
	if (!surfaceSendRight) goto fail;
	surface = IOSurfaceSendRight_get_surface(surfaceSendRight);
	if (!IOSurface_kernel_pointer(surface)) goto fail;
	desc = IOSurface_get_memoryDescriptor(surface);
	if (!IOSurface_kernel_pointer(desc)) goto fail;
	if (!IOSurface_map_capture(desc, &snapshot)) goto fail;
	snapshotReady = true;

	if (fakeRangePath) {
		if (gMapCleanupCount >= SIZE_MAX / sizeof(*gMapCleanups)) {
			errno = EOVERFLOW;
			goto fail;
		}
		fakeRanges = malloc(2 * sizeof(uint64_t));
		if (!fakeRanges) {
			errno = ENOMEM;
			goto fail;
		}
		fakeRanges[0] = pa;
		fakeRanges[1] = size;

		uint64_t fakeRangesPa = vtophys(ttep_self(), (uint64_t)fakeRanges);
		if (!fakeRangesPa) {
			if (!errno) errno = EFAULT;
			goto fail;
		}
		fakeRangesKaddr = phystokv(fakeRangesPa);
		if (!fakeRangesKaddr) {
			if (!errno) errno = EFAULT;
			goto fail;
		}

		size_t newCleanupCount = gMapCleanupCount + 1;
		struct IOSurfaceMapCleanup *newCleanups = realloc(gMapCleanups, newCleanupCount * sizeof(*gMapCleanups));
		if (!newCleanups) {
			errno = ENOMEM;
			goto fail;
		}
		gMapCleanups = newCleanups;

		modificationsStarted = true;
		if (IOMemoryDescriptor_set_ranges(desc, fakeRangesKaddr) != 0) goto fail;
	} else {
		uint64_t secondRangeAddress = 0;
		if (!IOSurface_target_address(snapshot.ranges, sizeof(uint64_t), &secondRangeAddress)) goto fail;
		modificationsStarted = true;
		if (IOSurface_write(snapshot.ranges, &pa, sizeof(pa)) != 0 ||
		    IOSurface_write(secondRangeAddress, &size, sizeof(size)) != 0) goto fail;
	}

	if (IOMemoryDescriptor_set_size(desc, size) != 0) goto fail;
	uint64_t zero = 0;
	if (IOSurface_map_write_field(desc, 0x70, &zero, sizeof(zero)) != 0 ||
	    IOSurface_map_write_field(desc, 0x18, &zero, sizeof(zero)) != 0 ||
	    IOSurface_map_write_field(desc, 0x90, &zero, sizeof(zero)) != 0) goto fail;
	if (IOMemoryDescriptor_set_wired(desc, true) != 0) goto fail;
	uint32_t flags = (snapshot.flags & ~0x410) | 0x20;
	if (IOMemoryDescriptor_set_flags(desc, flags) != 0) goto fail;
	if (IOMemoryDescriptor_set_memRef(desc, 0) != 0) goto fail;

	mappedSurfaceRef = IOSurfaceLookupFromMachPort(surfaceMachPort);
	if (!mappedSurfaceRef) {
		errno = EIO;
		goto fail;
	}
	*uaddr = IOSurfaceGetBaseAddress(mappedSurfaceRef);
	if (!*uaddr) {
		errno = EFAULT;
		goto fail;
	}

/*********************** roothide specific **************************************/
    if (@available(iOS 17.0, *)) {
        // Use the mapping returned by IOSurface directly on iOS 17, matching
        // upstream Dopamine. Keep the historical RootHide alias for older iOS.
    } else {
        vm_prot_t cur_prot, max_prot;
        kern_return_t kr = vm_remap(mach_task_self(), (vm_address_t *)uaddr, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)*uaddr, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
			errno = EIO;
			goto fail;
		}
    }
/*********************************************************************************/

	if (fakeRangePath) {
		gMapCleanups[gMapCleanupCount++] = (struct IOSurfaceMapCleanup){ desc, snapshot.ranges, fakeRanges };
		fakeRanges = NULL;
	}
	return 0;

fail: {
	int savedError = errno ? errno : EIO;
	bool restored = true;
	if (snapshotReady && modificationsStarted) restored = IOSurface_map_restore(desc, &snapshot);
	if (mappedSurfaceRef) CFRelease(mappedSurfaceRef);
	if (restored) {
		free(fakeRanges);
		if (MACH_PORT_VALID(surfaceMachPort)) mach_port_deallocate(mach_task_self(), surfaceMachPort);
	} else {
		// Keep the fake range storage and send right alive if rollback failed.
		fakeRanges = NULL;
	}
	*uaddr = NULL;
	errno = savedError;
	return -1;
}
}

int IOSurface_map(uint64_t pa, uint64_t size, void **uaddr)
{
	return IOSurface_map_withCacheMode(pa, size, uaddr, 0);
}

void IOSurface_map_cleanup(void)
{
	size_t remaining = 0;
	int cleanupError = 0;
	for (size_t i = 0; i < gMapCleanupCount; i++) {
		struct IOSurfaceMapCleanup cleanup = gMapCleanups[i];
		if (IOMemoryDescriptor_set_ranges(cleanup.descriptor, cleanup.originalRanges) == 0) {
			free(cleanup.fakeRanges);
		} else {
			if (!cleanupError) cleanupError = errno ? errno : EIO;
			gMapCleanups[remaining++] = cleanup;
		}
	}
	gMapCleanupCount = remaining;
	if (!gMapCleanupCount) {
		free(gMapCleanups);
		gMapCleanups = NULL;
	}
	if (cleanupError) errno = cleanupError;
}

static mach_port_t IOSurface_kalloc_getSurfacePort(uint64_t size)
{
	errno = 0;
	if (size < 2 * sizeof(uint64_t)) {
		errno = EINVAL;
		return MACH_PORT_NULL;
	}
	if ((uint64_t)(size_t)size != size) {
		errno = EOVERFLOW;
		return MACH_PORT_NULL;
	}
	uint64_t allocSize = 0x10;
	uint64_t *addressRangesBuf = (uint64_t *)malloc((size_t)size);
	if (!addressRangesBuf) {
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}
	memset(addressRangesBuf, 0, (size_t)size);
	void *allocation = malloc((size_t)allocSize);
	if (!allocation) {
		free(addressRangesBuf);
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}
	addressRangesBuf[0] = (uint64_t)allocation;
	addressRangesBuf[1] = allocSize;
	NSData *addressRanges = [NSData dataWithBytes:addressRangesBuf length:(NSUInteger)size];
	free(addressRangesBuf);
	if (!addressRanges) {
		free(allocation);
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}

	IOSurfaceRef surfaceRef = IOSurfaceCreate((__bridge CFDictionaryRef)@{
		@"IOSurfaceAllocSize" : @(allocSize),
		@"IOSurfaceAddressRanges" : addressRanges,
	});
	if (!surfaceRef) {
		free(allocation);
		errno = EIO;
		return MACH_PORT_NULL;
	}
	mach_port_t port = IOSurfaceCreateMachPort(surfaceRef);
	IOSurfaceDecrementUseCount(surfaceRef);
	CFRelease(surfaceRef);
	if (!MACH_PORT_VALID(port)) {
		free(allocation);
		errno = EIO;
		return MACH_PORT_NULL;
	}
	return port;
}

static mach_port_t IOSurface_kalloc_getSurfacePort_16up(uint64_t size)
{
	errno = 0;
	if (!size) {
		errno = EINVAL;
		return MACH_PORT_NULL;
	}
	if (size > UINT64_MAX - 0xf) {
		errno = EOVERFLOW;
		return MACH_PORT_NULL;
	}
	uint64_t rangesAlignedSize64 = ((size + 0xf) & ~(uint64_t)0xf);
	if (rangesAlignedSize64 < 2 * sizeof(uint64_t) ||
	    (uint64_t)(size_t)rangesAlignedSize64 != rangesAlignedSize64 ||
	    rangesAlignedSize64 > LONG_MAX) {
		errno = EOVERFLOW;
		return MACH_PORT_NULL;
	}
	size_t rangesAlignedSize = (size_t)rangesAlignedSize64;

	static vm_size_t dummyPageSize = 0x4000;
	static vm_address_t dummyPage = 0;
	if (dummyPage == 0) {
		vm_address_t allocatedPage = 0;
		kern_return_t kr = vm_allocate(mach_task_self(), &allocatedPage, dummyPageSize, VM_FLAGS_ANYWHERE);
		if (kr != KERN_SUCCESS || !allocatedPage) {
			errno = EIO;
			return MACH_PORT_NULL;
		}
		dummyPage = allocatedPage;
	}

	uint64_t *userspaceRanges = (uint64_t *)malloc(rangesAlignedSize);
	if (!userspaceRanges) {
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}
	for (size_t i = 0; i < rangesAlignedSize / sizeof(uint64_t); i += 2) {
		userspaceRanges[i] = dummyPage;
		userspaceRanges[i + 1] = dummyPageSize;
	}

	CFDataRef userspaceRangesData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)userspaceRanges, rangesAlignedSize);
	free(userspaceRanges);
	if (!userspaceRangesData) {
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}

	CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
	if (!dict) {
		CFRelease(userspaceRangesData);
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}
	CFNumberRef dummyPageSizeNum = CFNUM64(dummyPageSize);
	if (!dummyPageSizeNum) {
		CFRelease(userspaceRangesData);
		CFRelease(dict);
		errno = ENOMEM;
		return MACH_PORT_NULL;
	}
	CFDictionarySetValue(dict, CFSTR("IOSurfaceAllocSize"), dummyPageSizeNum);
	CFDictionarySetValue(dict, CFSTR("IOSurfaceAddressRanges"), userspaceRangesData);

	IOSurfaceRef surfaceRef = IOSurfaceCreate(dict);
	mach_port_t port = surfaceRef ? IOSurfaceCreateMachPort(surfaceRef) : MACH_PORT_NULL;
	if (surfaceRef) {
		IOSurfaceDecrementUseCount(surfaceRef);
		CFRelease(surfaceRef);
	}
	CFRelease(userspaceRangesData);
	CFRelease(dummyPageSizeNum);
	CFRelease(dict);
	if (!MACH_PORT_VALID(port)) {
		errno = EIO;
		return MACH_PORT_NULL;
	}
	return port;
}

#define IOSURFACE_KALLOC_MAX_ATTEMPTS 256

static bool IOSurface_kalloc_clear_ranges(uint64_t surface, uint64_t ranges, uint32_t rangeCount, bool *safeToRelease)
{
	if (!safeToRelease) {
		errno = EINVAL;
		return false;
	}
	*safeToRelease = true;
	if (IOSurface_set_ranges(surface, 0) == 0 && IOSurface_set_rangeCount(surface, 0) == 0) return true;

	int savedError = errno ? errno : EIO;
	bool rangesRestored = IOSurface_set_ranges(surface, ranges) == 0;
	bool countRestored = IOSurface_set_rangeCount(surface, rangeCount) == 0;
	if (!rangesRestored || !countRestored) *safeToRelease = false;
	errno = savedError;
	return false;
}

static uint64_t IOSurface_kalloc_16up(uint64_t size, bool leak)
{
	errno = 0;
	if (!size || size > 0x10000) {
		errno = EINVAL;
		return 0;
	}

	for (unsigned attempt = 0; attempt < IOSURFACE_KALLOC_MAX_ATTEMPTS; attempt++) {
		mach_port_t surfaceMachPort = IOSurface_kalloc_getSurfacePort_16up(size);
		if (!MACH_PORT_VALID(surfaceMachPort)) return 0;

		uint64_t surfaceSendRight = IOSurface_port_getSendRight(surfaceMachPort);
		if (!surfaceSendRight) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		uint64_t surface = IOSurfaceSendRight_get_surface(surfaceSendRight);
		if (!surface) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		uint64_t va = IOSurface_get_ranges(surface);
		if (!va) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		uint64_t rangeCountValue = IOSurface_get_rangeCount(surface);
		if (!rangeCountValue || rangeCountValue > UINT32_MAX) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		uint32_t rangeCount = (uint32_t)rangeCountValue;
		uint64_t vaSize = (uint64_t)rangeCount * 0x10;

		if (vaSize < size) {
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			continue;
		}

		if (leak) {
			bool safeToRelease = true;
			if (!IOSurface_kalloc_clear_ranges(surface, va, rangeCount, &safeToRelease)) {
				int savedError = errno ? errno : EIO;
				if (safeToRelease) mach_port_deallocate(mach_task_self(), surfaceMachPort);
				errno = savedError;
				return 0;
			}
		}

		return va;
	}
	errno = ENOMEM;
	return 0;
}

uint64_t IOSurface_kalloc(uint64_t size, bool leak)
{
	errno = 0;
	if (!size) {
		errno = EINVAL;
		return 0;
	}
	if (@available(iOS 16.0, *)) {
		return IOSurface_kalloc_16up(size, leak);
	}

	if (size > UINT64_MAX - 0x10000) {
		errno = EOVERFLOW;
		return 0;
	}
	uint64_t allocSize = size > 0x10000 ? size : 0x10000;
	for (unsigned attempt = 0; attempt < IOSURFACE_KALLOC_MAX_ATTEMPTS; attempt++) {
		mach_port_t surfaceMachPort = IOSurface_kalloc_getSurfacePort(allocSize);
		if (!MACH_PORT_VALID(surfaceMachPort)) return 0;
		uint64_t surfaceSendRight = IOSurface_port_getSendRight(surfaceMachPort);
		if (!surfaceSendRight) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		uint64_t surface = IOSurfaceSendRight_get_surface(surfaceSendRight);
		if (!surface) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		uint64_t va = IOSurface_get_ranges(surface);
		if (!va) {
			int savedError = errno ? errno : EFAULT;
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = savedError;
			return 0;
		}
		if (va > UINT64_MAX - allocSize) {
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			errno = EOVERFLOW;
			return 0;
		}

		errno = 0;
		if (kvtophys(va + allocSize) != 0) {
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			continue;
		}
		uint64_t result = va + (allocSize - size);

		if (leak) {
			uint64_t rangeCountValue = IOSurface_get_rangeCount(surface);
			if (!rangeCountValue || rangeCountValue > UINT32_MAX) {
				int savedError = errno ? errno : EFAULT;
				mach_port_deallocate(mach_task_self(), surfaceMachPort);
				errno = savedError;
				return 0;
			}
			bool safeToRelease = true;
			if (!IOSurface_kalloc_clear_ranges(surface, va, (uint32_t)rangeCountValue, &safeToRelease)) {
				int savedError = errno ? errno : EIO;
				if (safeToRelease) mach_port_deallocate(mach_task_self(), surfaceMachPort);
				errno = savedError;
				return 0;
			}
		}
		return result;
	}
	errno = ENOMEM;
	return 0;
}

int IOSurface_kalloc_global(uint64_t *addr, uint64_t size)
{
	if (!addr) {
		errno = EINVAL;
		return -1;
	}
	*addr = 0;
	uint64_t alloc = IOSurface_kalloc(size, true);
	if (alloc != 0) {
		*addr = alloc;
		return 0;
	}
	return -1;
}

int IOSurface_kalloc_local(uint64_t *addr, uint64_t size)
{
	if (!addr) {
		errno = EINVAL;
		return -1;
	}
	*addr = 0;
	uint64_t alloc = IOSurface_kalloc(size, false);
	if (alloc != 0) {
		*addr = alloc;
		return 0;
	}
	return -1;
}

void libjailbreak_IOSurface_primitives_init(void)
{
	IOSurfaceRef surfaceRef = IOSurfaceCreate((__bridge CFDictionaryRef)@{
		(__bridge NSString *)kIOSurfaceWidth : @120,
		(__bridge NSString *)kIOSurfaceHeight : @120,
		(__bridge NSString *)kIOSurfaceBytesPerElement : @4,
	});
	if (!surfaceRef) {
		char execPath[PATH_MAX];
		uint32_t execPathSize = sizeof(execPath);
		if (_NSGetExecutablePath(execPath, &execPathSize) != 0) execPath[0] = '\0';
		printf("Failed to initialize IOSurface primitives, add \"IOSurfaceRootUserClient\" to the \"com.apple.security.exception.iokit-user-client-class\" dictionary of the entitlements from \"%s\" to fix this. Due to this, the kalloc, kmap and kcall primitives will not work.\n", execPath);
		return;
	}
	CFRelease(surfaceRef);

	gPrimitives.kmap = IOSurface_map;
	gPrimitives.kalloc_global = IOSurface_kalloc_global;
	gPrimitives.kalloc_local  = IOSurface_kalloc_local;
}
