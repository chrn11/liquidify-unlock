#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

%hook CCLiquidGlassView

// ============ 核心: 液态玻璃构建入口 ============
- (void)cc_dispatchGlassBuildWithTextRect:(CGRect)textRect
                               canvasRect:(CGRect)canvasRect
                                   isDark:(BOOL)isDark
                                    style:(NSInteger)style
                       displacementFactor:(double)displacementFactor {
    if (displacementFactor <= 0.0) {
        displacementFactor = 1.0;
    }
    %orig;
}

// ============ Q 点: 玻璃填充外观 ============
- (void)cc_applyGlassFillAppearance {
    %orig;
}

// ============ C 点: 折射强度 ============
- (void)cc_applyGlassRefractionStrength {
    %orig;
}

// ============ 填充色兜底 ============
- (UIColor *)cc_currentGlassFillColor {
    UIColor *color = %orig;
    if (!color) {
        color = [UIColor colorWithWhite:1.0 alpha:0.12];
    }
    return color;
}

// ============ 强制网格开启 ============
- (void)setMeshEnabled:(BOOL)enabled {
    %orig(YES);
}

- (BOOL)meshEnabled {
    return YES;
}

- (BOOL)cc_hasGlassContent {
    return YES;
}

%end

%hook CCLiquidGlassLabel

- (void)cc_dispatchGlassBuildWithTextRect:(CGRect)textRect
                               canvasRect:(CGRect)canvasRect
                                   isDark:(BOOL)isDark
                                    style:(NSInteger)style
                       displacementFactor:(double)displacementFactor {
    if (displacementFactor <= 0.0) {
        displacementFactor = 1.0;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // marker 验证加载
        NSString *status = @"loaded";
        [status writeToFile:@"/var/mobile/Documents/liquidify_unlock_status.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSLog(@"[LiquidifyUnlock] Loaded");
}
