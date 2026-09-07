#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <stdint.h>
#import <libkern/OSCacheControl.h>

// LiquidifyUnlock v5 — 全授权链 hook (图方案加强版)
// Liquidify 的授权体系 (imports 实证):
//   ECDH 设备密钥对 + relay 服务器 (DP-token) + ECDSA 验签 + Keychain 票据
// 全部关键 Sec API 拦截为"授权成功"语义:
//   SecKeyVerifySignature        -> errSecSuccess (0)
//   SecKeyCopyKeyExchangeResult  -> 固定 32B 共享密钥 + 成功
//   SecItemCopyMatching          -> 票据存在时返回 errSecSuccess (不阻断读取)
//   SecItemAdd/SecItemUpdate     -> errSecSuccess
//   SecTrustEvaluateWithError    -> true (若被间接调用)
// 磁盘零修改。

static void LQLog(NSString *s) { NSLog(@"[LiquidifyUnlock] %@", s); }

// ---------- 通用 inline hook (vm_protect COW + adrp/add/br 跳板) ----------

static BOOL LQMakeWritable(uintptr_t addr, size_t len) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)addr,
                                  (vm_size_t)len, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

static void LQMakeExec(uintptr_t addr, size_t len) {
    vm_protect(mach_task_self(), (vm_address_t)addr, (vm_size_t)len, FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);
}

static void *LQTrampolineFor(void *target) {
    // 16B 原指令 + 跳回 target+16
    uint8_t *t = (uint8_t *)target;
    uint8_t *tramp = (uint8_t *)malloc(64);
    if (!tramp) return NULL;
    memcpy(tramp, t, 16);
    int32_t off = (int32_t)(((intptr_t)t + 16 - (intptr_t)(tramp + 16)) / 4);
    uint32_t br = 0x14000000u | ((uint32_t)off & 0x03FFFFFFu);
    memcpy(tramp + 16, &br, 4);
    sys_icache_invalidate(tramp, 20);
    return tramp;
}

static BOOL LQHookFunction(void *target, void *replacement, void **orig) {
    if (!target || !replacement) return NO;
    size_t ps = (size_t)getpagesize();
    uintptr_t page = (uintptr_t)target & ~(uintptr_t)(ps - 1);
    uintptr_t page2 = ((uintptr_t)target + 32) & ~(uintptr_t)(ps - 1);
    size_t cover = ps + (page2 != page ? ps : 0);
    if (!LQMakeWritable(page, cover)) { LQLog(@"vm_protect failed"); return NO; }
    if (orig) *orig = LQTrampolineFor(target);
    uintptr_t hookAddr = (uintptr_t)replacement;
    int64_t delta = (int64_t)((hookAddr & ~(uintptr_t)0xFFF) -
                              ((uintptr_t)target & ~(uintptr_t)0xFFF)) / 4096;
    uint64_t imm = (uint64_t)delta & 0x1FFFFF;
    uint32_t adrp = 0x90000000u
                  | ((uint32_t)((imm >> 2) & 3) << 29)
                  | ((uint32_t)((imm >> 2) & 0x7FFFF) << 5)
                  | 16;
    uint32_t add = 0x91000210u | (((uint32_t)hookAddr & 0xFFF) << 10);
    uint32_t brx = 0xD61F0200u;
    uint32_t nop = 0xD503201Fu;
    uint8_t *t = (uint8_t *)target;
    memcpy(t, &adrp, 4); memcpy(t + 4, &add, 4);
    memcpy(t + 8, &brx, 4); memcpy(t + 12, &nop, 4);
    sys_icache_invalidate(t, 16);
    if (page2 != page) LQMakeExec(page2, ps);
    LQMakeExec(page, ps);
    return YES;
}

// ---------- Hook 实现 ----------

static OSStatus (*OrigVerifySig)(void *, void *, void *, void *);
static OSStatus HookVerifySig(void *key, void *alg, void *data, void *sig) {
    return 0; // errSecSuccess
}

// SecKeyCopyKeyExchangeResult(algorithm, privateKey, publicKey, parameters, error**) -> CFData?
static void *(*OrigKeyExch)(void *, void *, void *, void *, void **);
static void *HookKeyExch(void *alg, void *priv, void *pub, void *params, void **err) {
    if (err) *err = NULL;
    // 返回固定 32 字节共享密钥 (CFData)
    static CFDataRef shared = NULL;
    if (!shared) {
        uint8_t bytes[32];
        memset(bytes, 0x42, sizeof(bytes));
        shared = CFDataCreate(NULL, bytes, sizeof(bytes));
    }
    return (void *)shared;
}

// SecItemCopyMatching(query, result*) -> OSStatus
static OSStatus (*OrigItemCopy)(void *, void *);
static OSStatus HookItemCopy(void *query, void *result) {
    OSStatus st = OrigItemCopy ? OrigItemCopy(query, result) : errSecItemNotFound;
    if (st == errSecItemNotFound || st != errSecSuccess) {
        // 票据不存在/读取失败: 谎报成功但 result 保持空 (上层拿 nil 走默认允许路径的常见模式)
        // 若上层强制要求非空, 此处可注入伪造 CFDictionary

        return errSecSuccess;
    }
    return st;
}

static OSStatus (*OrigItemAdd)(void *, void *);
static OSStatus HookItemAdd(void *attrs, void *result) { return errSecSuccess; }

static OSStatus (*OrigItemUpdate)(void *, void *);
static OSStatus HookItemUpdate(void *q, void *u) { return errSecSuccess; }

// SecTrustEvaluateWithError(trust, error**) -> bool
static bool (*OrigTrustEval)(void *, void **);
static bool HookTrustEval(void *trust, void **err) {
    if (err) *err = NULL;
    return true;
}

static void LQHookSym(const char *name, void *hook, void **orig) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) sym = dlsym((void *)RTLD_NEXT, name);
    if (!sym) { LQLog([NSString stringWithFormat:@"%@ not found", [NSString stringWithUTF8String:name]]); return; }
    if (LQHookFunction(sym, hook, orig)) {
        LQLog([NSString stringWithFormat:@"%@ hooked @ %p", [NSString stringWithUTF8String:name], sym]);
    } else {
        LQLog([NSString stringWithFormat:@"%@ hook FAILED", [NSString stringWithUTF8String:name]]);
    }
}

__attribute__((constructor)) static void LQInit(void) {
    @autoreleasepool {
        LQLog(@"auth-chain tweak v5 loaded");
        LQHookSym("SecKeyVerifySignature", (void *)HookVerifySig, (void **)&OrigVerifySig);
        LQHookSym("SecKeyCopyKeyExchangeResult", (void *)HookKeyExch, (void **)&OrigKeyExch);
        LQHookSym("SecItemCopyMatching", (void *)HookItemCopy, (void **)&OrigItemCopy);
        LQHookSym("SecItemAdd", (void *)HookItemAdd, (void **)&OrigItemAdd);
        LQHookSym("SecItemUpdate", (void *)HookItemUpdate, (void **)&OrigItemUpdate);
        LQHookSym("SecTrustEvaluateWithError", (void *)HookTrustEval, (void **)&OrigTrustEval);
        LQLog(@"auth-chain installed");
    }
}
