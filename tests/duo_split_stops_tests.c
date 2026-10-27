#include "ApolloDuoSplitStops.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;

static void Check(int condition, const char *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static int Near(double a, double b) {
    return fabs(a - b) < 0.01;
}

int main(void) {
    const CGFloat canvas = 951;
    const CGFloat fold = 475.5;
    const CGFloat inset = 84;
    const CGFloat wideThread = 260;
    const CGFloat minimum = 240;

    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedQuarter, canvas, fold, inset, wideThread), 237.75),
          "Feed quarter divider is 25% of the canvas");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, canvas, fold, inset, wideThread), 475.5),
          "Half divider sits at the fold");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, canvas, fold, inset, wideThread), 607),
          "Wide divider leaves the thread what its post actions need beside the rail (951 - 84 - 260)");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, 2000, 0, inset, wideThread), 1500),
          "Wide divider is capped at 75% of a canvas wide enough for it (2000: 1500 against 1656)");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, 600, 300, inset, wideThread), 300),
          "Wide divider never sits left of Half (formula 256 on a 600 canvas)");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, 600, 0, inset, wideThread), 300),
          "Wide divider on a narrow canvas without a fold sits at mid-canvas");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, canvas, fold, 0, wideThread), 691),
          "Wide divider without a rail inset is the smaller of 75% and canvas - 260 (691)");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, 1100, 0, 0, wideThread), 825),
          "Wide divider without a rail inset is 75% where that leaves 260");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, 900, 0, 0, wideThread), 640),
          "Wide divider without a rail inset keeps 260 for the thread (900 - 260)");
    Check(ApolloDuoSplitStopFits(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, canvas, fold, inset, wideThread),
                                 canvas, inset, minimum),
          "The Duo's Wide divider keeps the thread tiled");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, canvas, 0, inset, wideThread), 475.5),
          "Half divider falls back to half the canvas without a fold");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, 1000, 480, inset, wideThread), 480),
          "Half divider prefers the fold over half the canvas");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedQuarter, canvas, 0, inset, wideThread), 237.75),
          "Quarter ignores a missing fold");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, canvas, 0, inset, wideThread), 607),
          "Wide ignores a missing fold");
    Check(Near(ApolloDuoSplitStopDivider((ApolloDuoSplitStop)0, canvas, fold, inset, wideThread), 475.5),
          "Invalid stop 0 behaves as Half");
    Check(Near(ApolloDuoSplitStopDivider((ApolloDuoSplitStop)9, canvas, 0, inset, wideThread), 475.5),
          "Invalid stop 9 behaves as Half without a fold");

    Check(ApolloDuoSplitStopNearest(100, canvas, fold, inset, wideThread) == ApolloDuoSplitStopFeedQuarter,
          "100 snaps to the feed quarter");
    Check(ApolloDuoSplitStopNearest(300, canvas, fold, inset, wideThread) == ApolloDuoSplitStopFeedQuarter,
          "300 snaps to the feed quarter");
    Check(ApolloDuoSplitStopNearest(476, canvas, fold, inset, wideThread) == ApolloDuoSplitStopHalf,
          "476 snaps to half");
    Check(ApolloDuoSplitStopNearest(600, canvas, fold, inset, wideThread) == ApolloDuoSplitStopFeedWide,
          "600 snaps to wide");
    Check(ApolloDuoSplitStopNearest(541, canvas, fold, inset, wideThread) == ApolloDuoSplitStopHalf,
          "541 is just under the Half/Wide midpoint (541.25): half");
    Check(ApolloDuoSplitStopNearest(542, canvas, fold, inset, wideThread) == ApolloDuoSplitStopFeedWide,
          "542 is just over the Half/Wide midpoint: wide");
    Check(ApolloDuoSplitStopNearest(800, canvas, fold, inset, wideThread) == ApolloDuoSplitStopFeedWide,
          "800 snaps to wide");
    Check(ApolloDuoSplitStopNearest(476, canvas, 0, inset, wideThread) == ApolloDuoSplitStopHalf,
          "Nearest works without a fold");

    ApolloDuoSplitRelease r = ApolloDuoSplitReleaseFor(700, 0, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopFeedWide && !r.closesThread && !r.fullScreen,
          "Slow release at 700 lands on wide");
    r = ApolloDuoSplitReleaseFor(900, 0, canvas, fold, inset, wideThread);
    Check(r.closesThread && !r.fullScreen, "Slow release at 900 closes the thread");
    r = ApolloDuoSplitReleaseFor(720, 600, canvas, fold, inset, wideThread);
    Check(r.closesThread && !r.fullScreen, "Rightward flick past the wide stop closes the thread");
    r = ApolloDuoSplitReleaseFor(600, 600, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopFeedWide && !r.closesThread && !r.fullScreen,
          "Rightward flick short of the wide stop does not close");
    r = ApolloDuoSplitReleaseFor(607, 600, canvas, fold, inset, wideThread);
    Check(r.closesThread && !r.fullScreen, "Rightward flick from exactly the wide stop closes the thread");
    r = ApolloDuoSplitReleaseFor(720, 400, canvas, fold, inset, wideThread);
    Check(!r.closesThread, "A slow rightward release just past the stop does not close");

    r = ApolloDuoSplitReleaseFor(250, 0, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopFeedQuarter && !r.closesThread && !r.fullScreen,
          "Slow release at 250 lands on the feed quarter");
    r = ApolloDuoSplitReleaseFor(50, 0, canvas, fold, inset, wideThread);
    Check(r.fullScreen && !r.closesThread, "Slow release at 50 goes full screen");
    r = ApolloDuoSplitReleaseFor(230, -600, canvas, fold, inset, wideThread);
    Check(r.fullScreen && !r.closesThread, "Leftward flick past the 25% stop goes full screen");
    r = ApolloDuoSplitReleaseFor(350, -600, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopFeedQuarter && !r.fullScreen && !r.closesThread,
          "Leftward flick short of the 25% stop does not go full screen");

    // The edge commit thresholds: 607 + 0.35 * (951 - 607) = 727.4
    // on the right, 237.75 - 0.35 * 237.75 = 154.54 on the left.
    r = ApolloDuoSplitReleaseFor(727, 0, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopFeedWide && !r.closesThread && !r.fullScreen,
          "Slow release just inside the close threshold lands on wide");
    r = ApolloDuoSplitReleaseFor(728, 0, canvas, fold, inset, wideThread);
    Check(r.closesThread && !r.fullScreen, "Slow release just past the close threshold closes the thread");
    r = ApolloDuoSplitReleaseFor(155, 0, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopFeedQuarter && !r.closesThread && !r.fullScreen,
          "Slow release just inside the full screen threshold lands on the feed quarter");
    r = ApolloDuoSplitReleaseFor(154, 0, canvas, fold, inset, wideThread);
    Check(r.fullScreen && !r.closesThread, "Slow release just past the full screen threshold goes full screen");

    r = ApolloDuoSplitReleaseFor(476, 0, canvas, fold, inset, wideThread);
    Check(r.stop == ApolloDuoSplitStopHalf && !r.closesThread && !r.fullScreen,
          "Release at the fold lands on half");

    Check(Near(ApolloDuoPostsPrimaryWidth(false, ApolloDuoSplitStopFeedQuarter, canvas, fold, inset, wideThread), 475.5),
          "Toggle off keeps the feed at half the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(false, ApolloDuoSplitStopFeedWide, 1000, 480, inset, wideThread), 500),
          "Toggle off ignores the stop and the fold, as before the setting");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopFeedQuarter, canvas, fold, inset, wideThread), 237.75),
          "Feed quarter gives the feed a quarter of the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopFeedWide, canvas, fold, inset, wideThread), 607),
          "Wide gives the feed the widest width that keeps the thread tiled");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopHalf, canvas, 0, inset, wideThread), 475.5),
          "Half without a fold is half the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopHalf, 1000, 480, inset, wideThread), 480),
          "Half with the toggle on ends the feed at the fold");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, (ApolloDuoSplitStop)7, canvas, 0, inset, wideThread), 475.5),
          "An unknown stored stop sizes the feed as Half");

    /* UIKit tiles the thread beside the feed only while the thread, less its
       trailing safe area (the rail, 84 pt on the Duo), keeps the split's 240 pt
       minimum secondary width; measured on the Duo simulator: a 627 pt feed
       tiles, 627.67 lays the thread out under the feed. */
    Check(ApolloDuoSplitStopFits(627, canvas, 84, 240) && !ApolloDuoSplitStopFits(627.67, canvas, 84, 240),
          "Fit: the thread less the rail keeps the split's minimum, as UIKit tiles it");
    Check(!ApolloDuoSplitStopFits(713.25, canvas, 84, 240),
          "Fit: 75% of the Duo leaves a 154 pt thread beside the rail, which UIKit won't tile");
    Check(ApolloDuoSplitStopFits(237.75, canvas, 84, 240) && ApolloDuoSplitStopFits(475.5, canvas, 84, 240),
          "Fit: the 25% and 50% stops tile");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, ApolloDuoSplitStopFeedWide, canvas, fold, 84, wideThread, 240), 607),
          "Fitted: the Wide stop on the Duo is kept, no fallback");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, ApolloDuoSplitStopFeedWide, canvas, 0, 84, wideThread, 240), 607),
          "Fitted: the Wide stop is the same without a fold");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, ApolloDuoSplitStopFeedWide, 600, 300, 84, wideThread, 240), 300),
          "Fitted: a canvas too narrow to tile at any stop falls back to Half (the fold)");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, ApolloDuoSplitStopFeedWide, 600, 0, 84, wideThread, 240), 300),
          "Fitted: Half without a fold is mid-canvas");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, ApolloDuoSplitStopFeedQuarter, canvas, fold, 84, wideThread, 240), 237.75),
          "Fitted: a workable stop is kept");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, ApolloDuoSplitStopFeedWide, 1400, 0, 84, wideThread, 240), 1050),
          "Fitted: the 75% cap is kept where the canvas leaves the thread room");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(false, ApolloDuoSplitStopFeedWide, canvas, fold, 84, wideThread, 240), 475.5),
          "Fitted: toggle off is half the canvas, as before the setting");

    Check(ApolloDuoSplitStopSanitized(0) == ApolloDuoSplitStopHalf, "Sanitized 0 is Half");
    Check(ApolloDuoSplitStopSanitized(7) == ApolloDuoSplitStopHalf, "Sanitized 7 is Half");
    Check(ApolloDuoSplitStopSanitized(1) == ApolloDuoSplitStopFeedQuarter, "Sanitized 1 is kept");
    Check(ApolloDuoSplitStopSanitized(3) == ApolloDuoSplitStopFeedWide, "Sanitized 3 is kept");

    printf("duo split stops tests passed (%u checks)\n", checks);
    return 0;
}
