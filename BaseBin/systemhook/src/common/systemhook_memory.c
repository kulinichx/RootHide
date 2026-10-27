#include "common.h"
#include <libjailbreak/hookd.h>
#include <libkern/OSCacheControl.h>

// systemhook-only memory helpers; launchdhook does not link hookd.
kern_return_t vm_allocate_nearby(vm_map_t target_task, vm_address_t from_area, vm_size_t from_area_size, vm_address_t *address, vm_size_t size, uint64_t limit)
{
	if (from_area != 0 && from_area_size > 0 && address) {
		// Make sure allocation is within limit for every single page in the area
		uint64_t realLimit = limit - (from_area_size / 2);

		for (uint64_t off = 0; off < realLimit; off += vm_page_size) {
			vm_address_t tmp = (from_area + from_area_size) + off;
			kern_return_t kr = vm_allocate(target_task, &tmp, size, VM_FLAGS_FIXED);
			if (kr == KERN_SUCCESS) {
				*address = tmp;
				return kr;
			}

			tmp = (from_area - size) - off;
			kr = vm_allocate(target_task, &tmp, size, VM_FLAGS_FIXED);
			if (kr == KERN_SUCCESS) {
				*address = tmp;
				return kr;
			}
		}
	}

	return KERN_NO_SPACE;
}

__attribute__((noinline, naked)) volatile void *get_tpidrr0_el0(void)
{
	asm("MRS X0, TPIDRRO_EL0");
	asm("RET");
}

kern_return_t litehook_hook_memory_hookd(void *target, void *source, size_t sourceSize)
{
	kern_return_t kr = hookd_hook(mach_task_self_, (uint64_t)target, source, sourceSize);
	if (kr == KERN_SUCCESS) {
		sys_icache_invalidate(target, sourceSize);
	}
	return kr;
}

kern_return_t mach_vm_protect_fixed(mach_port_name_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_maximum, vm_prot_t new_protection)
{
	kern_return_t rv;

	bool skipped = false;
	if (!skipped) {
		if ((new_protection & VM_PROT_EXECUTE) || (new_protection & VM_PROT_COPY)) {
			rv = hookd_vm_protect(task, address, size, set_maximum, new_protection);
		}
		else {
			rv = _kernelrpc_mach_vm_protect_trap(task, address, size, set_maximum, new_protection);
			if (rv == MACH_SEND_INVALID_DEST) {
				rv = _kernelrpc_mach_vm_protect(task, address, size, set_maximum, new_protection);
			}
		}
	}

	return rv;
}
