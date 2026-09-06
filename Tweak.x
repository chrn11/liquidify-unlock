#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <unistd.h>
#import <libkern/OSCacheControl.h>
#import <stdint.h>
#include <string.h>

// Runtime-only patch. The installed Liquidify.dylib is never modified on disk.
// These are the verified arm64e Q/C points in Liquidify 1.3.7-4:
//   Q 0x30044c: cset w21, hi -> mov w21, #1
//   C 0x30165c: cset w8, lo  -> mov w8, #1

static const uintptr_t kQOffset = 0x30044c;
static const uintptr_t kCOffset = 0x30165c;
static const uint32_t kQOriginal = 0x1a9f97f5;
static const uint32_t kCOriginal = 0x1a9f27e8;
static const uint32_t kQPatch = 0x52800035; // mov w21, #1
static const uint32_t kCPatch = 0x52800028; // mov w8, #1

static void LQLog(NSString *message) {
    NSLog(@"[LiquidifyUnlock] %@", message);
}

static BOOL LQMakePageWritable(uintptr_t page, size_t pageSize) {
    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)page,
                                  (vm_size_t)pageSize,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) {
        return YES;
    }

    // Fallback for jailbreaks which expose mprotect instead of writable VM pages.
    return mprotect((void *)page, pageSize,
                    PROT_READ | PROT_WRITE | PROT_EXEC) == 0;
}

static void LQRestorePageExecutable(uintptr_t page, size_t pageSize) {
    vm_protect(mach_task_self(),
               (vm_address_t)page,
               (vm_size_t)pageSize,
               FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);
    // Ignore mprotect failure: vm_protect is the normal iOS path.
}

static BOOL LQPatchLiquidifyImage(const struct mach_header *header,
                                  intptr_t slide,
                                  const char *imageName) {
    if (!header || header->magic != MH_MAGIC_64 || !imageName) {
        return NO;
    }

    const struct mach_header_64 *machHeader =
        (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    const struct segment_command_64 *textSegment = NULL;

    for (uint32_t i = 0; i < machHeader->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)cursor;
            if (strcmp(segment->segname, "__TEXT") == 0) {
                textSegment = segment;
            }
        }
        cursor += command->cmdsize;
    }

    if (!textSegment) {
        LQLog([NSString stringWithFormat:@"no __TEXT segment in %s", imageName]);
        return NO;
    }

    // The addresses above are image VM addresses. Derive the image base rather
    // than assuming a particular ASLR slide or a particular mapped path.
    uintptr_t imageBase = (uintptr_t)header - (uintptr_t)textSegment->vmaddr;
    uintptr_t qAddress = imageBase + kQOffset;
    uintptr_t cAddress = imageBase + kCOffset;

    uintptr_t textStart = imageBase + (uintptr_t)textSegment->vmaddr;
    uintptr_t textEnd = textStart + (uintptr_t)textSegment->vmsize;
    if (qAddress < textStart || cAddress < textStart ||
        qAddress + sizeof(uint32_t) > textEnd ||
        cAddress + sizeof(uint32_t) > textEnd) {
        LQLog([NSString stringWithFormat:@"Q/C outside __TEXT in %s (slide=%p)",
               imageName, (void *)slide]);
        return NO;
    }

    uint32_t *qWord = (uint32_t *)qAddress;
    uint32_t *cWord = (uint32_t *)cAddress;
    uint32_t qCurrent = *qWord;
    uint32_t cCurrent = *cWord;

    // Idempotent: a second image-add callback must not write again.
    if (qCurrent == kQPatch && cCurrent == kCPatch) {
        LQLog([NSString stringWithFormat:@"Q/C already patched in %s", imageName]);
        return YES;
    }

    // Never touch an unexpected image version. This is deliberately strict.
    if (qCurrent != kQOriginal || cCurrent != kCOriginal) {
        LQLog([NSString stringWithFormat:
               @"Q/C signature mismatch in %s: Q=%08x C=%08x",
               imageName, qCurrent, cCurrent]);
        return NO;
    }

    size_t pageSize = (size_t)getpagesize();
    uintptr_t qPage = qAddress & ~(uintptr_t)(pageSize - 1);
    uintptr_t cPage = cAddress & ~(uintptr_t)(pageSize - 1);

    if (!LQMakePageWritable(qPage, pageSize)) {
        LQLog(@"cannot make Q page writable");
        return NO;
    }
    if (cPage != qPage && !LQMakePageWritable(cPage, pageSize)) {
        LQRestorePageExecutable(qPage, pageSize);
        LQLog(@"cannot make C page writable");
        return NO;
    }

    // Only these two instruction words are changed; no branch target or state
    // machine table is modified.
    *qWord = kQPatch;
    *cWord = kCPatch;
    sys_icache_invalidate((void *)qAddress, sizeof(uint32_t));
    sys_icache_invalidate((void *)cAddress, sizeof(uint32_t));

    LQRestorePageExecutable(qPage, pageSize);
    if (cPage != qPage) {
        LQRestorePageExecutable(cPage, pageSize);
    }

    LQLog([NSString stringWithFormat:
           @"Q/C patched in %s (Q=%p C=%p slide=%p)",
           imageName, (void *)qAddress, (void *)cAddress, (void *)slide]);
    return YES;
}

static void LQScanAndPatch(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/Liquidify.dylib")) {
            continue;
        }

        const struct mach_header *header = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (LQPatchLiquidifyImage(header, slide, name)) {
            return;
        }
    }
}

static void LQImageAdded(const struct mach_header *header, intptr_t slide) {
    if (!header) {
        return;
    }

    // Locate the matching image by header. The callback does not provide a path.
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        if (_dyld_get_image_header(i) != header) {
            continue;
        }
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/Liquidify.dylib")) {
            LQPatchLiquidifyImage(header, slide, name);
        }
        return;
    }
}

__attribute__((constructor)) static void LQInit(void) {
    @autoreleasepool {
        LQLog(@"runtime Q/C tweak loaded");
        // This also invokes the callback for images already loaded.
        _dyld_register_func_for_add_image(LQImageAdded);
        // Keep an explicit scan for loaders which register callbacks late.
        LQScanAndPatch();
    }
}
