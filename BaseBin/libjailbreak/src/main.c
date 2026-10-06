#include "jbclient_xpc.h"
#include <stdlib.h>
#include "physrw.h"
#include "physrw_pte.h"
#include "primitives_IOSurface.h"
#include "info.h"
#include "translation.h"
#include "kcall_Fugu14.h"
#include "kcall_arm64.h"
#include <xpc/xpc.h>
#include "roothide_stage.h"

int jbclient_initialize_primitives_internal(bool physrwPTE)
{
	if (getuid() != 0) return -1;

	xpc_object_t xSystemInfo = NULL;
	roothide_stage_log("primitives.sysinfo.begin");
	int sysinfoResult = jbclient_root_get_sysinfo(&xSystemInfo);
	roothide_stage_log("primitives.sysinfo.end result=%d", sysinfoResult);
	if (sysinfoResult == 0) {
		roothide_stage_log("primitives.deserialize.begin");
		SYSTEM_INFO_DESERIALIZE(xSystemInfo);
		roothide_stage_log("primitives.deserialize.end");
		xpc_release(xSystemInfo);
		uint64_t asidPtr = 0;
		roothide_stage_log("primitives.physrw_handoff.begin single_pte=%d", physrwPTE);
		int handoffResult = jbclient_root_get_physrw(physrwPTE, &asidPtr);
		roothide_stage_log("primitives.physrw_handoff.end result=%d", handoffResult);
		if (handoffResult == 0) {
			if (physrwPTE) {
				libjailbreak_physrw_pte_init(true, asidPtr);
			}
			else {
				libjailbreak_physrw_init(true);
			}
			libjailbreak_translation_init();
			roothide_stage_log("primitives.translation.end");
			libjailbreak_IOSurface_primitives_init();
			roothide_stage_log("primitives.IOSurface.end");
			if (gPrimitives.kalloc_local) {
#ifdef __arm64e__
				if (jbinfo(usesPACBypass)) {
					jbclient_get_fugu14_kcall();
				}
#else
				arm64_kcall_init();
#endif
			}

			return 0;
		}
	}

	return -1;
}

int jbclient_initialize_primitives(void)
{
	return jbclient_initialize_primitives_internal(false);
}

// Used for supporting third party legacy software that still calls this function
int jbdInitPPLRW(void)
{
	return jbclient_initialize_primitives();
}
