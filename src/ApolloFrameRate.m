#import "ApolloFrameRate.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

// The display's top rate, or 0 when it has nothing above 60 Hz to ask for.
static float ApolloFullFrameRateMaximum(void) {
    float maximum = (float)UIScreen.mainScreen.maximumFramesPerSecond;
    return maximum > 60.0f ? maximum : 0.0f;
}

void ApolloAnimationUsesFullFrameRate(CAAnimation *animation) {
    if (@available(iOS 15.0, *)) {
        float maximum = ApolloFullFrameRateMaximum();
        if (maximum > 0) animation.preferredFrameRateRange = CAFrameRateRangeMake(MIN(80.0f, maximum), maximum, maximum);
    }
}

// A display link that does no work holds the rate; its frame count logs the
// rate a drag got.
@interface ApolloFullFrameRateTicker : NSObject
@property(nonatomic) NSUInteger frames;
@property(nonatomic) CFTimeInterval first, last;
@end

@implementation ApolloFullFrameRateTicker
- (void)tick:(CADisplayLink *)link {
    if (!self.frames) self.first = link.timestamp;
    self.last = link.timestamp;
    self.frames++;
}
@end

static CADisplayLink *sFullFrameRateLink;
static ApolloFullFrameRateTicker *sFullFrameRateTicker;
static NSUInteger sFullFrameRateHolds, sFullFrameRateGeneration;

void ApolloFullFrameRateBegin(void) {
    if (!NSThread.isMainThread) return;
    sFullFrameRateHolds++;
    // A new drag during the previous one's tail keeps the same link.
    sFullFrameRateGeneration++;
    if (sFullFrameRateLink) return;
    if (@available(iOS 15.0, *)) {
        float maximum = ApolloFullFrameRateMaximum();
        if (maximum <= 0) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                ApolloLog(@"[FrameRate] display max %ld fps: nothing above 60 Hz to hold",
                          (long)UIScreen.mainScreen.maximumFramesPerSecond);
            });
            return;
        }
        sFullFrameRateTicker = [ApolloFullFrameRateTicker new];
        sFullFrameRateLink = [CADisplayLink displayLinkWithTarget:sFullFrameRateTicker selector:@selector(tick:)];
        sFullFrameRateLink.preferredFrameRateRange = CAFrameRateRangeMake(MIN(80.0f, maximum), maximum, maximum);
        [sFullFrameRateLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

void ApolloFullFrameRateEnd(NSTimeInterval tail) {
    if (!NSThread.isMainThread || sFullFrameRateHolds == 0) return;
    if (--sFullFrameRateHolds) return;
    NSUInteger generation = ++sFullFrameRateGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, tail) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sFullFrameRateGeneration || sFullFrameRateHolds || !sFullFrameRateLink) return;
        ApolloFullFrameRateTicker *ticker = sFullFrameRateTicker;
        CFTimeInterval span = ticker.last - ticker.first;
        ApolloLog(@"[FrameRate] drag held the full rate for %.2fs at %.0f fps (display max %ld)", span,
                  span > 0 && ticker.frames > 1 ? (ticker.frames - 1) / span : 0.0,
                  (long)UIScreen.mainScreen.maximumFramesPerSecond);
        [sFullFrameRateLink invalidate];
        sFullFrameRateLink = nil;
        sFullFrameRateTicker = nil;
    });
}

static char kApolloFullFrameRateHeldKey;

void ApolloFullFrameRateFollowGesture(UIGestureRecognizer *gesture, NSTimeInterval tail) {
    if (!gesture) return;
    BOOL held = objc_getAssociatedObject(gesture, &kApolloFullFrameRateHeldKey) != nil;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            if (held) return;
            objc_setAssociatedObject(gesture, &kApolloFullFrameRateHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloFullFrameRateBegin();
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (!held) return;
            objc_setAssociatedObject(gesture, &kApolloFullFrameRateHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloFullFrameRateEnd(tail);
            break;
        default:
            break;
    }
}
