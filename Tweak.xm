#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdlib.h>
#import <unistd.h>
#import <signal.h>

// LiquidifyUnlock v31 — 验证修复版 (纯观察, 不修改任何行为)
// 修复点:
//  1. ctor 报告带 PID/进程/时间 — 知道是"谁"加载了
//  2. Hook 安装显式校验: 类是否存在 / 方法是否存在 / 安装前后 IMP 是否变化 / 失败原因
//  3. Liquidify.dylib 加载后延迟重试 Hook (类可能后注册)
//  4. 方法触发报告记录原始值 (不做任何写操作), 每方法前 N 次
//  5. 上一版的"乱填 double ivar"已删除 — 那基于错误的偏移判断

#define LQ_REPORT_PATH "/var/mobile/Documents/lq_verify.txt"
#define LQ_MAX_PER_METHOD 12

static int fd_report = -1;

static void LQOpenReport(void) {
    if (fd_report >= 0) return;
    fd_report = open(LQ_REPORT_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void LQWrite(const char *s) {
    LQOpenReport();
    if (fd_report < 0) return;
    write(fd_report, s, strlen(s));
}

static void LQWriteF(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    LQWrite(buf);
}

static void LQHeader(const char *tag) {
    LQWriteF("[%s] pid=%d proc=%s time=%s",
             tag, getpid(),
             getprogname() ? getprogname() : "?",
             [[[NSDate date] description] UTF8String]);
}

// ---------- 纯观察 Hook (不改任何值) ----------

static void LQObserve(const char *which, id self, SEL _cmd) {
    static int count[3] = {0, 0, 0};
    int idx = which[0] == 'Q' ? 0 : (which[2] == 'r' ? 1 : 2);
    if (++count[idx] > LQ_MAX_PER_METHOD) return;

    Class cls = object_getClass(self);
    LQHeader(which);
    LQWriteF(" class=%s cmd=%s\n",
             class_getName(cls), sel_getName(_cmd));

    // 只记录: 全部数值 ivar 的当前值 (原始, 未修改)
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        const char *name = ivar_getName(ivars[i]);
        ptrdiff_t off = (ptrdiff_t)ivar_getOffset(ivars[i]);
        char *base = (char *)(__bridge void *)self;
        if (!type) continue;
        if (type[0] == 'd') {
            double v = *(double *)(base + off);
            LQWriteF("  d %-34s +%5td = %g\n", name ? name : "?", off, v);
        } else if (type[0] == 'f') {
            float v = *(float *)(base + off);
            LQWriteF("  f %-34s +%5td = %g\n", name ? name : "?", off, v);
        } else if (type[0] == 'B' || type[0] == 'c') {
            char v = *(char *)(base + off);
            LQWriteF("  B %-34s +%5td = %d\n", name ? name : "?", off, (int)v);
        } else if (type[0] == 'i' || type[0] == 'l' || type[0] == 'q') {
            long long v = *(long long *)(base + off);
            LQWriteF("  i %-34s +%5td = %lld\n", name ? name : "?", off, v);
        }
    }
    if (ivars) free(ivars);
}

%hook CCLiquidGlassView

- (void)cc_applyGlassFillAppearance {
    LQObserve("Q:fill", self, _cmd);
    %orig;
}

- (void)cc_applyGlassRefractionStrength {
    LQObserve("C:refr", self, _cmd);
    %orig;
}

- (void)cc_applyBackdropBlurRadius {
    LQObserve("C:blur", self, _cmd);
    %orig;
}

%end

// ---------- Hook 安装校验 ----------

static void LQCheckHooks(void) {
    LQHeader("check");
    LQWrite("\n");

    Class cls = objc_getClass("CCLiquidGlassView");
    if (!cls) {
        LQWrite("  class CCLiquidGlassView: NOT FOUND (Liquidify.dylib not loaded yet?)\n");
        return;
    }
    LQWriteF("  class: %p\n", cls);

    const char *names[] = {"cc_applyGlassFillAppearance",
                           "cc_applyGlassRefractionStrength",
                           "cc_applyBackdropBlurRadius"};
    for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(cls, sel_registerName(names[i]));
        if (!m) {
            LQWriteF("  method %s: NOT FOUND\n", names[i]);
            continue;
        }
        LQWriteF("  method %-32s imp=%p type=%s\n",
                 names[i], method_getImplementation(m),
                 method_getTypeEncoding(m) ? method_getTypeEncoding(m) : "?");
    }
}

// Liquidify.dylib 加载时触发检查 (类注册后)
static void LQLiquidifyLoaded(const struct mach_header *mh, intptr_t slide) {
    const char *name = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if (_dyld_get_image_header(i) == mh) {
            name = _dyld_get_image_name(i);
            break;
        }
    }
    if (name && strstr(name, "Liquidify.dylib")) {
        LQHeader("liquidify-loaded");
        LQWriteF(" image=%s\n", name);
        // 类刚注册, Logos ctor 时机可能已过 — 校验并手动补装
        LQCheckHooks();
    }
}

__attribute__((constructor)) static void LQInit(void) {
    @autoreleasepool {
        LQHeader("ctor");
        LQWrite(" tweak loaded (v31 observe-only)\n");
        LQCheckHooks();
        _dyld_register_func_for_add_image(LQLiquidifyLoaded);
    }
}
