#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// ==== 基于 2026-09-06 逆向结论的安全 Hook ====
// 根因: DRM/pref 层传参失败 → 恒 0 → 各 gate 判 0 → 跳过液态转换 → 透明
// 策略: 只覆盖"读"型方法的返回值, void 方法全部 %orig 原样放行
//       任何 hook 失败最多回到透明, 不会崩溃

static double LQFallbackDisplacement = 16.0;  // 插件自己的默认位移 (FMOV D0,#16.0)
static double LQMinOpacity = 0.55;            // 磨砂不透明度兜底

%hook CCLiquidGlassLabel

// Label 位移 gate (0x591a54 b.le 的根源):
// gate 比较 cachedDisplacementFactor 与新 pref 值, DRM 让 pref 恒 0 且缓存也 0
// → diff=0 → 永远跳过 dispatchGlassBuild。
// hook: 缓存值 < 1 时返回 16 → diff 恒大于 ε → build 必然执行
- (double)cachedDisplacementFactor {
    double v = %orig;
    if (v < 1.0) {
        return LQFallbackDisplacement;
    }
    return v;
}

// 液态转换主入口: displacementFactor <= 0.5 (DRM 清零) 时强制用默认值
- (void)cc_dispatchGlassBuildWithTextRect:(CGRect)textRect
                               canvasRect:(CGRect)canvasRect
                                   isDark:(BOOL)isDark
                                    style:(long)style
                       displacementFactor:(double)displacementFactor {
    if (displacementFactor <= 0.5) {
        displacementFactor = LQFallbackDisplacement;
    }
    %orig(textRect, canvasRect, isDark, style, displacementFactor);
}

%end

%hook CCLiquidGlassView

// Q 点内部 gate: fill 管线被 cachedShellPrepared=0 卡死 (0x2b4c18 → cmp → csel)
- (BOOL)cachedShellPrepared { return YES; }

// C 点内部 gate: refraction 管线被 cachedMeshEnabled=0 卡死 (0x2acba4 → cmp → csel)
- (BOOL)cachedMeshEnabled { return YES; }

// 填充色为 nil (DRM 拒发) 时给兜底色, 避免画透明
- (UIColor *)cc_currentGlassFillColor {
    UIColor *c = %orig;
    if (!c) {
        c = [UIColor colorWithWhite:1.0 alpha:0.12];
    }
    return c;
}

// FrostedGlassOpacity 的默认值是 0.0 (0x58f900 movi d0,#0) —
// "恒 0 → 透明模式"的最直接来源。应用端兜底。
- (void)cc_applyFrostedBackdropOpacity:(double)opacity {
    if (opacity < 0.1) {
        opacity = LQMinOpacity;
    }
    %orig(opacity);
}

// Q/C 点最终执行的三个转换方法: gate 已被上面两个 hook 打开, 原样放行
- (void)cc_applyGlassFillAppearance { %orig; }
- (void)cc_applyGlassRefractionStrength { %orig; }
- (void)cc_applyBackdropBlurRadius { %orig; }

%end

%ctor {
    @autoreleasepool {
        // marker: 验证加载 (未注入时此文件不会出现)
        NSString *info = [NSString stringWithFormat:
            @"loaded pid=%d %@ %@\n",
            getpid(),
            [[NSBundle mainBundle] bundleIdentifier],
            [[NSDate date] description]];
        NSString *path = @"/var/mobile/Documents/liquidify_unlock_status.txt";
        NSFileHandle *fh = nil;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path
                contents:nil attributes:nil];
        }
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[info dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        NSLog(@"[LiquidifyUnlock] ctor done in %@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}
