#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <string.h>
#import <stdint.h>
#import <stddef.h>
#import <libkern/OSCacheControl.h>

// LiquidifyUnlock — 图中方案：不修改 Liquidify.dylib 任何字节。
// 运行时 Hook 授权校验函数 SecKeyVerifySignature，强制返回 errSecSuccess(0)。

typedef int OSStatus;

typedef OSStatus (*SecKeyVerifySignature_t)(void *key, void *algorithm,
                                            void *signedData, void *signature);

static SecKeyVerifySignature_t LQOrigVerify = NULL;

static OSStatus LQHookedVerify(void *key, void *algorithm,
                               void *signedData, void *signature) {
    NSLog(@"[LiquidifyUnlock] SecKeyVerifySignature intercepted -> errSecSuccess");
    return 0; // errSecSuccess — 授权恒成功
}

static void LQLog(NSString *s) {
    NSLog(@"[LiquidifyUnlock] %@", s);
}

// 通用 arm64 inline hook (trampoline): 与 substrate 无依赖, 只用 mprotect + 绝对跳转。
// 布局: 原函数前 4 条指令搬走, 前部写 adrp x16 + add + br x16 跳到 hook。
// 对 Apple 系统 PAC 代码 (arm64e) 使用 braa 形式以保持签名兼容。
static BOOL LQMakeCodeWritable(uintptr_t addr, size_t len) {
    // iOS: __TEXT 页需要 vm_protect + VM_PROT_COPY (COW); mprotect 会 EPERM。
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)addr,
                                  (vm_size_t)len, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) return YES;
    // 兜底
    return mprotect((void *)addr, len, PROT_READ | PROT_WRITE | PROT_EXEC) == 0;
}

static void LQMakeCodeExec(uintptr_t addr, size_t len) {
    vm_protect(mach_task_self(), (vm_address_t)addr, (vm_size_t)len, FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);
}

static BOOL LQHookFunction(void *target, void *replacement, void **orig) {
    if (!target || !replacement) return NO;

    size_t ps = 4096;
    uintptr_t page = (uintptr_t)target & ~(uintptr_t)(ps - 1);
    uintptr_t page2 = ((uintptr_t)target + 32) & ~(uintptr_t)(ps - 1);
    size_t cover = ps + (page2 != page ? ps : 0);
    if (!LQMakeCodeWritable(page, cover)) {
        LQLog(@"vm_protect failed");
        return NO;
    }

    // 保存原始 4 条指令到 trampoline (16 字节) + 绝对跳回
    uint8_t *t = (uint8_t *)target;
    uint8_t *tramp = (uint8_t *)malloc(64);
    if (!tramp) return NO;
    memcpy(tramp, t, 16);                                   // 原前 4 条指令
    // br 指令: B .+ imm26  跳到 target+16
    int32_t off = (int32_t)(((intptr_t)t + 16 - (intptr_t)(tramp + 16)) / 4);
    uint32_t br = 0x14000000u | ((uint32_t)off & 0x03FFFFFFu);
    memcpy(tramp + 16, &br, 4);                             // 跳回 target+16
    // icache
    sys_icache_invalidate(tramp, 20);
    *orig = tramp;

    // 原函数头部: adrp x16, hook; add x16, x16, #lo; br x16  (16字节, 无 PAC 需求)
    // arm64e PAC: 系统 libSystem 函数入口本身非 PAC 保护 (dyld stub 已 braa 过),
    // 这里写普通 adrp+add+br 足够 (ElleKit/Substitute 同款做法)。
    uintptr_t hookAddr = (uintptr_t)replacement;
    // adrp x16, imm — imm 为有符号 21 位页偏移
    int64_t delta = (int64_t)((hookAddr & ~(uintptr_t)0xFFF) -
                              ((uintptr_t)t & ~(uintptr_t)0xFFF)) / 4096;
    uint64_t imm = (uint64_t)delta & 0x1FFFFF;
    uint32_t adrp = 0x90000000u
                  | ((uint32_t)((imm >> 2) & 3) << 29)
                  | ((uint32_t)((imm >> 2) & 0x7FFFF) << 5)
                  | 16;
    uint32_t add = 0x91000210u | (((uint32_t)hookAddr & 0xFFF) << 10); // add x16,x16,#imm12
    uint32_t brx = 0xD61F0200u; // br x16
    uint32_t nops[1] = { 0xD503201Fu };

    memcpy(t, &adrp, 4);
    memcpy(t + 4, &add, 4);
    memcpy(t + 8, &brx, 4);
    memcpy(t + 12, nops, 4);
    sys_icache_invalidate(t, 16);

    if (page2 != page) LQMakeCodeExec(page2, ps);
    LQMakeCodeExec(page, ps);
    return YES;
}

__attribute__((constructor)) static void LQInit(void) {
    @autoreleasepool {
        LQLog(@"auth-hook tweak loaded (no binary patch)");
        void *sym = dlsym(RTLD_DEFAULT, "SecKeyVerifySignature");
        if (!sym) {
            sym = dlsym((void *)RTLD_NEXT, "SecKeyVerifySignature");
        }
        if (!sym) {
            // 显式加载 Security 框架再取
            void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
            if (sec) sym = dlsym(sec, "SecKeyVerifySignature");
        }
        if (!sym) {
            LQLog(@"SecKeyVerifySignature not found");
            return;
        }
        LQLog([NSString stringWithFormat:@"SecKeyVerifySignature @ %p", sym]);
        if (LQHookFunction(sym, (void *)LQHookedVerify, (void **)&LQOrigVerify)) {
            LQLog(@"hook installed");
        } else {
            LQLog(@"hook FAILED");
        }
    }
}
