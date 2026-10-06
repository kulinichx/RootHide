#!/usr/bin/env python3
"""Host regressions for checked IOSurface kernel-memory helpers.

The C harness extracts the real address, read/write, snapshot, rollback,
cleanup, and kalloc-range helpers. It uses a bounded fake kernel-memory array;
it does not emulate IOSurface, XNU, page tables, or device compatibility.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = ROOT / "BaseBin/libjailbreak/src/primitives_IOSurface.m"
INFO_SOURCE_PATH = ROOT / "BaseBin/libjailbreak/src/info.c"


def extract_braced(source: str, start: int, closing_suffix: str) -> str:
    opening = source.index("{", start)
    depth = 0
    for position in range(opening, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                end = position + 1
                if closing_suffix == ";":
                    end = source.index(";", end) + 1
                return source[start:end]
    raise ValueError("Unclosed C declaration")


def extract_function(source: str, signature: str) -> str:
    start = source.index(signature)
    return extract_braced(source, start, "")


def extract_struct(source: str, name: str) -> str:
    start = source.index(f"struct {name} {{")
    return extract_braced(source, start, ";")


PREFIX = r"""
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KERNEL_BASE UINT64_C(0x1000)
static uint8_t kernel_memory[0x4000];
static uint64_t failed_read_address = UINT64_MAX;
struct write_failure { unsigned call; uint64_t address; };
static struct write_failure write_failures[8];
static unsigned write_failure_count;
static unsigned write_call_count;
static struct { size_t krwMinSafeReadSize; } gPrimitives = {0};

struct kernel_layout {
    uint8_t padding0[0x10];
    uint64_t ranges;
    uint8_t padding1[0x20 - 0x18];
    uint32_t rangeCount;
};
#define koffsetof(type, member) offsetof(struct kernel_layout, member)
#define UNSIGN_PTR(value) (value)

static void reset_io(void) {
    failed_read_address = UINT64_MAX;
    write_failure_count = 0;
    write_call_count = 0;
}

static void fail_write_on_call(unsigned call, uint64_t address) {
    assert(write_failure_count < sizeof(write_failures) / sizeof(write_failures[0]));
    write_failures[write_failure_count++] = (struct write_failure){call, address};
}

int kreadbuf(uint64_t address, void *output, size_t size) {
    if (address == failed_read_address || address < KERNEL_BASE || size > sizeof(kernel_memory)) return -1;
    uint64_t offset = address - KERNEL_BASE;
    if (offset > sizeof(kernel_memory) - size) return -1;
    memcpy(output, kernel_memory + (size_t)offset, size);
    return 0;
}

int kwritebuf(uint64_t address, const void *input, size_t size) {
    write_call_count++;
    for (unsigned i = 0; i < write_failure_count; i++) {
        if (write_failures[i].call == write_call_count && write_failures[i].address == address) return -1;
    }
    if (address < KERNEL_BASE || size > sizeof(kernel_memory)) return -1;
    uint64_t offset = address - KERNEL_BASE;
    if (offset > sizeof(kernel_memory) - size) return -1;
    memcpy(kernel_memory + (size_t)offset, input, size);
    return 0;
}

static void store_bytes(uint64_t address, const void *input, size_t size) {
    assert(address >= KERNEL_BASE && size <= sizeof(kernel_memory));
    uint64_t offset = address - KERNEL_BASE;
    assert(offset <= sizeof(kernel_memory) - size);
    memcpy(kernel_memory + (size_t)offset, input, size);
}

static void store_u64(uint64_t address, uint64_t value) { store_bytes(address, &value, sizeof(value)); }
static void store_u32(uint64_t address, uint32_t value) { store_bytes(address, &value, sizeof(value)); }
static void store_u8(uint64_t address, uint8_t value) { store_bytes(address, &value, sizeof(value)); }

static uint64_t load_u64(uint64_t address) {
    uint64_t value = 0;
    assert(kreadbuf(address, &value, sizeof(value)) == 0);
    return value;
}
static uint32_t load_u32(uint64_t address) {
    uint32_t value = 0;
    assert(kreadbuf(address, &value, sizeof(value)) == 0);
    return value;
}
static uint8_t load_u8(uint64_t address) {
    uint8_t value = 0;
    assert(kreadbuf(address, &value, sizeof(value)) == 0);
    return value;
}

static unsigned tracked_free_count;
static void tracked_free(void *pointer) {
    if (pointer) {
        tracked_free_count++;
        free(pointer);
    }
}
"""


def check_source_contract(source: str) -> None:
    map_port = extract_function(source, "static mach_port_t IOSurface_map_getSurfacePort(")
    for guard in ("if (!properties)", "if (!surfaceRef)", "if (!baseAddress)", "if (!MACH_PORT_VALID(port))"):
        assert guard in map_port, f"Missing IOSurface map-port guard: {guard}"

    map_function = extract_function(source, "int IOSurface_map_withCacheMode(")
    for guard in (
        "if (!uaddr || !size)",
        "if (pa > UINT64_MAX - size)",
        "if (IOMemoryDescriptor_set_size(desc, size) != 0)",
        "if (IOMemoryDescriptor_set_wired(desc, true) != 0)",
        "if (IOMemoryDescriptor_set_flags(desc, flags) != 0)",
        "if (IOMemoryDescriptor_set_memRef(desc, 0) != 0)",
        "IOSurface_map_restore(desc, &snapshot)",
    ):
        assert guard in map_function, f"Missing checked map path: {guard}"
    assert "kwrite64(" not in map_function, "IOSurface map must not bypass checked writes"

    cleanup = extract_function(source, "void IOSurface_map_cleanup(void)")
    assert "gMapCleanups[remaining++] = cleanup;" in cleanup
    assert "free(cleanup.fakeRanges);" in cleanup

    old_kalloc_port = extract_function(source, "static mach_port_t IOSurface_kalloc_getSurfacePort(")
    for guard in ("if (!addressRangesBuf)", "if (!allocation)", "if (!addressRanges)", "if (!surfaceRef)", "if (!MACH_PORT_VALID(port))"):
        assert guard in old_kalloc_port, f"Missing legacy kalloc allocation guard: {guard}"

    new_kalloc_port = extract_function(source, "static mach_port_t IOSurface_kalloc_getSurfacePort_16up(")
    for guard in ("if (!userspaceRanges)", "if (!userspaceRangesData)", "if (!dict)", "if (!dummyPageSizeNum)", "if (!MACH_PORT_VALID(port))"):
        assert guard in new_kalloc_port, f"Missing 16-up kalloc allocation guard: {guard}"


def check_surface_pointer_contract(source: str) -> None:
    pointer = extract_function(source, "static bool IOSurface_kernel_pointer(")
    assert "value >= 0xffff000000000000ULL" in pointer

    surface_check = extract_function(source, "static bool IOSurface_object_is_surface(")
    assert "if (!IOSurface_kernel_pointer(candidate)) return false;" in surface_check
    assert "IOSurface_read_ptr(mdAddress)" in surface_check
    assert "IOSurface_kernel_pointer(descriptor)" in surface_check
    assert "IOSurface_kernel_pointer(IOSurface_read_ptr(rangesAddress))" in surface_check

    send_right = extract_function(source, "uint64_t IOSurfaceSendRight_get_surface(")
    assert "if (IOSurface_object_is_surface(surface)) return surface;" in send_right
    assert "if (IOSurface_object_is_surface(candidate)) return candidate;" in send_right
    assert "static const uint64_t probeOffsets[] = { 0x20, 0x28, 0x10 };" in send_right


def check_iosurface_offset_contract() -> None:
    info_source = INFO_SOURCE_PATH.read_text(encoding="utf-8")
    start = info_source.index("// iOS 17+")
    end = info_source.index("// IOMachPort", start)
    ios17_layout = info_source[start:end]

    assert "gSystemInfo.kernelStruct.IOSurface.memoryDescriptor = 0x40;" in ios17_layout
    assert "gSystemInfo.kernelStruct.IOSurface.memoryDescriptor = 0x20;" not in ios17_layout


def run_surface_pointer_regressions(source: str) -> None:
    signatures = (
        "static bool IOSurface_target_address(",
        "static bool IOSurface_read_bytes(",
        "static bool IOSurface_read_u64(",
        "static uint64_t IOSurface_read_ptr(",
        "static bool IOSurface_kernel_pointer(",
        "static bool IOSurface_object_is_surface(",
        "uint64_t IOSurfaceSendRight_get_surface(",
    )
    functions = [extract_function(source, signature) for signature in signatures]

    prefix = r"""
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define KERNEL_BASE UINT64_C(0xfffffff000000000)
#define PAGE_MASK UINT64_C(0x3fff)
static uint8_t kernel_memory[0x10000];
static uint64_t failed_read_address = UINT64_MAX;
static unsigned invalid_read_count;
static bool clearSwordSilentFailure;
static uint64_t tracked_send_right;
static unsigned send_right_read_count;
static bool send_right_overread;
struct mock_primitives { uint64_t krwMinSafeReadSize; } gPrimitives;

#define koffsetof(type, member) ((uint64_t)0x20)
#define UNSIGN_PTR(value) (value)

int kreadbuf(uint64_t address, void *output, size_t size) {
    uint8_t *output8 = (uint8_t *)output;
    size_t bytes_read = 0;
    while (bytes_read < size) {
        size_t chunk = (size - bytes_read < 0x20) ? (size - bytes_read) : 0x20;
        uint64_t where = address + bytes_read;
        bool clearSwordWindow = gPrimitives.krwMinSafeReadSize == 0x20;
        size_t data_offset = 0;
        uint64_t read_address = where;
        size_t physical_size = chunk;
        if (clearSwordWindow) {
            uint64_t real_end = where + 0x20 - 1;
            if ((where & ~PAGE_MASK) != (real_end & ~PAGE_MASK)) {
                data_offset = 0x20 - chunk;
                read_address = where - data_offset;
            }
            physical_size = 0x20;
        }

        bool invalid = read_address == failed_read_address || read_address < KERNEL_BASE ||
                       physical_size > sizeof(kernel_memory);
        uint64_t offset = invalid ? 0 : read_address - KERNEL_BASE;
        if (!invalid && offset > sizeof(kernel_memory) - physical_size) invalid = true;
        if (tracked_send_right && read_address >= tracked_send_right && read_address < tracked_send_right + 0x100) {
            send_right_read_count++;
            if (read_address + physical_size > tracked_send_right + 0x30) send_right_overread = true;
        }
        if (invalid) {
            invalid_read_count++;
            if (clearSwordWindow && clearSwordSilentFailure) {
                bytes_read += chunk; // clearsword_kreadbuf returns 0 even when early_kreadbuf failed
                continue;
            }
            return -1;
        }

        memcpy(output8 + bytes_read, kernel_memory + (size_t)offset + data_offset, chunk);
        bytes_read += chunk;
    }
    return 0;
}

static void reset_reads(void) {
    failed_read_address = UINT64_MAX;
    invalid_read_count = 0;
    send_right_read_count = 0;
    send_right_overread = false;
}

static void store_u64(uint64_t address, uint64_t value) {
    assert(address >= KERNEL_BASE);
    uint64_t offset = address - KERNEL_BASE;
    assert(offset <= sizeof(kernel_memory) - sizeof(value));
    memcpy(kernel_memory + (size_t)offset, &value, sizeof(value));
}

static void install_surface_chain(uint64_t surface, uint64_t descriptor, uint64_t ranges) {
    store_u64(surface + 0x20, descriptor);
    store_u64(descriptor + 0x60, ranges);
}
"""

    suffix = r"""
int main(void) {
    const uint64_t send_right = KERNEL_BASE + 0x100;
    tracked_send_right = send_right;
    const uint64_t surface = KERNEL_BASE + 0x1000;
    const uint64_t descriptor = KERNEL_BASE + 0x2000;
    const uint64_t ranges = KERNEL_BASE + 0x3000;
    install_surface_chain(surface, descriptor, ranges);

    // Legacy direct-offset path remains valid when no widened read is needed.
    gPrimitives.krwMinSafeReadSize = 0;
    store_u64(send_right + 0x18, surface);
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == surface);
    assert(invalid_read_count == 0);
    assert(send_right_read_count == 1 && !send_right_overread);

    // ClearSword's 0x20 safe-read path still resolves the legacy +0x18 field.
    gPrimitives.krwMinSafeReadSize = 0x20;
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == surface);
    assert(invalid_read_count == 0);
    assert(send_right_read_count == 1 && !send_right_overread);

    // A valid +0x20 candidate is selected from the bounded safe-read window.
    store_u64(send_right + 0x18, UINT64_C(0x100000061));
    store_u64(send_right + 0x20, surface);
    store_u64(send_right + 0x28, UINT64_C(0x100000071));
    store_u64(send_right + 0x10, UINT64_C(0x100000019));
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == surface);
    assert(invalid_read_count == 0);
    assert(send_right_read_count == 1 && !send_right_overread);

    // A low, invalid +0x18 value must not be dereferenced; a validated +0x28
    // surface candidate should be selected instead.
    store_u64(send_right + 0x18, UINT64_C(0x100000061));
    store_u64(send_right + 0x20, UINT64_C(0x100000051));
    store_u64(send_right + 0x28, surface);
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == surface);
    assert(invalid_read_count == 0);
    assert(send_right_read_count == 1 && !send_right_overread);

    // The +0x10 candidate is also read from the same bounded safe-read window.
    store_u64(send_right + 0x18, UINT64_C(0x100000061));
    store_u64(send_right + 0x20, UINT64_C(0x100000051));
    store_u64(send_right + 0x28, UINT64_C(0x100000071));
    store_u64(send_right + 0x10, surface);
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == surface);
    assert(invalid_read_count == 0);
    assert(send_right_read_count == 1 && !send_right_overread);

    // A pointer-looking candidate with an invalid descriptor chain is rejected.
    const uint64_t bad_surface = KERNEL_BASE + 0x4000;
    store_u64(bad_surface + 0x20, UINT64_C(0x100000051));
    store_u64(send_right + 0x18, UINT64_C(0x100000061));
    store_u64(send_right + 0x20, UINT64_C(0x100000051));
    store_u64(send_right + 0x28, bad_surface);
    store_u64(send_right + 0x10, 0);
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == 0);
    assert(errno == EFAULT && invalid_read_count == 0);
    assert(send_right_read_count == 1 && !send_right_overread);

    // A descriptor whose ranges field is not a kernel pointer is rejected too.
    const uint64_t bad_descriptor = KERNEL_BASE + 0x5000;
    store_u64(bad_surface + 0x20, bad_descriptor);
    store_u64(bad_descriptor + 0x60, UINT64_C(0x100000071));
    store_u64(send_right + 0x28, bad_surface);
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == 0);
    assert(errno == EFAULT && invalid_read_count == 0);

    // Silent ClearSword failure while reading a valid-looking surface's
    // memoryDescriptor must also be rejected; a low-level kread error is not reported.
    store_u64(send_right + 0x18, UINT64_C(0x100000061));
    store_u64(send_right + 0x20, UINT64_C(0x100000051));
    store_u64(send_right + 0x28, surface);
    store_u64(send_right + 0x10, UINT64_C(0x100000019));
    reset_reads();
    failed_read_address = surface + 0x20;
    clearSwordSilentFailure = true;
    assert(IOSurfaceSendRight_get_surface(send_right) == 0 && errno == EFAULT);
    assert(invalid_read_count == 1 && send_right_read_count == 1 && !send_right_overread);
    clearSwordSilentFailure = false;

    // ClearSword's lower-level failure is silent; the zeroed output still fails closed.
    gPrimitives.krwMinSafeReadSize = 0x20;
    reset_reads();
    failed_read_address = send_right + 0x10;
    clearSwordSilentFailure = true;
    assert(IOSurfaceSendRight_get_surface(send_right) == 0 && errno == EFAULT);
    assert(invalid_read_count == 1 && send_right_read_count == 1 && !send_right_overread);
    clearSwordSilentFailure = false;

    // A kreadbuf implementation that reports errors explicitly propagates EIO.
    reset_reads();
    failed_read_address = send_right + 0x10;
    assert(IOSurfaceSendRight_get_surface(send_right) == 0 && errno == EIO);

    // Unreasonable safe-read sizes are rejected before issuing a read.
    gPrimitives.krwMinSafeReadSize = 0x40;
    reset_reads();
    assert(IOSurfaceSendRight_get_surface(send_right) == 0 && errno == ERANGE);

    puts("PASS: IOSurfaceSendRight bounded probes, ClearSword 0x20 windows and fail-closed validation");
    return 0;
}
"""

    harness = prefix + "\n" + "\n\n".join(functions) + "\n\n" + suffix
    with tempfile.TemporaryDirectory(prefix="iosurface-pointer-") as directory:
        test_c = Path(directory) / "iosurface_pointer.c"
        test_exe = Path(directory) / "iosurface_pointer"
        test_c.write_text(harness, encoding="utf-8")
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(test_c), "-o", str(test_exe)], check=True)
        subprocess.run([str(test_exe)], check=True)


def main() -> None:
    source = SOURCE_PATH.read_text(encoding="utf-8")
    check_source_contract(source)
    check_surface_pointer_contract(source)
    check_iosurface_offset_contract()

    declarations = "\n".join((
        extract_struct(source, "IOSurfaceMapCleanup"),
        extract_struct(source, "IOSurfaceMapSnapshot"),
        "static struct IOSurfaceMapCleanup *gMapCleanups;\nstatic size_t gMapCleanupCount;",
    ))
    signatures = (
        "static bool IOSurface_target_address(",
        "static bool IOSurface_read_bytes(",
        "static bool IOSurface_read_u64(",
        "static uint64_t IOSurface_read_ptr(",
        "static int IOSurface_write(",
        "uint64_t IOMemoryDescriptor_get_ranges(",
        "int IOMemoryDescriptor_set_ranges(",
        "int IOMemoryDescriptor_set_wired(",
        "int IOMemoryDescriptor_set_flags(",
        "int IOMemoryDescriptor_set_memRef(",
        "int IOSurface_set_ranges(",
        "int IOSurface_set_rangeCount(",
        "static bool IOSurface_map_read_field(",
        "static int IOSurface_map_write_field(",
        "static bool IOSurface_map_capture(",
        "static bool IOSurface_map_restore(",
        "static bool IOSurface_kalloc_clear_ranges(",
    )
    functions = [extract_function(source, signature) for signature in signatures]
    cleanup = extract_function(source, "void IOSurface_map_cleanup(void)").replace("free(", "tracked_free(")

    suffix = r"""
int main(void) {
    uint64_t address = 0;
    errno = EDOM;
    assert(IOSurface_target_address(0x1000, 0x20, &address) && address == 0x1020);
    assert(!IOSurface_target_address(0, 0, &address) && errno == EFAULT);
    assert(!IOSurface_target_address(UINT64_MAX - 2, 4, &address) && errno == EOVERFLOW);

    uint8_t output[4] = {1, 2, 3, 4};
    reset_io();
    failed_read_address = 0x2000;
    assert(!IOSurface_read_bytes(0x2000, output, sizeof(output)) && errno == EIO);
    assert(output[0] == 0 && output[1] == 0 && output[2] == 0 && output[3] == 0);

    uint32_t write_value = 0x12345678;
    reset_io();
    fail_write_on_call(1, 0x2100);
    assert(IOSurface_write(0x2100, &write_value, sizeof(write_value)) == -1 && errno == EIO);

    const uint64_t descriptor = 0x1100;
    const uint64_t ranges = 0x3000;
    const uint64_t fake_ranges_kaddr = 0x3100;
    store_u64(descriptor + 0x60, ranges);
    store_u64(ranges, 0x1111222233334444);
    store_u64(ranges + 8, 0x5555666677778888);
    store_u64(descriptor + 0x50, 0x9000);
    store_u64(descriptor + 0x18, 0x18181818);
    store_u64(descriptor + 0x70, 0x70707070);
    store_u64(descriptor + 0x90, 0x90909090);
    store_u64(descriptor + 0x28, 0x28282828);
    store_u32(descriptor + 0x20, 0x20202020);
    store_u8(descriptor + 0x88, 1);

    struct IOSurfaceMapSnapshot snapshot;
    reset_io();
    assert(IOSurface_map_capture(descriptor, &snapshot));
    assert(snapshot.ranges == ranges && snapshot.rangeValues[0] == 0x1111222233334444);
    assert(snapshot.rangeValues[1] == 0x5555666677778888 && snapshot.size == 0x9000);
    assert(snapshot.descriptor18 == 0x18181818 && snapshot.descriptor70 == 0x70707070);
    assert(snapshot.descriptor90 == 0x90909090 && snapshot.memRef == 0x28282828);
    assert(snapshot.flags == 0x20202020 && snapshot.wired == 1);

    store_u64(descriptor + 0x60, fake_ranges_kaddr);
    store_u64(ranges, 1);
    store_u64(ranges + 8, 2);
    store_u64(descriptor + 0x50, 3);
    store_u64(descriptor + 0x18, 4);
    store_u64(descriptor + 0x70, 5);
    store_u64(descriptor + 0x90, 6);
    store_u64(descriptor + 0x28, 7);
    store_u32(descriptor + 0x20, 8);
    store_u8(descriptor + 0x88, 0);
    reset_io();
    assert(IOSurface_map_restore(descriptor, &snapshot));
    assert(load_u64(descriptor + 0x60) == ranges);
    assert(load_u64(ranges) == snapshot.rangeValues[0] && load_u64(ranges + 8) == snapshot.rangeValues[1]);
    assert(load_u64(descriptor + 0x50) == snapshot.size);
    assert(load_u64(descriptor + 0x18) == snapshot.descriptor18);
    assert(load_u64(descriptor + 0x70) == snapshot.descriptor70);
    assert(load_u64(descriptor + 0x90) == snapshot.descriptor90);
    assert(load_u64(descriptor + 0x28) == snapshot.memRef);
    assert(load_u32(descriptor + 0x20) == snapshot.flags && load_u8(descriptor + 0x88) == snapshot.wired);

    reset_io();
    failed_read_address = descriptor + 0x70;
    struct IOSurfaceMapSnapshot failed_snapshot;
    assert(!IOSurface_map_capture(descriptor, &failed_snapshot) && errno == EIO);

    store_u64(descriptor + 0x60, fake_ranges_kaddr);
    store_u64(descriptor + 0x50, 0xaaaa);
    reset_io();
    fail_write_on_call(1, descriptor + 0x60);
    assert(!IOSurface_map_restore(descriptor, &snapshot));
    assert(load_u64(descriptor + 0x60) == fake_ranges_kaddr);
    assert(load_u64(descriptor + 0x50) == snapshot.size); // Later restore writes still run.
    reset_io();
    assert(IOSurface_map_restore(descriptor, &snapshot));

    gPrimitives.krwMinSafeReadSize = 0x20;
    reset_io();
    failed_read_address = ranges;
    assert(IOSurface_map_capture(descriptor, &snapshot));
    fail_write_on_call(2, ranges);
    assert(IOSurface_map_restore(descriptor, &snapshot));
    gPrimitives.krwMinSafeReadSize = 0;

    const uint64_t surface = 0x2200;
    const uint64_t original_ranges = 0x3000;
    store_u64(surface + 0x10, original_ranges);
    store_u32(surface + 0x20, 7);
    bool safe_to_release = false;
    reset_io();
    assert(IOSurface_kalloc_clear_ranges(surface, original_ranges, 7, &safe_to_release));
    assert(safe_to_release && load_u64(surface + 0x10) == 0 && load_u32(surface + 0x20) == 0);

    store_u64(surface + 0x10, original_ranges);
    store_u32(surface + 0x20, 7);
    reset_io();
    fail_write_on_call(2, surface + 0x20);
    assert(!IOSurface_kalloc_clear_ranges(surface, original_ranges, 7, &safe_to_release));
    assert(safe_to_release && errno == EIO);
    assert(load_u64(surface + 0x10) == original_ranges && load_u32(surface + 0x20) == 7);

    store_u64(surface + 0x10, original_ranges);
    store_u32(surface + 0x20, 7);
    reset_io();
    fail_write_on_call(2, surface + 0x20);
    fail_write_on_call(3, surface + 0x10);
    assert(!IOSurface_kalloc_clear_ranges(surface, original_ranges, 7, &safe_to_release));
    assert(!safe_to_release && load_u64(surface + 0x10) == 0 && load_u32(surface + 0x20) == 7);

    const uint64_t cleanup_descriptor = 0x1300;
    store_u64(cleanup_descriptor + 0x60, fake_ranges_kaddr);
    struct IOSurfaceMapCleanup *cleanup_array = malloc(sizeof(*cleanup_array));
    uint64_t *fake_ranges = malloc(2 * sizeof(uint64_t));
    assert(cleanup_array && fake_ranges);
    cleanup_array[0] = (struct IOSurfaceMapCleanup){cleanup_descriptor, ranges, fake_ranges};
    gMapCleanups = cleanup_array;
    gMapCleanupCount = 1;
    tracked_free_count = 0;
    reset_io();
    fail_write_on_call(1, cleanup_descriptor + 0x60);
    IOSurface_map_cleanup();
    assert(gMapCleanupCount == 1 && gMapCleanups == cleanup_array && tracked_free_count == 0);
    assert(errno == EIO);
    reset_io();
    IOSurface_map_cleanup();
    assert(gMapCleanupCount == 0 && gMapCleanups == NULL && tracked_free_count == 2);
    assert(load_u64(cleanup_descriptor + 0x60) == ranges);

    puts("PASS: IOSurface address, I/O, rollback, cleanup and kalloc failure paths");
    return 0;
}
"""

    harness = PREFIX + "\n" + declarations + "\n" + "\n\n".join(functions) + "\n\n" + cleanup + "\n" + suffix
    with tempfile.TemporaryDirectory(prefix="iosurface-health-") as directory:
        test_c = Path(directory) / "iosurface_health.c"
        test_exe = Path(directory) / "iosurface_health"
        test_c.write_text(harness, encoding="utf-8")
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(test_c), "-o", str(test_exe)], check=True)
        subprocess.run([str(test_exe)], check=True)
    run_surface_pointer_regressions(source)
    print("Scope: extracted checked helpers + fake kernel memory; device verification still required.")


if __name__ == "__main__":
    main()
