#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// ============ 诊断版: 全方法参数日志 ============
// 目标: 搞清 SpringBoard/widget 进程里哪些方法被调、参数是什么、DRM 把什么清零了

static int LQCallCount = 0;

%hook CCLiquidGlassLabel

- (double)cachedDisplacementFactor {
    double v = %orig;
    NSLog(@"[LQ] Label.cachedDisplacementFactor = %f", v);
    if (v < 1.0) {
        return 16.0;
    }
    return v;
}

- (void)cc_dispatchGlassBuildWithTextRect:(CGRect)textRect
                               canvasRect:(CGRect)canvasRect
                                   isDark:(BOOL)isDark
                                    style:(NSInteger)style
                       displacementFactor:(double)displacementFactor {
    NSLog(@"[LQ] Label.dispatchGlassBuild df=%f isDark=%d style=%ld", displacementFactor, isDark, (long)style);
    if (displacementFactor <= 0.5) {
        displacementFactor = 16.0;
        NSLog(@"[LQ]   -> df forced to 16.0");
    }
    %orig;
}

%end

%hook CCLiquidGlassView

- (BOOL)cachedShellPrepared {
    BOOL v = %orig;
    NSLog(@"[LQ] View.cachedShellPrepared = %d", v);
    return YES;
}

- (BOOL)cachedMeshEnabled {
    BOOL v = %orig;
    NSLog(@"[LQ] View.cachedMeshEnabled = %d", v);
    return YES;
}

- (UIColor *)cc_currentGlassFillColor {
    UIColor *c = %orig;
    NSLog(@"[LQ] View.currentGlassFillColor = %@", c);
    if (!c) {
        c = [UIColor colorWithWhite:1.0 alpha:0.12];
    }
    return c;
}

- (void)cc_applyFrostedBackdropOpacity:(double)opacity {
    NSLog(@"[LQ] View.applyFrostedBackdropOpacity = %f", opacity);
    if (opacity < 0.1) {
        opacity = 0.55;
        NSLog(@"[LQ]   -> opacity forced to 0.55");
    }
    %orig;
}

- (void)cc_applyGlassFillAppearance {
    LQCallCount++;
    if (LQCallCount <= 20) NSLog(@"[LQ] View.applyGlassFillAppearance #%d", LQCallCount);
    %orig;
}

- (void)cc_applyGlassRefractionStrength {
    static int n = 0;
    n++;
    if (n <= 20) NSLog(@"[LQ] View.applyGlassRefractionStrength #%d", n);
    %orig;
}

- (void)cc_applyBackdropBlurRadius {
    static int n = 0;
    n++;
    if (n <= 20) NSLog(@"[LQ] View.applyBackdropBlurRadius #%d", n);
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSLog(@"[LiquidifyUnlock] DIAG ctor in %@", bid);
    }
}
