#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
extern "C" Ivar *class_copyIvarList(Class cls, unsigned int *outCount);


// LiquidifyUnlock QC — 用户思路的最终形态:
// Q 点 (cc_applyGlassFillAppearance) 和 C 点 (cc_applyGlassRefractionStrength/cc_applyBackdropBlurRadius)
// 执行液态转换, 但 "传参进不去" (ivar 里的强度/模糊值全 0) → 渲染成透明.
// 本 tweak hook 这两个方法, 在原实现运行前把 self 的参数 ivar 强制写为有效值
// (来自用户设置的真实偏好: 强度 20 / 模糊 5 / 不透明度 0.85).
// 磁盘零修改, 与 GlassFix 共存.

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
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[LiquidifyUnlock] QC ivar-fill tweak loaded");
    }
}
