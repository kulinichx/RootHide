#include "translation.h"
#include "primitives.h"
#include "kernel.h"
#include "info.h"
#include <errno.h>
#include <stdio.h>

struct tt_level arm_tt_level[4];

// Address translation physical <-> virtual

#define PTOV_TABLE_SIZE 8
uint64_t phystokv(uint64_t pa)
{
	errno = 0;
	struct ptov_table_entry {
		uint64_t pa;
		uint64_t va;
		uint64_t len;
	} ptov_table[PTOV_TABLE_SIZE] = {0};
	uint64_t ptov_table_addr = ksymbol(ptov_table);
	if (ptov_table_addr) {
		if (kreadbuf(ptov_table_addr, &ptov_table[0], sizeof(ptov_table)) != 0) {
			errno = EIO;
			return 0;
		}

		for (uint64_t i = 0; (i < PTOV_TABLE_SIZE) && (ptov_table[i].len != 0); i++) {
			if (pa >= ptov_table[i].pa) {
				uint64_t entryOffset = pa - ptov_table[i].pa;
				if (entryOffset < ptov_table[i].len) {
					if (ptov_table[i].va > UINT64_MAX - entryOffset) {
						errno = EOVERFLOW;
						return 0;
					}
					uint64_t va = ptov_table[i].va + entryOffset;
					if (va == 0) {
						errno = EFAULT;
						return 0;
					}
					return va;
				}
			}
		}
	}

	uint64_t papt_ranges_addr = ksymbol(libsptm_papt_ranges);
	uint64_t n_papt_ranges_addr = ksymbol(libsptm_n_papt_ranges);
	if (papt_ranges_addr && n_papt_ranges_addr) {
		uint64_t papt_table = 0;
		uint64_t papt_table_n_ptr = 0;
		if (kreadbuf(papt_ranges_addr, &papt_table, sizeof(papt_table)) != 0 ||
		    kreadbuf(n_papt_ranges_addr, &papt_table_n_ptr, sizeof(papt_table_n_ptr)) != 0) {
			errno = EIO;
			return 0;
		}
		papt_table = UNSIGN_PTR(papt_table);
		papt_table_n_ptr = UNSIGN_PTR(papt_table_n_ptr);
		if (!papt_table || !papt_table_n_ptr) {
			errno = EFAULT;
			return 0;
		}

		uint32_t papt_table_n = 0;
		if (kreadbuf(papt_table_n_ptr, &papt_table_n, sizeof(papt_table_n)) != 0) {
			errno = EIO;
			return 0;
		}
		if (papt_table_n == 0 || papt_table_n > 64) {
			errno = EFAULT;
			return 0;
		}

		struct sptm_papt_entry {
			uint64_t paddr_start;
			uint64_t papt_start;
			uint64_t num_mappings;
		} sptm_papt_table[64] = {0};
		if (kreadbuf(papt_table, &sptm_papt_table[0], (size_t)papt_table_n * sizeof(struct sptm_papt_entry)) != 0) {
			errno = EIO;
			return 0;
		}

		uint64_t page_size = vm_real_kernel_page_size ? vm_real_kernel_page_size : 0x4000;
		for (uint32_t i = 0; i < papt_table_n; i++) {
			struct sptm_papt_entry *curEntry = &sptm_papt_table[i];
			if (curEntry->num_mappings > UINT64_MAX / page_size) {
				errno = EOVERFLOW;
				return 0;
			}
			uint64_t len = curEntry->num_mappings * page_size;
			if (pa >= curEntry->paddr_start) {
				uint64_t entryOffset = pa - curEntry->paddr_start;
				if (entryOffset < len) {
					if (curEntry->papt_start > UINT64_MAX - entryOffset) {
						errno = EOVERFLOW;
						return 0;
					}
					uint64_t va = curEntry->papt_start + entryOffset;
					if (va == 0) {
						errno = EFAULT;
						return 0;
					}
					return va;
				}
			}
		}

		errno = EFAULT;
		return 0;
	}

	uint64_t physBase = kconstant(physBase);
	uint64_t virtBase = kconstant(virtBase);
	uint64_t physSize = kconstant(physSize);
	if (physBase && virtBase && !ksymbol(SPTMArgs)) {
		if (pa >= physBase) {
			uint64_t offset = pa - physBase;
			if (!physSize || offset < physSize) {
				if (virtBase > UINT64_MAX - offset) {
					errno = EOVERFLOW;
					return 0;
				}
				uint64_t va = virtBase + offset;
				if (va != 0) return va;
				errno = EFAULT;
				return 0;
			}
		}
	}

	errno = EFAULT;
	return 0;
}

uint64_t vtophys_lvl(uint64_t tte_ttep, uint64_t va, uint64_t *leaf_level, uint64_t *leaf_tte_ttep)
{
	errno = 0;
	const uint64_t ROOT_LEVEL = PMAP_TT_L1_LEVEL;
	const uint64_t LEAF_LEVEL = *leaf_level;

	uint64_t pa = 0;

	bool physical = !(bool)(tte_ttep & 0xf000000000000000);

	for (uint64_t curLevel = ROOT_LEVEL; curLevel <= LEAF_LEVEL; curLevel++) {
		if (curLevel > PMAP_TT_L3_LEVEL) {
			errno = 1041;
			return 0;
		}

		struct tt_level *lvlp = &arm_tt_level[curLevel];
		uint64_t tteIndex = (va & lvlp->indexMask) >> lvlp->shift;
		uint64_t tteEntry = 0;
		if (physical) {
			uint64_t tte_pa = tte_ttep + (tteIndex * sizeof(uint64_t));
			tteEntry = physread64(tte_pa);
			if (leaf_tte_ttep) *leaf_tte_ttep = tte_pa;
			if (leaf_level) *leaf_level = curLevel;
		}
		else if (gPrimitives.kreadbuf && !physical) {
			uint64_t tte_va = tte_ttep + (tteIndex * sizeof(uint64_t));
			tteEntry = kread64(tte_va);
			if (leaf_tte_ttep) *leaf_tte_ttep = tte_va;
			if (leaf_level) *leaf_level = curLevel;
		}
		else {
			printf("WARNING: Failed %s translation, no function to do it.\n", physical ? "physical" : "virtual");
			errno = 1043;
			return 0;
		}

		if ((tteEntry & lvlp->validMask) != lvlp->validMask) {
			errno = 1042;
			return 0;
		}

		if ((tteEntry & lvlp->typeMask) == lvlp->typeBlock) {
			// Found block mapping, no matter what level we are in, this is the end
			return ((tteEntry & ARM_TTE_PA_MASK & ~lvlp->offMask) | (va & lvlp->offMask));
		}

		if (physical) {
			tte_ttep = tteEntry & ARM_TTE_TABLE_MASK;
		}
		else {
			tte_ttep = phystokv(tteEntry & ARM_TTE_TABLE_MASK);
		}
	}

	// If we end up here, it means we did not find a block mapping
	// In this case, return the last page table address we traversed
	return tte_ttep;
}

uint64_t vtophys(uint64_t tte_ttep, uint64_t va)
{
	uint64_t level = PMAP_TT_L3_LEVEL;
	return vtophys_lvl(tte_ttep, va, &level, NULL);
}

uint64_t kvtophys(uint64_t va)
{
	return vtophys(kconstant(cpuTTEP), va);
}

void libjailbreak_translation_init(void)
{
	// A9+: Kernel uses 16K pages
	if (vm_real_kernel_page_size == 0x4000) {
		arm_tt_level[0] = (struct tt_level){
			.offMask = ARM_16K_TT_L0_OFFMASK,
			.shift = ARM_16K_TT_L0_SHIFT,
			.indexMask = ARM_16K_TT_L0_INDEX_MASK,
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_BLOCK,
		};
		arm_tt_level[1] = (struct tt_level){
			.offMask = ARM_16K_TT_L1_OFFMASK,
			.shift = ARM_16K_TT_L1_SHIFT,
			.indexMask = kconstant(ARM_TT_L1_INDEX_MASK),
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_BLOCK,
		};
		arm_tt_level[2] = (struct tt_level){
			.offMask = ARM_16K_TT_L2_OFFMASK,
			.shift = ARM_16K_TT_L2_SHIFT,
			.indexMask = ARM_16K_TT_L2_INDEX_MASK,
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_BLOCK,
		};
		arm_tt_level[3] = (struct tt_level){
			.offMask = ARM_16K_TT_L3_OFFMASK,
			.shift = ARM_16K_TT_L3_SHIFT,
			.indexMask = ARM_16K_TT_L3_INDEX_MASK,
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_L3BLOCK,
		};
	}
	// A8: Kernel uses 4k pages
	else if (vm_real_kernel_page_size == 0x1000) {
		arm_tt_level[0] = (struct tt_level){
			.offMask = ARM_4K_TT_L0_OFFMASK,
			.shift = ARM_4K_TT_L0_SHIFT,
			.indexMask = ARM_4K_TT_L0_INDEX_MASK,
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_BLOCK,
		};
		arm_tt_level[1] = (struct tt_level){
			.offMask = ARM_4K_TT_L1_OFFMASK,
			.shift = ARM_4K_TT_L1_SHIFT,
			.indexMask = kconstant(ARM_TT_L1_INDEX_MASK),
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_BLOCK,
		};
		arm_tt_level[2] = (struct tt_level){
			.offMask = ARM_4K_TT_L2_OFFMASK,
			.shift = ARM_4K_TT_L2_SHIFT,
			.indexMask = ARM_4K_TT_L2_INDEX_MASK,
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_BLOCK,
		};
		arm_tt_level[3] = (struct tt_level){
			.offMask = ARM_4K_TT_L3_OFFMASK,
			.shift = ARM_4K_TT_L3_SHIFT,
			.indexMask = ARM_4K_TT_L3_INDEX_MASK,
			.validMask = ARM_TTE_VALID,
			.typeMask = ARM_TTE_TYPE_MASK,
			.typeBlock = ARM_TTE_TYPE_L3BLOCK,
		};
	}

	gPrimitives.phystokv = phystokv;
	gPrimitives.vtophys  = vtophys;
}
