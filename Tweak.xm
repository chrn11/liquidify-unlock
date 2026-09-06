%hook CCLiquidGlassView

// ============ 核心: 液态玻璃构建入口 ============
// 签名: v100@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16{CGRect={CGPoint=dd}{CGSize=dd}}48B80q84d92
// displacementFactor (d92) 传 0 → 玻璃透明无液态效果
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

- (void)cc_applyGlassFillAppearance {
    %orig;
}

- (void)cc_applyGlassRefractionStrength {
    %orig;
}

%end

%ctor {
    NSLog(@"[LiquidifyUnlock] Loaded");
}
