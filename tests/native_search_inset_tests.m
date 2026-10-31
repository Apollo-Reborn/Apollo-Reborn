#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// INCLUDE_PRODUCTION_TOP_RULE
static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static BOOL Near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.0001; }
// The rule as it was, against the table's safe area alone.
static CGFloat OldTop(CGFloat top, CGFloat safe, CGFloat band) {
    if (safe > 1.0 && top >= safe - kNSBBandSlack) {
        CGFloat extra = top - safe;
        top = (extra <= kNSBBandSlack) ? 0.0 : (extra - band);
        if (top < 0.0) top = 0.0;
    }
    return top;
}
int main(void) {
    @autoreleasepool {
        // Every case where the table and the screen agree (any write on
        // screen today) maps exactly as before.
        BOOL same = YES;
        for (CGFloat safe = 0; safe <= 260; safe += 6.5) {
            for (CGFloat top = -20; top <= 420; top += 3.5) {
                CGFloat now = NSBRelativizedTop(top, safe, safe > 1.0, 45);
                if (!Near(now, OldTop(top, safe, 45))) same = NO;
            }
        }
        Check(same, @"agreeing safe areas on screen: every write maps as before");
        Check(Near(NSBRelativizedTop(176 + 45, 176, YES, 45), 0) && Near(NSBRelativizedTop(159, 176, YES, 45), 0)
              && Near(NSBRelativizedTop(213, 176, YES, 45), 0) && Near(NSBRelativizedTop(0, 176, YES, 45), 0),
              @"resting writes (settled, active search, mid-morph, an echo) rest flush");
        Check(Near(NSBRelativizedTop(176 + 140, 176, YES, 45), 95), @"a growth Apollo owns (a spinner) keeps its surplus");
        // The screen's safe area is Apollo's basis; the table's can lag it.
        Check(Near(NSBRelativizedTop(150 + 45, 150, YES, 45), 0),
              @"a write against the screen's safe area rests, whatever the lagging table's was (palette not yet in it)");
        Check(Near(OldTop(150 + 45, 90, 45), 60) && Near(OldTop(90 + 45, 0, 45), 135),
              @"(the old rule kept a lagging table's difference, or the whole write, as a permanent inset)");
        // Off-window: nothing on screen to measure against, still a resting write.
        Check(Near(NSBRelativizedTop(0 + 45, 0, YES, 45), 0), @"an off-window band-only write rests");
        Check(Near(NSBRelativizedTop(45, 0, NO, 45), 45),
              @"on screen with no safe area at all (no off-window, no basis) the write stays as it was");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
