#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// INCLUDE_PRODUCTION_INTERACTIVE_DRAWER
static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static BOOL Near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.0001; }
int main(void) {
    @autoreleasepool {
        // The drawer parks its width plus a 12pt gap off the leading edge.
        CGFloat travel = ApolloDuoListDragTravel(360);
        Check(Near(travel, 372) && Near(ApolloDuoListDragTravel(0), 12) && Near(ApolloDuoListDragTravel(-5), 12),
              @"travel: the drawer's width and the 12pt gap, never negative");

        // Progress: the finger pulls the drawer in; it never goes past
        // fully shown and never back out of the leading edge.
        Check(Near(ApolloDuoListDragOffset(-30, travel), 0) && Near(ApolloDuoListDragOffset(100, travel), 100)
              && Near(ApolloDuoListDragOffset(900, travel), travel),
              @"offset: clamped between the parked and the fully shown drawer");
        Check(Near(ApolloDuoListDragTranslationX(0, travel), -372) && Near(ApolloDuoListDragTranslationX(100, travel), -272)
              && Near(ApolloDuoListDragTranslationX(900, travel), 0) && Near(ApolloDuoListDragTranslationX(-9, travel), -372),
              @"translation: -(w + 12) + dx, ending at rest");
        Check(Near(ApolloDuoListDragProgress(186, travel), 0.5) && Near(ApolloDuoListDragProgress(900, travel), 1)
              && Near(ApolloDuoListDragProgress(-4, travel), 0) && Near(ApolloDuoListDragProgress(40, 0), 0),
              @"progress: offset over travel, clamped, zero without travel");

        // Begin: any drawer not shown, with no drag already in hand. One still
        // parking after a hide is taken over from where it is.
        Check(ApolloDuoListDragBegins(NO, NO), @"begin: a hidden or still parking drawer, idle");
        Check(!ApolloDuoListDragBegins(YES, NO), @"begin: not while shown (or still sliding in)");
        Check(!ApolloDuoListDragBegins(NO, YES), @"begin: never replaces a drag in progress");
        Check(Near(ApolloDuoListDragBase(0, travel, YES), 0) && Near(ApolloDuoListDragBase(-372, travel, NO), 0)
              && Near(ApolloDuoListDragBase(-0.9, travel, NO), 371.1) && Near(ApolloDuoListDragBase(-100, travel, NO), 272),
              @"base: a hidden drawer starts at 0, a parking one at the share still shown");
        Check(Near(ApolloDuoListDragBase(40, travel, NO), travel) && Near(ApolloDuoListDragBase(-900, travel, NO), 0),
              @"base: an overshooting spring and a far-off one are clamped to the drawer's travel");
        // The finger moves it from there: position is the base plus the drag.
        Check(Near(ApolloDuoListDragTranslationX(272 + 50, travel), -50) && Near(ApolloDuoListDragProgress(272 + 50, travel), 322.0 / 372.0)
              && Near(ApolloDuoListDragTranslationX(272 - 400, travel), -372),
              @"take over: progress and place follow base + drag, clamped at both ends");

        // Finish: the drawer ends shown only for a tracked drag that commits.
        Check(ApolloDuoListDragEndsVisible(YES, YES), @"finish: a reveal commit shows the drawer");
        Check(!ApolloDuoListDragEndsVisible(YES, NO), @"finish: a short reveal slides it back");
        Check(!ApolloDuoListDragEndsVisible(NO, YES), @"finish: no drag in hand, no Back (no second Back from one swipe)");

        // The Reduce Motion fade: alpha always comes back, even superseded.
        Check(ApolloDuoListFadeEndFor(NO).restoreAlpha && ApolloDuoListFadeEndFor(NO).settle,
              @"fade end: the newest fade restores alpha and settles the drawer");
        Check(ApolloDuoListFadeEndFor(YES).restoreAlpha && !ApolloDuoListFadeEndFor(YES).settle,
              @"fade end: a superseded fade still restores alpha but leaves the newer slide to settle");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
