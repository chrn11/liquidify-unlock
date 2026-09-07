#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <unistd.h>
#import <libkern/OSCacheControl.h>
#import <stdint.h>
#include <string.h>

// LiquidifyUnlock — runtime tweak for Liquidify 1.3.7-4 (arm64e).
// Disk file is never modified. Five verified, non-looping patch points:
//
//  0x2b4c68  csel w8,w13,w8,ne  -> orr w8,wzr,w13   SetA fill: cachedShellPrepared gate -> always K_true
//  0x2acef4  csel w8,w9, w8,ne  -> orr w8,wzr,w9    SetA refr: cachedMeshEnabled   gate -> always K_true
//  0x7169c4  cset w8,eq         -> mov w8,#1        DRM1: signature-verified flag forced true
//  0x7e7190  strb w0,[x19,#5]   -> strb wzr,[x19,#5] DRM2: OSStatus forced 0 (success)
//  0x591a54  b.le 0x591ad4      -> nop               Label gate: never skip cc_dispatchGlassBuild
//
// Q(0x30044c)/C(0x30165c) are deliberately NOT touched: Q is mathematically
// constant 0 (umull>>50 caps at ~32 vs 0xb631a05e) and forcing either sends the
// OLLVM dispatcher into an infinite self-loop (the earlier black screen).

typedef struct {
    uintptr_t offset;
    uint32_t expect;   // original instruction word, strict check
    uint32_t patch;    // replacement word
} LQPatch;

static const LQPatch kPatches[] = {
    { 0x2b4c68, 0x1a8811a8, 0x2a0d03e8 },
    { 0x2acef4, 0x1a881128, 0x2a0903e8 },
    { 0x7169c4, 0x1a9f17e8, 0x52800028 },
    { 0x7e7190, 0x39001660, 0x3900167f },
    { 0x591a54, 0x5400040d, 0xd503201f },
};
static const size_t kPatchCount = sizeof(kPatches) / sizeof(kPatches[0]);

static void LQLog(NSString *message) {
    NSLog(@"[LiquidifyUnlock] %@", message);
}

static BOOL LQMakeWritable(uintptr_t page, size_t pageSize) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page,
                                  (vm_size_t)pageSize, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) return YES;
    return mprotect((void *)page, pageSize,
                    PROT_READ | PROT_WRITE | PROT_EXEC) == 0;
}

static void LQRestoreExec(uintptr_t page, size_t pageSize) {
    vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)pageSize,
               FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
}

static BOOL LQPatchLiquidifyImage(const struct mach_header *header,
                                  intptr_t slide, const char *imageName) {
    if (!header || header->magic != MH_MAGIC_64 || !imageName) return NO;

    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    const struct segment_command_64 *text = NULL;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)cursor;
            if (strcmp(seg->segname, "__TEXT") == 0) text = seg;
        }
        cursor += cmd->cmdsize;
    }
    if (!text) return NO;

    uintptr_t base = (uintptr_t)header - (uintptr_t)text->vmaddr;
    uintptr_t textStart = base + (uintptr_t)text->vmaddr;
    uintptr_t textEnd = textStart + (uintptr_t)text->vmsize;

    // Strict pre-check of every original word on this image.
    for (size_t i = 0; i < kPatchCount; i++) {
        uintptr_t a = base + kPatches[i].offset;
        if (a < textStart || a + 4 > textEnd) return NO;
        uint32_t cur = *(uint32_t *)a;
        if (cur == kPatches[i].patch) {
            // Already applied (idempotent re-entry).
            continue;
        }
        if (cur != kPatches[i].expect) {
            LQLog([NSString stringWithFormat:
                   @"mismatch @%p: %08x != %08x (%s)",
                   (void *)a, cur, kPatches[i].expect, imageName]);
            return NO;
        }
    }

    size_t pageSize = (size_t)getpagesize();
    uintptr_t pages[8];
    size_t pageCount = 0;
    for (size_t i = 0; i < kPatchCount && pageCount < 8; i++) {
        uintptr_t p = (base + kPatches[i].offset) & ~(uintptr_t)(pageSize - 1);
        BOOL dup = NO;
        for (size_t j = 0; j < pageCount; j++) if (pages[j] == p) dup = YES;
        if (!dup) pages[pageCount++] = p;
    }
    for (size_t j = 0; j < pageCount; j++) {
        if (!LQMakeWritable(pages[j], pageSize)) {
            LQLog(@"page not writable");
            return NO;
        }
    }

    int applied = 0;
    for (size_t i = 0; i < kPatchCount; i++) {
        uintptr_t a = base + kPatches[i].offset;
        if (*(uint32_t *)a == kPatches[i].patch) continue;
        *(uint32_t *)a = kPatches[i].patch;
        sys_icache_invalidate((void *)a, sizeof(uint32_t));
        applied++;
    }

    for (size_t j = 0; j < pageCount; j++) LQRestoreExec(pages[j], pageSize);

    LQLog([NSString stringWithFormat:
           @"patched %d/%zu sites in %s (base=%p slide=%p)",
           applied, kPatchCount, imageName, (void *)base, (void *)slide]);
    return YES;
}

static void LQTryPatch(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/Liquidify.dylib")) continue;
        const struct mach_header *mh = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (LQPatchLiquidifyImage(mh, slide, name)) return;
    }
}

static void LQImageAdded(const struct mach_header *header, intptr_t slide) {
    if (!header) return;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) != header) continue;
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/Liquidify.dylib")) {
            LQPatchLiquidifyImage(header, slide, name);
        }
        return;
    }
}

__attribute__((constructor)) static void LQInit(void) {
    @autoreleasepool {
        LQLog(@"tweak loaded (5-point)");
        _dyld_register_func_for_add_image(LQImageAdded);
        LQTryPatch();
    }
}
