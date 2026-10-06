#!/usr/bin/env python3
"""Host regressions for the physical-to-kernel-virtual translation contract.

The harness extracts phystokv() from the real source. It only tests failure
handling and arithmetic with fake kernel state; it does not validate device
page-table layouts or iOS compatibility.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def extract_function(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for position in range(opening, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[start:position + 1]
    raise ValueError(f"unclosed function: {signature}")


PREFIX = r"""
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define PTOV_TABLE_SIZE 8

struct {
    struct {
        uint64_t physBase;
        uint64_t virtBase;
        uint64_t physSize;
    } kernelConstant;
} gSystemInfo;

static uint64_t ptov_symbol = 0;
static uint64_t sptm_symbol = 0;
static uint64_t papt_ranges_symbol = 0;
static uint64_t n_papt_ranges_symbol = 0;
static uint64_t papt_table_addr = 0;
static uint64_t papt_table_n_addr = 0;
static uint32_t fake_papt_n = 0;
static uint64_t vm_real_kernel_page_size = 0x4000;
static int ptov_read_result = 0;
static int papt_read_result = 0;
struct fake_ptov_entry {
    uint64_t pa;
    uint64_t va;
    uint64_t len;
};
static struct fake_ptov_entry fake_ptov[8];
struct fake_papt_entry {
    uint64_t paddr_start;
    uint64_t papt_start;
    uint64_t num_mappings;
};
static struct fake_papt_entry fake_papt[8];

#define UNSIGN_PTR(value) (value)
#define kconstant(name) (gSystemInfo.kernelConstant.name)
#define ksymbol(name) (strcmp(#name, "ptov_table") == 0 ? ptov_symbol : \
    (strcmp(#name, "SPTMArgs") == 0 ? sptm_symbol : \
    (strcmp(#name, "libsptm_papt_ranges") == 0 ? papt_ranges_symbol : \
    (strcmp(#name, "libsptm_n_papt_ranges") == 0 ? n_papt_ranges_symbol : 0))))

int kreadbuf(uint64_t address, void *output, size_t size) {
    if (address == papt_ranges_symbol && size == sizeof(uint64_t)) {
        if (papt_read_result != 0) return -1;
        memcpy(output, &papt_table_addr, size);
        return 0;
    }
    if (address == n_papt_ranges_symbol && size == sizeof(uint64_t)) {
        if (papt_read_result != 0) return -1;
        memcpy(output, &papt_table_n_addr, size);
        return 0;
    }
    if (address == papt_table_n_addr && size == sizeof(uint32_t)) {
        if (papt_read_result != 0) return -1;
        memcpy(output, &fake_papt_n, size);
        return 0;
    }
    if (address == papt_table_addr && size == (size_t)fake_papt_n * sizeof(struct fake_papt_entry)) {
        if (papt_read_result != 0) return -1;
        memcpy(output, fake_papt, size);
        return 0;
    }
    if (ptov_read_result != 0 || address != ptov_symbol || size != sizeof(fake_ptov)) {
        return -1;
    }
    memcpy(output, fake_ptov, size);
    return 0;
}
"""

SUFFIX = r"""
int main(void) {
    gSystemInfo.kernelConstant.physBase = 0x100000;
    gSystemInfo.kernelConstant.virtBase = 0x8000000000;
    gSystemInfo.kernelConstant.physSize = 0x1000;
    sptm_symbol = 0;

    // The linear fallback is used only when no physical table symbol exists.
    ptov_symbol = 0;
    errno = EDOM;
    assert(phystokv(0x100020) == 0x8000000020);
    assert(errno == 0);
    assert(phystokv(0x0fffff) == 0 && errno == EFAULT);
    assert(phystokv(0x101000) == 0 && errno == EFAULT);

    // A present table whose read fails must fail closed, not use uninitialized data.
    ptov_symbol = 0x1000;
    ptov_read_result = -1;
    assert(phystokv(0x100020) == 0 && errno == EIO);

    // A valid table entry translates with its range offset.
    ptov_read_result = 0;
    memset(fake_ptov, 0, sizeof(fake_ptov));
    fake_ptov[0].pa = 0x2000;
    fake_ptov[0].va = 0x9000;
    fake_ptov[0].len = 0x100;
    assert(phystokv(0x2050) == 0x9050);
    assert(phystokv(0x2100) == 0 && errno == EFAULT);

    // A range beginning near UINT64_MAX must not wrap and match a low address.
    fake_ptov[0].pa = UINT64_MAX - 15;
    assert(phystokv(0x10) == 0 && errno == EFAULT);

    // Reject overflow when adding a valid table offset to its virtual base.
    fake_ptov[0].pa = 0x3000;
    fake_ptov[0].va = UINT64_MAX - 4;
    fake_ptov[0].len = 0x100;
    assert(phystokv(0x3008) == 0 && errno == EOVERFLOW);

    // Reject unsigned arithmetic wraparound in the virtual base plus offset.
    ptov_symbol = 0;
    gSystemInfo.kernelConstant.virtBase = UINT64_MAX - 4;
    gSystemInfo.kernelConstant.physBase = 0x1000;
    gSystemInfo.kernelConstant.physSize = 0x100;
    assert(phystokv(0x1008) == 0 && errno == EOVERFLOW);

    // SPTM has no linear fallback when the non-SPTM table is absent.
    gSystemInfo.kernelConstant.virtBase = 0x8000000000;
    sptm_symbol = 1;
    papt_ranges_symbol = 0;
    n_papt_ranges_symbol = 0;
    assert(phystokv(0x1008) == 0 && errno == EFAULT);

    // SPTM translates physical addresses through PAPT ranges when present.
    papt_ranges_symbol = 0x5000;
    n_papt_ranges_symbol = 0x5008;
    papt_table_addr = 0x6000;
    papt_table_n_addr = 0x6008;
    fake_papt_n = 1;
    papt_read_result = 0;
    memset(fake_papt, 0, sizeof(fake_papt));
    fake_papt[0].paddr_start = 0x800000000ULL;
    fake_papt[0].papt_start = 0xfffffeef87000000ULL;
    fake_papt[0].num_mappings = 4;
    assert(phystokv(0x800004020ULL) == 0xfffffeef87004020ULL);
    assert(phystokv(0x800010000ULL) == 0 && errno == EFAULT);

    papt_read_result = -1;
    assert(phystokv(0x800004020ULL) == 0 && errno == EIO);

    papt_read_result = 0;
    fake_papt[0].papt_start = UINT64_MAX - 0x10;
    assert(phystokv(0x800000020ULL) == 0 && errno == EOVERFLOW);

    puts("PASS: phystokv read failure, range, underflow and overflow cases");
    return 0;
}
"""

source=(ROOT/'BaseBin/libjailbreak/src/translation.c').read_text(encoding='utf-8')
harness=PREFIX+'\n'+extract_function(source,'uint64_t phystokv(uint64_t pa)')+'\n'+SUFFIX
with tempfile.TemporaryDirectory(prefix='translation-health-') as directory:
    test_c=Path(directory)/'translation.c'
    test_exe=Path(directory)/'translation-health'
    test_c.write_text(harness,encoding='utf-8')
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(test_c),'-o',str(test_exe)],check=True)
    subprocess.run([str(test_exe)],check=True)
print('Scope: extracted phystokv + fake kernel table; device page-table verification still required.')
