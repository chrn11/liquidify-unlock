#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <fcntl.h>

static int LQReportCount = 0;
static void LQReport(const char *tag, Class cls, id selfObj) {
    if (cls && ++LQReportCount > 30) return;
    int fd = open("/var/mobile/Documents/lq_verify.txt", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char buf[512];
    if (cls && selfObj) {
        int n = snprintf(buf, sizeof(buf), "[%s] class=%s\n", tag, class_getName(cls));
        write(fd, buf, n);
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            const char *name = ivar_getName(ivars[i]);
            ptrdiff_t off = (ptrdiff_t)ivar_getOffset(ivars[i]);
            void *base = (__bridge void *)selfObj;
            if (type && type[0] == 'd') {
                double v = *(double *)((char *)base + off);
                n = snprintf(buf, sizeof(buf), "  d %s +%td = %f\n", name ? name : "?", off, v);
                write(fd, buf, n);
            } else if (type && type[0] == 'B') {
                BOOL v = *(BOOL *)((char *)base + off);
                n = snprintf(buf, sizeof(buf), "  B %s +%td = %d\n", name ? name : "?", off, (int)v);
                write(fd, buf, n);
            } else if (type && type[0] == 'f') {
                float v = *(float *)((char *)base + off);
                n = snprintf(buf, sizeof(buf), "  f %s +%td = %f\n", name ? name : "?", off, v);
                write(fd, buf, n);
            } else if (type && type[0] == 'i') {
                int v = *(int *)((char *)base + off);
                n = snprintf(buf, sizeof(buf), "  i %s +%td = %d\n", name ? name : "?", off, v);
                write(fd, buf, n);
            }
        }
        if (ivars) free(ivars);
    } else {
        int n = snprintf(buf, sizeof(buf), "[ctor] tweak loaded\n");
        write(fd, buf, n);
    }
    close(fd);
}

static double LQPrefDouble(NSString *key, double fallback) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.charlieleung.liquidify.plist"];
    id v = prefs[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    return fallback;
}

%hook CCLiquidGlassView

// Q 点: 玻璃填充外观 — 强制 opacity 参数 ivar 为用户设置值
- (void)cc_applyGlassFillAppearance {
    // ivar 扫描: 把 self 内 0.0 的 double ivar 全部补成有效值
    // (0x3d0 = frosted opacity, 通过运行时偏移探测 + 全量兜底)
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(self), &count);
    double opacity = LQPrefDouble(@"LiquidifyFrostedGlassOpacity", 0.85);
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == 'd') {
            ptrdiff_t off = (ptrdiff_t)ivar_getOffset(ivars[i]);
            double *slot = (double *)((uint8_t *)(__bridge void *)self + off);
            if (*slot == 0.0) {
                *slot = opacity;
            }
        }
    }
    if (ivars) free(ivars);
    LQReport("Q-fill", object_getClass(self), self);
    %orig;
}

// C 点: 折射强度 — 同样把 0 值强度/半径 ivar 补上
- (void)cc_applyGlassRefractionStrength {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(self), &count);
    double strength = LQPrefDouble(@"LiquidifyGlassRefractionStrength", 20.0);
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == 'd') {
            ptrdiff_t off = (ptrdiff_t)ivar_getOffset(ivars[i]);
            double *slot = (double *)((uint8_t *)(__bridge void *)self + off);
            if (*slot == 0.0) {
                *slot = strength;
            }
        }
    }
    if (ivars) free(ivars);
    LQReport("C-refr", object_getClass(self), self);
    %orig;
}

- (void)cc_applyBackdropBlurRadius {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(self), &count);
    double radius = LQPrefDouble(@"LiquidifyGlassBlurRadius", 5.0);
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == 'd') {
            ptrdiff_t off = (ptrdiff_t)ivar_getOffset(ivars[i]);
            double *slot = (double *)((uint8_t *)(__bridge void *)self + off);
            if (*slot == 0.0) {
                *slot = radius;
            }
        }
    }
    if (ivars) free(ivars);
    LQReport("C-blur", object_getClass(self), self);
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        LQReport("ctor", nil, nil);
        NSLog(@"[LiquidifyUnlock] QC ivar-fill tweak loaded");
    }
}
