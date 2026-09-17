#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/vm_prot.h>
#include <os/lock.h>
#include <ptrauth.h>
#include <simd/simd.h>
#include <sys/mman.h>
#include <unistd.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

namespace {

static constexpr const char *kCustomFilterType = "go.roothide.refraction";
static constexpr size_t kGaussianRecordSlots = 22;
static constexpr size_t kGaussianRecordSize = kGaussianRecordSlots * sizeof(void *);
static constexpr uint32_t kRET = 0xD65F03C0u;
static constexpr uint32_t kPACIBSP = 0xD503237Fu;

struct AddressRange {
    uintptr_t start;
    uintptr_t end;
};

struct QuartzCoreImage {
    const mach_header_64 *header;
    intptr_t slide;
    uintptr_t textStart;
    uintptr_t textEnd;
    AddressRange executable[8];
    size_t executableCount;
};

static QuartzCoreImage gQuartzCore = {};
static bool gQuartzCoreReady = false;

using CAInternAtomFn = uint32_t (*)(const char *);
using AddFilterFn = void (*)(uint32_t, void *);
using StopEncodersFn = void (*)(void *);
using GlassCallbackFn = void (*)(void *, void *, id<MTLDevice>, void *, float,
                                 void *, void *, void *, void *, void *);

static void *gCAInternAtom = nullptr;
static void *gAddFilter = nullptr;
static void **gGaussianRecordSlot = nullptr;
static void **gFilterRegistrySlot = nullptr;
static void *gStopEncoders = nullptr;
static ptrdiff_t gCommandContextOffset = -1;
static uint32_t gCustomAtom = 0;
static void *gOriginalSecondary = nullptr;
static bool gRegistered = false;
static bool gRetryScheduled = false;

static os_unfair_lock gPipelineLock = OS_UNFAIR_LOCK_INIT;
static __strong id<MTLDevice> gPipelineDevice = nil;
static MTLPixelFormat gPipelineFormat = MTLPixelFormatInvalid;
static __strong id<MTLRenderPipelineState> gPipelineState = nil;

struct GlassUniforms {
    vector_float2 sourceSize;
    vector_float2 outputSize;
    float radius;
    float bezelWidth;
    float refractionScale;
    float refractiveIndex;
    float dispersionStrength;
    float diffusionStrength;
    float darkEdgeStrength;
    float specularStrength;
    float backdropZoom;
    float padding;
};

static const char *kGlassShaderSourceUTF8 = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlassUniforms {
    float2 sourceSize;
    float2 outputSize;
    float radius;
    float bezelWidth;
    float refractionScale;
    float refractiveIndex;
    float dispersionStrength;
    float diffusionStrength;
    float darkEdgeStrength;
    float specularStrength;
    float backdropZoom;
    float padding;
};

vertex VertexOut rhGlassVertex(uint vertexID [[vertex_id]])
{
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    float2 p = positions[vertexID];
    VertexOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2((p.x + 1.0) * 0.5,
                    1.0 - (p.y + 1.0) * 0.5);
    return out;
}

static float roundedRectSDF(float2 p, float2 size, float radius)
{
    float2 halfSize = size * 0.5;
    float r = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    float2 q = abs(p - halfSize) - (halfSize - r);
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

static float luminance(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

fragment float4 rhGlassFragment(VertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant GlassUniforms& u [[buffer(0)]])
{
    constexpr sampler linearClamp(coord::normalized,
                                  address::clamp_to_edge,
                                  filter::linear);

    float2 outputSize = max(u.outputSize, float2(1.0));
    float2 sourceSize = max(u.sourceSize, float2(1.0));
    float2 pixel = in.uv * outputSize;

    float sdf = roundedRectSDF(pixel, outputSize, u.radius);
    float insideDistance = max(-sdf, 0.0);
    float bezel = max(u.bezelWidth, 1.0);
    float edge = 1.0 - smoothstep(0.0, bezel, insideDistance);

    // Mango's geometry reference is edge-bounded: the center remains stable.
    float x = clamp(insideDistance / bezel, 0.0, 1.0);
    float oneMinusX = 1.0 - x;
    float y = pow(max(1.0 - pow(oneMinusX, 4.0), 0.0), 0.25);
    float slope = pow(oneMinusX, 3.0) / max(pow(y, 3.0), 0.025);
    float surfaceTilt = slope / (1.0 + slope);

    float dx = roundedRectSDF(pixel + float2(1.0, 0.0), outputSize, u.radius) -
               roundedRectSDF(pixel - float2(1.0, 0.0), outputSize, u.radius);
    float dy = roundedRectSDF(pixel + float2(0.0, 1.0), outputSize, u.radius) -
               roundedRectSDF(pixel - float2(0.0, 1.0), outputSize, u.radius);
    float2 edgeNormal = normalize(float2(dx, dy) + float2(1e-5));

    float3 surfaceNormal = normalize(float3(edgeNormal * surfaceTilt * 1.2, 1.0));
    float eta = 1.0 / max(u.refractiveIndex, 1.001);
    float3 refracted = refract(float3(0.0, 0.0, -1.0), surfaceNormal, eta);
    float2 displacementPx = refracted.xy * bezel * u.refractionScale * edge;

    // Center-align compositor textures when QuartzCore gives the filter a small padded source.
    float2 mappedUV = 0.5 + (in.uv - 0.5) * (outputSize / sourceSize);
    mappedUV = 0.5 + (mappedUV - 0.5) / max(u.backdropZoom, 1.0);

    float2 displacementUV = displacementPx / sourceSize;
    float dispersion = clamp(u.dispersionStrength, 0.0, 1.0);
    float rScale = 1.0 + 0.02 * dispersion;
    float bScale = 1.0 - 0.02 * dispersion;

    float4 centerSample = source.sample(linearClamp, mappedUV + displacementUV);
    float3 refractedColor = centerSample.rgb;
    if (edge * length(displacementPx) > 0.12 && dispersion > 0.001) {
        refractedColor.r = source.sample(linearClamp, mappedUV + displacementUV * rScale).r;
        refractedColor.b = source.sample(linearClamp, mappedUV + displacementUV * bScale).b;
    }

    float2 texel = 1.0 / sourceSize;
    float3 diffuseAverage = (
        source.sample(linearClamp, mappedUV + displacementUV + float2( 1.5, 0.0) * texel).rgb +
        source.sample(linearClamp, mappedUV + displacementUV + float2(-1.5, 0.0) * texel).rgb +
        source.sample(linearClamp, mappedUV + displacementUV + float2(0.0,  1.5) * texel).rgb +
        source.sample(linearClamp, mappedUV + displacementUV + float2(0.0, -1.5) * texel).rgb
    ) * 0.25;

    float localContrast = abs(luminance(refractedColor) - luminance(diffuseAverage));
    float diffusionWeight = clamp(u.diffusionStrength, 0.0, 1.0) *
                            smoothstep(0.02, 0.16, localContrast) *
                            (0.45 + 0.55 * edge);
    float3 color = mix(refractedColor, diffuseAverage, diffusionWeight);

    float darkEdge = clamp(u.darkEdgeStrength, 0.0, 0.5) * pow(edge, 1.35);
    color *= 1.0 - darkEdge;

    float f0 = pow((u.refractiveIndex - 1.0) / (u.refractiveIndex + 1.0), 2.0);
    float cosTheta = clamp(surfaceNormal.z, 0.0, 1.0);
    float fresnel = f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
    float2 lightDirection = normalize(float2(-0.65, -0.76));
    float directional = pow(clamp(dot(-edgeNormal, lightDirection) * 0.5 + 0.5, 0.0, 1.0), 18.0) * edge;
    float glare = min(0.18, (fresnel * 0.45 + directional) * clamp(u.specularStrength, 0.0, 1.0));
    color = 1.0 - (1.0 - color) * (1.0 - glare);

    // Very small luminance-adaptive readability tint; this is RootHide tuning, not an Apple parameter.
    float luma = luminance(color);
    float3 adaptiveTint = luma < 0.42 ? float3(1.0) : float3(0.0);
    color = mix(color, adaptiveTint, 0.018 + 0.008 * edge);

    return float4(clamp(color, float3(0.0), float3(1.0)), centerSample.a);
}
)METAL";

static inline void *StripCode(void *pointer)
{
    return pointer ? ptrauth_strip(pointer, ptrauth_key_function_pointer) : nullptr;
}

static inline void *SignCode(void *pointer)
{
    if (!pointer) return nullptr;
    void *raw = ptrauth_strip(pointer, ptrauth_key_function_pointer);
    return ptrauth_sign_unauthenticated(raw, ptrauth_key_function_pointer, 0);
}

static inline void *StripData(void *pointer)
{
    return pointer ? ptrauth_strip(pointer, ptrauth_key_process_independent_data) : nullptr;
}

static bool IsBackboardd(void)
{
    char path[PATH_MAX] = {};
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return false;

    char resolved[PATH_MAX] = {};
    const char *actual = realpath(path, resolved) ? resolved : path;
    return strcmp(actual, "/usr/libexec/backboardd") == 0;
}

static bool LoadQuartzCoreImage(void)
{
    if (gQuartzCoreReady) return true;

    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || !strstr(name, "/QuartzCore.framework/QuartzCore")) continue;

        const mach_header *genericHeader = _dyld_get_image_header(index);
        if (!genericHeader || genericHeader->magic != MH_MAGIC_64) continue;

        QuartzCoreImage image = {};
        image.header = reinterpret_cast<const mach_header_64 *>(genericHeader);
        image.slide = _dyld_get_image_vmaddr_slide(index);

        const uint8_t *cursor = reinterpret_cast<const uint8_t *>(image.header + 1);
        for (uint32_t commandIndex = 0; commandIndex < image.header->ncmds; commandIndex++) {
            const load_command *command = reinterpret_cast<const load_command *>(cursor);
            if (command->cmd == LC_SEGMENT_64) {
                const segment_command_64 *segment = reinterpret_cast<const segment_command_64 *>(command);
                uintptr_t start = static_cast<uintptr_t>(image.slide) + static_cast<uintptr_t>(segment->vmaddr);
                uintptr_t end = start + static_cast<uintptr_t>(segment->vmsize);

                if (strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                    image.textStart = start;
                    image.textEnd = end;
                }
                if ((segment->initprot & VM_PROT_EXECUTE) && image.executableCount < 8) {
                    image.executable[image.executableCount++] = { start, end };
                }
            }
            cursor += command->cmdsize;
        }

        if (!image.textStart || image.textEnd <= image.textStart || image.executableCount == 0) {
            continue;
        }

        gQuartzCore = image;
        gQuartzCoreReady = true;
        return true;
    }

    return false;
}

static bool IsExecutableAddress(uintptr_t address)
{
    address = reinterpret_cast<uintptr_t>(StripCode(reinterpret_cast<void *>(address)));
    if (!address) return false;
    for (size_t index = 0; index < gQuartzCore.executableCount; index++) {
        const AddressRange &range = gQuartzCore.executable[index];
        if (address >= range.start && address < range.end) return true;
    }
    return false;
}

static bool ReadInstruction(uintptr_t address, uint32_t *instruction)
{
    if (!instruction || address < gQuartzCore.textStart || address + sizeof(uint32_t) > gQuartzCore.textEnd) {
        return false;
    }
    memcpy(instruction, reinterpret_cast<const void *>(address), sizeof(uint32_t));
    return true;
}

static int64_t SignExtend(uint64_t value, unsigned bits)
{
    const uint64_t sign = 1ULL << (bits - 1);
    return static_cast<int64_t>((value ^ sign) - sign);
}

static bool DecodeADRP(uintptr_t instructionAddress, uint32_t instruction, uintptr_t *pageAddress, uint32_t *destinationRegister)
{
    if ((instruction & 0x9F000000u) != 0x90000000u) return false;

    uint64_t immhi = (instruction >> 5) & 0x7FFFFu;
    uint64_t immlo = (instruction >> 29) & 0x3u;
    int64_t immediate = SignExtend((immhi << 2) | immlo, 21) << 12;
    uintptr_t page = instructionAddress & ~static_cast<uintptr_t>(0xFFF);

    if (pageAddress) *pageAddress = static_cast<uintptr_t>(static_cast<int64_t>(page) + immediate);
    if (destinationRegister) *destinationRegister = instruction & 0x1Fu;
    return true;
}

static bool DecodeADRPAdd(uintptr_t adrpAddress, uint32_t adrp, uint32_t add, uintptr_t *target)
{
    uintptr_t page = 0;
    uint32_t adrpRegister = 0;
    if (!DecodeADRP(adrpAddress, adrp, &page, &adrpRegister)) return false;
    if ((add & 0x7F800000u) != 0x11000000u) return false;

    uint32_t sourceRegister = (add >> 5) & 0x1Fu;
    if (sourceRegister != adrpRegister) return false;

    uint64_t immediate = (add >> 10) & 0xFFFu;
    if (add & (1u << 22)) immediate <<= 12;
    if (target) *target = page + immediate;
    return true;
}

static bool DecodeADRPLoad64(uintptr_t adrpAddress, uint32_t adrp, uint32_t load, uintptr_t *target)
{
    uintptr_t page = 0;
    uint32_t adrpRegister = 0;
    if (!DecodeADRP(adrpAddress, adrp, &page, &adrpRegister)) return false;
    if ((load >> 22) != 0x3E5u) return false;
    if (((load >> 5) & 0x1Fu) != adrpRegister) return false;

    uintptr_t offset = (static_cast<uintptr_t>(load) >> 7) & 0x7FF8u;
    if (target) *target = page + offset;
    return true;
}

static uintptr_t DecodeBLTarget(uintptr_t address, uint32_t instruction)
{
    if ((instruction & 0xFC000000u) != 0x94000000u) return 0;
    int64_t immediate = SignExtend(instruction & 0x03FFFFFFu, 26) << 2;
    return static_cast<uintptr_t>(static_cast<int64_t>(address) + immediate);
}

static uintptr_t FindCString(const char *needle)
{
    if (!needle || !LoadQuartzCoreImage()) return 0;
    size_t length = strlen(needle) + 1;
    if (length == 0 || length > gQuartzCore.textEnd - gQuartzCore.textStart) return 0;

    const uint8_t *start = reinterpret_cast<const uint8_t *>(gQuartzCore.textStart);
    size_t size = gQuartzCore.textEnd - gQuartzCore.textStart;
    for (size_t offset = 0; offset + length <= size; offset++) {
        if (start[offset] == static_cast<uint8_t>(needle[0]) &&
            memcmp(start + offset, needle, length) == 0) {
            return gQuartzCore.textStart + offset;
        }
    }
    return 0;
}

static uintptr_t FindADRPAddReference(uintptr_t target)
{
    if (!target || !LoadQuartzCoreImage()) return 0;
    for (uintptr_t address = gQuartzCore.textStart;
         address + 8 <= gQuartzCore.textEnd;
         address += 4) {
        uint32_t first = 0, second = 0;
        if (!ReadInstruction(address, &first) || !ReadInstruction(address + 4, &second)) break;
        uintptr_t decoded = 0;
        if (DecodeADRPAdd(address, first, second, &decoded) && decoded == target) {
            return address;
        }
    }
    return 0;
}

static bool IsFunctionPrologue(uint32_t instruction)
{
    if (instruction == kPACIBSP) return true;
    if ((instruction & 0xFFE003E0u) == 0xA9A003E0u) return true;
    if ((instruction & 0xFF8003FFu) == 0xD10003FFu) return true;
    return false;
}

static uintptr_t FindFunctionStart(uintptr_t reference, size_t maximumBackscan)
{
    if (!reference || reference < gQuartzCore.textStart) return 0;
    uintptr_t minimum = reference > maximumBackscan ? reference - maximumBackscan : gQuartzCore.textStart;
    if (minimum < gQuartzCore.textStart) minimum = gQuartzCore.textStart;

    uintptr_t current = reference & ~static_cast<uintptr_t>(3);
    while (current >= minimum && current >= gQuartzCore.textStart) {
        uint32_t instruction = 0;
        if (!ReadInstruction(current, &instruction)) break;
        if (IsFunctionPrologue(instruction)) {
            if (instruction != kPACIBSP && current >= gQuartzCore.textStart + 4) {
                uint32_t previous = 0;
                if (ReadInstruction(current - 4, &previous) && previous == kPACIBSP) {
                    return current - 4;
                }
            }
            return current;
        }
        if (current < minimum + 4) break;
        current -= 4;
    }
    return 0;
}

static void *ResolveCAInternAtom(void)
{
    void *symbol = dlsym(RTLD_DEFAULT, "CAInternAtomWithCString");
    if (symbol) return SignCode(symbol);
    if (!LoadQuartzCoreImage()) return nullptr;

    for (uintptr_t address = gQuartzCore.textStart + 4;
         address + 28 <= gQuartzCore.textEnd;
         address += 4) {
        uint32_t words[7] = {};
        bool readable = true;
        for (size_t index = 0; index < 7; index++) {
            if (!ReadInstruction(address + index * 4, &words[index])) {
                readable = false;
                break;
            }
        }
        if (!readable) break;
        if (words[0] != 0xA9BE4FF4u ||
            words[1] != 0xA9017BFDu ||
            words[2] != 0x910043FDu ||
            words[3] != 0xAA0003F3u ||
            (words[4] & 0xFC000000u) != 0x94000000u ||
            words[5] != 0xAA0003F4u ||
            (words[6] & 0x7F00001Fu) != 0x35000000u) {
            continue;
        }

        uintptr_t start = address;
        uint32_t previous = 0;
        if (ReadInstruction(address - 4, &previous) && previous == kPACIBSP) start -= 4;
        return SignCode(reinterpret_cast<void *>(start));
    }
    return nullptr;
}

struct AddFilterCandidate {
    uintptr_t instruction;
    uintptr_t callTarget;
    void **globalSlot;
};

static bool ParseAddFilterCandidate(uintptr_t address, AddFilterCandidate *candidate)
{
    if (!candidate || address < gQuartzCore.textStart + 8 || address + 20 > gQuartzCore.textEnd) return false;

    uint32_t movz = 0;
    if (!ReadInstruction(address, &movz)) return false;
    if ((movz & 0xFF80001Fu) != 0x52800000u) return false;

    uint32_t adrp = 0, add = 0;
    if (!ReadInstruction(address - 8, &adrp) || !ReadInstruction(address - 4, &add)) return false;
    uintptr_t globalAddress = 0;
    if (!DecodeADRPAdd(address - 8, adrp, add, &globalAddress) || (globalAddress & 0x7u)) return false;

    for (size_t index = 1; index <= 4; index++) {
        uintptr_t callAddress = address + index * 4;
        uint32_t instruction = 0;
        if (!ReadInstruction(callAddress, &instruction)) return false;
        uintptr_t target = DecodeBLTarget(callAddress, instruction);
        if (!target) continue;

        candidate->instruction = address;
        candidate->callTarget = target;
        candidate->globalSlot = reinterpret_cast<void **>(globalAddress);
        return true;
    }
    return false;
}

static void **FindFilterRegistrySlotNear(uintptr_t firstCandidate)
{
    if (firstCandidate < gQuartzCore.textStart + 8) return nullptr;
    uintptr_t secondAddress = firstCandidate - 4;

    for (size_t attempt = 0; attempt < 25; attempt++) {
        if (secondAddress < gQuartzCore.textStart + 4) break;
        uint32_t adrp = 0, load = 0;
        if (ReadInstruction(secondAddress - 4, &adrp) &&
            ReadInstruction(secondAddress, &load)) {
            uintptr_t decoded = 0;
            if (DecodeADRPLoad64(secondAddress - 4, adrp, load, &decoded)) {
                return reinterpret_cast<void **>(decoded);
            }
        }
        secondAddress -= 4;
    }
    return nullptr;
}

static bool ResolveAddFilterInternals(void)
{
    if (!LoadQuartzCoreImage()) return false;

    for (uintptr_t firstAddress = gQuartzCore.textStart + 8;
         firstAddress + 0x20 < gQuartzCore.textEnd;
         firstAddress += 4) {
        AddFilterCandidate first = {};
        if (!ParseAddFilterCandidate(firstAddress, &first)) continue;
        if (!IsExecutableAddress(first.callTarget)) continue;

        AddFilterCandidate matches[8] = {};
        matches[0] = first;
        size_t matchCount = 1;
        uintptr_t previous = firstAddress;

        while (matchCount < 8) {
            uintptr_t limit = previous + 0x40;
            if (limit > gQuartzCore.textEnd - 0x20) limit = gQuartzCore.textEnd - 0x20;
            bool found = false;
            for (uintptr_t address = previous + 4; address < limit; address += 4) {
                AddFilterCandidate next = {};
                if (ParseAddFilterCandidate(address, &next) && next.callTarget == first.callTarget) {
                    matches[matchCount++] = next;
                    previous = address;
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }

        if (matchCount < 4) continue;

        void **registrySlot = FindFilterRegistrySlotNear(matches[0].instruction);
        if (!registrySlot || !matches[1].globalSlot) continue;

        gAddFilter = SignCode(reinterpret_cast<void *>(first.callTarget));
        gGaussianRecordSlot = matches[1].globalSlot;
        gFilterRegistrySlot = registrySlot;
        return gAddFilter && gGaussianRecordSlot && gFilterRegistrySlot;
    }

    return false;
}

static void *ResolveStopEncoders(void)
{
    uintptr_t stringAddress = FindCString("!memoryless_in_use ()");
    uintptr_t reference = FindADRPAddReference(stringAddress);
    uintptr_t functionStart = FindFunctionStart(reference, 0x800);
    return functionStart ? SignCode(reinterpret_cast<void *>(functionStart)) : nullptr;
}

static ptrdiff_t ResolveCommandContextOffset(void)
{
    uintptr_t stringAddress = FindCString("Command buffer allocation failed!\n");
    uintptr_t reference = FindADRPAddReference(stringAddress);
    uintptr_t functionStart = FindFunctionStart(reference, 0x1000);
    if (!functionStart) return -1;

    uint32_t knownRegisters = 1u; // x0 is the initial render-context value.
    for (size_t index = 0; index < 48; index++) {
        uintptr_t address = functionStart + index * 4;
        if (address + 4 > gQuartzCore.textEnd) break;

        uint32_t instruction = 0;
        if (!ReadInstruction(address, &instruction)) break;

        if ((instruction & 0xFFE0FFE0u) == 0xAA0003E0u) {
            uint32_t source = (instruction >> 16) & 0x1Fu;
            uint32_t destination = instruction & 0x1Fu;
            if (source < 31 && destination < 31) {
                uint32_t destinationBit = 1u << destination;
                if (knownRegisters & (1u << source)) knownRegisters |= destinationBit;
                else knownRegisters &= ~destinationBit;
            }
            continue;
        }

        if (((instruction >> 23) & 0x1FFu) == 0x1F2u) {
            uint32_t base = (instruction >> 5) & 0x1Fu;
            uint32_t destination = instruction & 0x1Fu;
            ptrdiff_t offset = static_cast<ptrdiff_t>((instruction >> 7) & 0x7FF8u);

            if (base < 31 && offset >= 0x400 && (knownRegisters & (1u << base))) {
                return offset;
            }

            if ((instruction & 0x00400000u) && destination < 31) {
                knownRegisters &= ~(1u << destination);
            }
        }
    }

    return -1;
}

static int FindPrimaryCallbackSlot(void **record, size_t slotCount)
{
    if (!record) return -1;
    for (size_t slot = 0; slot < slotCount; slot++) {
        uintptr_t function = reinterpret_cast<uintptr_t>(StripCode(record[slot]));
        if (!IsExecutableAddress(function)) continue;

        bool sawX7FromX5 = false;
        bool sawX20FromX6 = false;
        bool sawSIMDStore = false;
        bool sawByteStore = false;
        size_t instructionCount = 0x140 / 4;

        for (size_t index = 0; index < instructionCount; index++) {
            uint32_t instruction = 0;
            if (!ReadInstruction(function + index * 4, &instruction)) break;
            if (instruction == 0xAA0503F7u) sawX7FromX5 = true;
            else if (instruction == 0xAA0603F4u) sawX20FromX6 = true;
            else if (instruction == 0x2D0002E1u) sawSIMDStore = true;
            else if (instruction == 0x39000288u) sawByteStore = true;

            if (sawX7FromX5 && sawX20FromX6 && sawSIMDStore && sawByteStore) {
                return static_cast<int>(slot);
            }
            if (instruction == kRET) break;
        }
    }
    return -1;
}

static int FindSecondaryCallbackSlot(void **record, size_t slotCount)
{
    if (!record || slotCount < 2) return -1;

    for (size_t slot = 0; slot + 1 < slotCount; slot++) {
        uintptr_t function = reinterpret_cast<uintptr_t>(StripCode(record[slot]));
        if (!IsExecutableAddress(function)) continue;
        uint32_t expected = static_cast<uint32_t>(slot + 1);

        for (size_t current = 0; current < 23; current++) {
            uint32_t instruction = 0;
            if (!ReadInstruction(function + current * 4, &instruction)) break;
            if (instruction == kRET) break;

            if (instruction == 0xF9400008u) {
                uint32_t next = 0;
                if (!ReadInstruction(function + 4, &next)) break;
                if ((next & 0xFFC003FFu) == 0xF9400108u &&
                    ((next >> 10) & 0xFFFu) == expected) {
                    bool sawBranchX16 = false;
                    for (size_t byteOffset = 8; byteOffset < 0x40; byteOffset += 4) {
                        uint32_t candidate = 0;
                        if (!ReadInstruction(function + byteOffset, &candidate)) break;
                        if ((candidate & 0xFFDFFFFFu) == 0xD61F0200u) sawBranchX16 = true;
                        if (candidate == 0xD61F0200u || candidate == 0xD63F0200u || candidate == kRET) break;
                    }
                    if (sawBranchX16) return static_cast<int>(expected);
                }
            }

            if (instruction == 0xF9400010u) {
                size_t firstLimit = (current < 13 ? current : 13) + 10;
                bool foundLoad = false;
                size_t matched = 0;
                for (size_t index = 1; index < firstLimit; index++) {
                    uint32_t candidate = 0;
                    if (!ReadInstruction(function + index * 4, &candidate)) break;
                    if ((candidate & 0xFFE00FFFu) != 0xF8400E08u) continue;
                    if (((candidate >> 15) & 0x3Fu) != expected) break;
                    foundLoad = true;
                    matched = index;
                    break;
                }
                if (!foundLoad) continue;

                size_t secondLimit = (matched < 14 ? matched : 14) + 10;
                for (size_t index = matched + 1; index < secondLimit; index++) {
                    uint32_t candidate = 0;
                    if (!ReadInstruction(function + index * 4, &candidate)) break;
                    if (((candidate | 0x00200000u) >> 11) == 0x001AE7E1u) {
                        return static_cast<int>(expected);
                    }
                    if (candidate == kRET) break;
                }
            }
        }
    }

    return -1;
}

static id<MTLRenderPipelineState> PipelineForDevice(id<MTLDevice> device, MTLPixelFormat pixelFormat)
{
    if (!device || pixelFormat == MTLPixelFormatInvalid) return nil;

    os_unfair_lock_lock(&gPipelineLock);
    if (gPipelineState && gPipelineDevice == device && gPipelineFormat == pixelFormat) {
        id<MTLRenderPipelineState> existing = gPipelineState;
        os_unfair_lock_unlock(&gPipelineLock);
        return existing;
    }

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:kGlassShaderSourceUTF8] options:nil error:&error];
    if (!library) {
        os_unfair_lock_unlock(&gPipelineLock);
        return nil;
    }

    id<MTLFunction> vertex = [library newFunctionWithName:@"rhGlassVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"rhGlassFragment"];
    if (!vertex || !fragment) {
        os_unfair_lock_unlock(&gPipelineLock);
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;

    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline) {
        gPipelineDevice = device;
        gPipelineFormat = pixelFormat;
        gPipelineState = pipeline;
    }
    os_unfair_lock_unlock(&gPipelineLock);
    return pipeline;
}

static bool ValidateTextures(id<MTLTexture> source, id<MTLTexture> output, id<MTLDevice> callbackDevice)
{
    if (!source || !output || !callbackDevice) return false;
    if (source.device != output.device || output.device != callbackDevice) return false;
    if (!(output.usage & MTLTextureUsageRenderTarget)) return false;
    if (output.pixelFormat == MTLPixelFormatInvalid) return false;

    NSUInteger sw = source.width, sh = source.height;
    NSUInteger ow = output.width, oh = output.height;
    if (!sw || !sh || !ow || !oh || sw > 16384 || sh > 16384 || ow > 16384 || oh > 16384) return false;

    auto dimensionCompatible = [](NSUInteger sourceSize, NSUInteger outputSize) {
        if (outputSize >= sourceSize) return (outputSize - sourceSize) < 65;
        return (sourceSize - outputSize) < 9;
    };
    return dimensionCompatible(sw, ow) && dimensionCompatible(sh, oh);
}

static bool RenderGlass(id<MTLDevice> device, void *renderContext, void *sourceWrapper)
{
    if (!device || !renderContext || !sourceWrapper || gCommandContextOffset < 0 || !gStopEncoders) return false;

    void *sourceRaw = *reinterpret_cast<void **>(reinterpret_cast<uint8_t *>(sourceWrapper) + 0x58);
    void *outputNode = *reinterpret_cast<void **>(reinterpret_cast<uint8_t *>(renderContext) + 0x110);
    if (!sourceRaw || !outputNode) return false;
    void *outputRaw = *reinterpret_cast<void **>(reinterpret_cast<uint8_t *>(outputNode) + 0x58);
    if (!outputRaw) return false;

    __unsafe_unretained id<MTLTexture> sourceTexture = (__bridge id<MTLTexture>)sourceRaw;
    __unsafe_unretained id<MTLTexture> outputTexture = (__bridge id<MTLTexture>)outputRaw;
    if (!ValidateTextures(sourceTexture, outputTexture, device)) return false;

    id<MTLRenderPipelineState> pipeline = PipelineForDevice(device, outputTexture.pixelFormat);
    if (!pipeline) return false;

    void *commandContextRaw = *reinterpret_cast<void **>(reinterpret_cast<uint8_t *>(renderContext) + gCommandContextOffset);
    if (!commandContextRaw) return false;
    __unsafe_unretained id commandContext = (__bridge id)commandContextRaw;
    SEL encoderSelector = NSSelectorFromString(@"renderCommandEncoderWithDescriptor:");
    if (![commandContext respondsToSelector:encoderSelector]) return false;

    StopEncodersFn stopEncoders = reinterpret_cast<StopEncodersFn>(SignCode(gStopEncoders));
    if (!stopEncoders) return false;
    stopEncoders(renderContext);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = outputTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    using EncoderMessageFn = id<MTLRenderCommandEncoder> (*)(id, SEL, MTLRenderPassDescriptor *);
    EncoderMessageFn encoderMessage = reinterpret_cast<EncoderMessageFn>(objc_msgSend);
    id<MTLRenderCommandEncoder> encoder = encoderMessage(commandContext, encoderSelector, pass);
    if (!encoder) return false;

    GlassUniforms uniforms = {};
    uniforms.sourceSize = { static_cast<float>(sourceTexture.width), static_cast<float>(sourceTexture.height) };
    uniforms.outputSize = { static_cast<float>(outputTexture.width), static_cast<float>(outputTexture.height) };
    uniforms.radius = 0.5f * fminf(uniforms.outputSize.x, uniforms.outputSize.y);
    uniforms.bezelWidth = fminf(34.0f, fmaxf(10.0f, uniforms.outputSize.y * 0.30f));
    uniforms.refractionScale = 0.58f;
    uniforms.refractiveIndex = 1.13f;
    uniforms.dispersionStrength = 0.20f;
    uniforms.diffusionStrength = 0.16f;
    uniforms.darkEdgeStrength = 0.075f;
    uniforms.specularStrength = 0.12f;
    uniforms.backdropZoom = 1.012f;

    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:sourceTexture atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return true;
}

static void CallOriginalSecondary(void *x0, void *filterContext, id<MTLDevice> device,
                                  void *renderContext, float scalar0, void *sourceWrapper,
                                  void *x5, void *x6, void *x7, void *stackArgument)
{
    GlassCallbackFn original = reinterpret_cast<GlassCallbackFn>(SignCode(gOriginalSecondary));
    if (original) {
        original(x0, filterContext, device, renderContext, scalar0,
                 sourceWrapper, x5, x6, x7, stackArgument);
    }
}

extern "C" uintptr_t RHGlassRecordMarker(void)
{
    return 0;
}

extern "C" void RHGlassRenderCallback(void *x0, void *filterContext, id<MTLDevice> device,
                                      void *renderContext, float scalar0, void *sourceWrapper,
                                      void *x5, void *x6, void *x7, void *stackArgument)
{
    if (!filterContext || !device || !renderContext || !sourceWrapper) {
        CallOriginalSecondary(x0, filterContext, device, renderContext, scalar0,
                              sourceWrapper, x5, x6, x7, stackArgument);
        return;
    }

    uint32_t activeAtom = *reinterpret_cast<uint32_t *>(reinterpret_cast<uint8_t *>(filterContext) + 0x18);
    if (activeAtom != gCustomAtom) {
        CallOriginalSecondary(x0, filterContext, device, renderContext, scalar0,
                              sourceWrapper, x5, x6, x7, stackArgument);
        return;
    }

    @autoreleasepool {
        if (RenderGlass(device, renderContext, sourceWrapper)) return;
    }

    CallOriginalSecondary(x0, filterContext, device, renderContext, scalar0,
                          sourceWrapper, x5, x6, x7, stackArgument);
}

static void ScheduleRegistrationRetry(void);

static void RegisterGlassFilter(void)
{
    if (gRegistered) return;
    if (!LoadQuartzCoreImage()) return;

    if (!gCAInternAtom) gCAInternAtom = ResolveCAInternAtom();
    if ((!gAddFilter || !gGaussianRecordSlot || !gFilterRegistrySlot) && !ResolveAddFilterInternals()) return;
    if (!gStopEncoders) gStopEncoders = ResolveStopEncoders();
    if (gCommandContextOffset < 0) gCommandContextOffset = ResolveCommandContextOffset();

    if (!gCAInternAtom || !gAddFilter || !gGaussianRecordSlot || !gFilterRegistrySlot ||
        !gStopEncoders || gCommandContextOffset < 0x400 || gCommandContextOffset > 0x4000) {
        return;
    }

    if (!*gFilterRegistrySlot) {
        ScheduleRegistrationRetry();
        return;
    }

    void *gaussianRecordRaw = *gGaussianRecordSlot;
    void **gaussianRecord = reinterpret_cast<void **>(StripData(gaussianRecordRaw));
    if (!gaussianRecord) return;

    int primarySlot = FindPrimaryCallbackSlot(gaussianRecord, kGaussianRecordSlots);
    int secondarySlot = FindSecondaryCallbackSlot(gaussianRecord, kGaussianRecordSlots);
    if (primarySlot < 0 || primarySlot >= static_cast<int>(kGaussianRecordSlots) ||
        secondarySlot < 0 || secondarySlot >= static_cast<int>(kGaussianRecordSlots) ||
        primarySlot == secondarySlot) {
        return;
    }

    // Mango's primary replacement is a pure tail-forwarder. Keeping the cloned
    // Gaussian primary pointer unchanged is ABI-equivalent and avoids inventing
    // a private prototype. Only the custom secondary renderer is replaced.
    gOriginalSecondary = StripCode(gaussianRecord[secondarySlot]);
    if (!gOriginalSecondary) return;

    CAInternAtomFn internAtom = reinterpret_cast<CAInternAtomFn>(SignCode(gCAInternAtom));
    AddFilterFn addFilter = reinterpret_cast<AddFilterFn>(SignCode(gAddFilter));
    if (!internAtom || !addFilter) return;

    uint32_t customAtom = internAtom(kCustomFilterType);
    uint32_t gaussianAtom = internAtom("gaussianBlur");
    if (!customAtom || !gaussianAtom || customAtom == gaussianAtom) return;

    void **clonedRecord = reinterpret_cast<void **>(mmap(nullptr, kGaussianRecordSize,
                                                         PROT_READ | PROT_WRITE,
                                                         MAP_PRIVATE | MAP_ANON, -1, 0));
    if (clonedRecord == MAP_FAILED) return;
    memcpy(clonedRecord, gaussianRecord, kGaussianRecordSize);

    clonedRecord[0] = StripCode(reinterpret_cast<void *>(&RHGlassRecordMarker));
    clonedRecord[secondarySlot] = StripCode(reinterpret_cast<void *>(&RHGlassRenderCallback));

    void **wrapper = reinterpret_cast<void **>(mmap(nullptr, 0x100,
                                                    PROT_READ | PROT_WRITE,
                                                    MAP_PRIVATE | MAP_ANON, -1, 0));
    if (wrapper == MAP_FAILED) {
        munmap(clonedRecord, kGaussianRecordSize);
        return;
    }
    memset(wrapper, 0, 0x100);
    wrapper[0] = clonedRecord;

    gCustomAtom = customAtom;
    addFilter(customAtom, wrapper);
    gRegistered = true;
}

static void ScheduleRegistrationRetry(void)
{
    if (gRegistered || gRetryScheduled) return;
    gRetryScheduled = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        gRetryScheduled = false;
        RegisterGlassFilter();
    });
}

} // namespace

__attribute__((constructor)) static void RootHideGlassRendererInitialize(void)
{
    @autoreleasepool {
        if (!IsBackboardd()) return;
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion != 16) return;
        RegisterGlassFilter();
    }
}
