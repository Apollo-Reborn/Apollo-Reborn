#import "ApolloPalHomeHaptics.h"
#import <UIKit/UIKit.h>
#import <CoreHaptics/CoreHaptics.h>

static void APImpact(UIImpactFeedbackStyle style, CGFloat intensity) {
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [generator impactOccurredWithIntensity:intensity];
}

static void APAfter(NSTimeInterval delay, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// A purr: a low, soft continuous rumble that swells and settles, with a
// little flutter. Core Haptics only; NO when it isn't available.
static BOOL APPurr(void) {
    if (@available(iOS 13.0, *)) {
        if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) return NO;
        static CHHapticEngine *engine;
        NSError *error = nil;
        if (!engine) {
            engine = [[CHHapticEngine alloc] initAndReturnError:&error];
            if (!engine) return NO;
            engine.playsHapticsOnly = YES;
            engine.autoShutdownEnabled = YES;
            __weak CHHapticEngine *weakEngine = engine;
            engine.resetHandler = ^{ [weakEngine startAndReturnError:nil]; };
        }
        if (![engine startAndReturnError:&error]) return NO;
        CHHapticEvent *rumble = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.32],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.08],
        ] relativeTime:0 duration:0.75];
        // Swell, flutter, settle.
        NSMutableArray *points = [NSMutableArray array];
        for (int i = 0; i <= 15; i++) {
            float t = i * 0.05f;
            float envelope = sinf((float)M_PI * MIN(1.0f, t / 0.75f));
            float flutter = (i % 2) ? 0.75f : 1.0f;
            [points addObject:[[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:t value:envelope * flutter]];
        }
        CHHapticParameterCurve *curve = [[CHHapticParameterCurve alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                                               controlPoints:points relativeTime:0];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[rumble] parameterCurves:@[curve] error:&error];
        id<CHHapticPatternPlayer> player = pattern ? [engine createPlayerWithPattern:pattern error:&error] : nil;
        return player && [player startAtTime:CHHapticTimeImmediate error:&error];
    }
    return NO;
}

void APHapticPlay(APHaptic haptic) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ APHapticPlay(haptic); });
        return;
    }
    switch (haptic) {
        case APHapticTap: APImpact(UIImpactFeedbackStyleLight, 0.55); break;
        case APHapticSelect: [[UISelectionFeedbackGenerator new] selectionChanged]; break;
        case APHapticToggle: APImpact(UIImpactFeedbackStyleRigid, 0.7); break;
        case APHapticPlace: APImpact(UIImpactFeedbackStyleMedium, 0.8); break;
        case APHapticRemove:
            APImpact(UIImpactFeedbackStyleLight, 0.6);
            APAfter(0.07, ^{ APImpact(UIImpactFeedbackStyleLight, 0.35); });
            break;
        case APHapticHop: APImpact(UIImpactFeedbackStyleSoft, 0.6); break;
        case APHapticThump: APImpact(UIImpactFeedbackStyleHeavy, 0.9); break;
        case APHapticPop:
            APImpact(UIImpactFeedbackStyleRigid, 1.0);
            APAfter(0.08, ^{ APImpact(UIImpactFeedbackStyleSoft, 0.5); });
            break;
        case APHapticPurr:
            if (!APPurr()) {
                for (int i = 0; i < 4; i++) APAfter(i * 0.09, ^{ APImpact(UIImpactFeedbackStyleSoft, 0.35 + (i % 2) * 0.15); });
            }
            break;
        case APHapticNom:
            for (int i = 0; i < 3; i++) APAfter(i * 0.14, ^{ APImpact(UIImpactFeedbackStyleSoft, 0.7 - i * 0.12); });
            break;
        case APHapticHeart:
            APImpact(UIImpactFeedbackStyleLight, 0.6);
            APAfter(0.1, ^{ APImpact(UIImpactFeedbackStyleRigid, 0.8); });
            break;
        case APHapticSuccess: [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess]; break;
        case APHapticNope: [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError]; break;
    }
}
