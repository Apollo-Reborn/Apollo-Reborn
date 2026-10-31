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

        // Finish: a reveal ends shown only by committing; a hide ends hidden only by committing.
        Check(ApolloDuoListDragEndsVisible(YES, NO, YES), @"finish: a reveal commit shows the drawer");
        Check(!ApolloDuoListDragEndsVisible(YES, NO, NO), @"finish: a short reveal slides it back");
        Check(!ApolloDuoListDragEndsVisible(YES, YES, YES), @"finish: a hide commit hides the drawer");
        Check(ApolloDuoListDragEndsVisible(YES, YES, NO), @"finish: a short hide springs back shown");
        Check(!ApolloDuoListDragEndsVisible(NO, NO, YES) && !ApolloDuoListDragEndsVisible(NO, YES, NO),
              @"finish: no drag in hand, no Back and no hide (no second Back from one swipe)");

        // The interactive hide: a leftward drag, measured against the same travel.
        Check(Near(ApolloDuoListHideProgress(-186, travel, travel), 0.5) && Near(ApolloDuoListHideProgress(50, travel, travel), 0)
              && Near(ApolloDuoListHideProgress(-900, travel, travel), 1) && Near(ApolloDuoListHideProgress(-40, 0, 0), 1),
              @"hide progress: the leftward travel over the drawer's, clamped");
        Check(Near(ApolloDuoListHideProgress(-50, travel, 100), 0.5) && Near(ApolloDuoListHideProgress(-100, travel, 100), 1)
              && Near(ApolloDuoListHideProgress(-30, travel, 0), 1),
              @"hide progress: a list still springing in counts the share of what it shows that is closed");
        Check(ApolloDuoListHideCommits(0.35, 0) && !ApolloDuoListHideCommits(0.34, 0) && !ApolloDuoListHideCommits(0.2, 400),
              @"hide commit: a third of the travel, or a flick, as the reveal does");
        Check(ApolloDuoListHideCommits(0.05, 500) && !ApolloDuoListHideCommits(0.04, 900) && !ApolloDuoListHideCommits(0.5, -500)
              && ApolloDuoListHideCommits(0.5, -499),
              @"hide commit: a leftward flick needs a little travel; a rightward one faster than 500 never commits");
        Check(ApolloDuoListHideBegins(YES, NO, -12, 3) && ApolloDuoListHideBegins(YES, NO, -12, -12),
              @"hide begin: a leftward drag on a shown list");
        Check(ApolloDuoListHideBegins(YES, NO, -2, 1), @"hide begin: a slow drag, decided on motion, still begins");
        Check(!ApolloDuoListHideBegins(NO, NO, -12, 0) && !ApolloDuoListHideBegins(YES, YES, -12, 0)
              && !ApolloDuoListHideBegins(YES, NO, 12, 0) && !ApolloDuoListHideBegins(YES, NO, -3, 14)
              && !ApolloDuoListHideBegins(YES, NO, 0, 0),
              @"hide begin: not when hidden, mid-drag, rightward or mostly vertical (scrolling)");
        Check(ApolloDuoListHideStripContains(332, 360) && ApolloDuoListHideStripContains(360, 360)
              && !ApolloDuoListHideStripContains(331, 360) && !ApolloDuoListHideStripContains(0, 360),
              @"hide strip: the 28pt at the list's trailing edge");

        // The Reduce Motion fade: alpha always comes back, even superseded.
        Check(ApolloDuoListFadeEndFor(NO).restoreAlpha && ApolloDuoListFadeEndFor(NO).settle,
              @"fade end: the newest fade restores alpha and settles the drawer");
        Check(ApolloDuoListFadeEndFor(YES).restoreAlpha && !ApolloDuoListFadeEndFor(YES).settle,
              @"fade end: a superseded fade still restores alpha but leaves the newer slide to settle");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
