#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// Safe value-override hooks based on 2026-09-06 reverse engineering.
// Root cause: DRM/pref layer feeds 0 -> gates judge 0 -> skip liquid conversion -> transparent.
// Strategy: only override return values of getters; void methods pass through %orig.

static double LQFallbackDisplacement = 16.0; // plugin's own default (FMOV D0,#16.0)
static double LQMinOpacity = 0.55;

%hook CCLiquidGlassLabel

// Displacement gate (0x591a54 b.le): compares cached value vs new pref value.
// DRM zeroes pref AND cache -> diff 0 -> dispatchGlassBuild always skipped.
// Hook: return 16.0 when cache < 1.0 -> diff always > epsilon -> build always runs.
- (double)cachedDisplacementFactor {
    double v = %orig;
    if (v < 1.0) {
        return LQFallbackDisplacement;
    }
    return v;
}

// Main liquid conversion entry: force default displacement when zeroed by DRM.
- (void)cc_dispatchGlassBuildWithTextRect:(CGRect)textRect
                               canvasRect:(CGRect)canvasRect
                                   isDark:(BOOL)isDark
                                    style:(NSInteger)style
                       displacementFactor:(double)displacementFactor {
    if (displacementFactor <= 0.5) {
        displacementFactor = LQFallbackDisplacement;
    }
    %orig;
}

%end

%hook CCLiquidGlassView

// Q-point internal gate: fill pipeline blocked by cachedShellPrepared == 0.
- (BOOL)cachedShellPrepared {
    return YES;
}

// C-point internal gate: refraction pipeline blocked by cachedMeshEnabled == 0.
- (BOOL)cachedMeshEnabled {
    return YES;
}

// Fill color fallback when DRM returns nil.
- (UIColor *)cc_currentGlassFillColor {
    UIColor *color = %orig;
    if (!color) {
        color = [UIColor colorWithWhite:1.0 alpha:0.12];
    }
    return color;
}

// FrostedGlassOpacity default is 0.0 (movi d0,#0) - the direct "always transparent" source.
- (void)cc_applyFrostedBackdropOpacity:(double)opacity {
    if (opacity < 0.1) {
        opacity = LQMinOpacity;
    }
    %orig;
}

// Final conversion methods called at Q/C points: gates opened above, pass through.
- (void)cc_applyGlassFillAppearance {
    %orig;
}

- (void)cc_applyGlassRefractionStrength {
    %orig;
}

- (void)cc_applyBackdropBlurRadius {
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // marker to verify loading
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *status = [NSString stringWithFormat:@"loaded %@", bid];
        [status writeToFile:@"/var/mobile/Documents/liquidify_unlock_status.txt"
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSLog(@"[LiquidifyUnlock] Loaded");
}
