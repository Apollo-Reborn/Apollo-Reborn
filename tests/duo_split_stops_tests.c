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

    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedQuarter, canvas, fold), 237.75),
          "Feed quarter divider is 25% of the canvas");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, canvas, fold), 475.5),
          "Half divider sits at the fold");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedThreeQuarters, canvas, fold), 713.25),
          "Feed three quarters divider is 75% of the canvas");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, canvas, 0), 475.5),
          "Half divider falls back to half the canvas without a fold");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, 1000, 480), 480),
          "Half divider prefers the fold over half the canvas");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedQuarter, canvas, 0), 237.75),
          "Quarter ignores a missing fold");
    Check(Near(ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedThreeQuarters, canvas, 0), 713.25),
          "Three quarters ignores a missing fold");
    Check(Near(ApolloDuoSplitStopDivider((ApolloDuoSplitStop)0, canvas, fold), 475.5),
          "Invalid stop 0 behaves as Half");
    Check(Near(ApolloDuoSplitStopDivider((ApolloDuoSplitStop)9, canvas, 0), 475.5),
          "Invalid stop 9 behaves as Half without a fold");

    Check(ApolloDuoSplitStopNearest(100, canvas, fold) == ApolloDuoSplitStopFeedQuarter,
          "100 snaps to the feed quarter");
    Check(ApolloDuoSplitStopNearest(300, canvas, fold) == ApolloDuoSplitStopFeedQuarter,
          "300 snaps to the feed quarter");
    Check(ApolloDuoSplitStopNearest(476, canvas, fold) == ApolloDuoSplitStopHalf,
          "476 snaps to half");
    Check(ApolloDuoSplitStopNearest(600, canvas, fold) == ApolloDuoSplitStopFeedThreeQuarters,
          "600 snaps to three quarters");
    Check(ApolloDuoSplitStopNearest(800, canvas, fold) == ApolloDuoSplitStopFeedThreeQuarters,
          "800 snaps to three quarters");
    Check(ApolloDuoSplitStopNearest(476, canvas, 0) == ApolloDuoSplitStopHalf,
          "Nearest works without a fold");

    ApolloDuoSplitRelease r = ApolloDuoSplitReleaseFor(700, 0, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopFeedThreeQuarters && !r.closesThread && !r.fullScreen,
          "Slow release at 700 lands on three quarters");
    r = ApolloDuoSplitReleaseFor(900, 0, canvas, fold);
    Check(r.closesThread && !r.fullScreen, "Slow release at 900 closes the thread");
    r = ApolloDuoSplitReleaseFor(720, 600, canvas, fold);
    Check(r.closesThread && !r.fullScreen, "Rightward flick past the 75% stop closes the thread");
    r = ApolloDuoSplitReleaseFor(600, 600, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopFeedThreeQuarters && !r.closesThread && !r.fullScreen,
          "Rightward flick short of the 75% stop does not close");
    r = ApolloDuoSplitReleaseFor(720, 400, canvas, fold);
    Check(!r.closesThread, "A slow rightward release just past the stop does not close");

    r = ApolloDuoSplitReleaseFor(250, 0, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopFeedQuarter && !r.closesThread && !r.fullScreen,
          "Slow release at 250 lands on the feed quarter");
    r = ApolloDuoSplitReleaseFor(50, 0, canvas, fold);
    Check(r.fullScreen && !r.closesThread, "Slow release at 50 goes full screen");
    r = ApolloDuoSplitReleaseFor(230, -600, canvas, fold);
    Check(r.fullScreen && !r.closesThread, "Leftward flick past the 25% stop goes full screen");
    r = ApolloDuoSplitReleaseFor(350, -600, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopFeedQuarter && !r.fullScreen && !r.closesThread,
          "Leftward flick short of the 25% stop does not go full screen");

    // The edge commit thresholds: 713.25 + 0.35 * (951 - 713.25) = 796.46
    // on the right, 237.75 - 0.35 * 237.75 = 154.54 on the left.
    r = ApolloDuoSplitReleaseFor(796, 0, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopFeedThreeQuarters && !r.closesThread && !r.fullScreen,
          "Slow release just inside the close threshold lands on three quarters");
    r = ApolloDuoSplitReleaseFor(797, 0, canvas, fold);
    Check(r.closesThread && !r.fullScreen, "Slow release just past the close threshold closes the thread");
    r = ApolloDuoSplitReleaseFor(155, 0, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopFeedQuarter && !r.closesThread && !r.fullScreen,
          "Slow release just inside the full screen threshold lands on the feed quarter");
    r = ApolloDuoSplitReleaseFor(154, 0, canvas, fold);
    Check(r.fullScreen && !r.closesThread, "Slow release just past the full screen threshold goes full screen");

    r = ApolloDuoSplitReleaseFor(476, 0, canvas, fold);
    Check(r.stop == ApolloDuoSplitStopHalf && !r.closesThread && !r.fullScreen,
          "Release at the fold lands on half");

    Check(Near(ApolloDuoPostsPrimaryWidth(false, ApolloDuoSplitStopFeedQuarter, canvas, fold), 475.5),
          "Toggle off keeps the feed at half the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(false, ApolloDuoSplitStopFeedThreeQuarters, 1000, 480), 500),
          "Toggle off ignores the stop and the fold, as before the setting");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopFeedQuarter, canvas, fold), 237.75),
          "Feed quarter gives the feed a quarter of the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopFeedThreeQuarters, canvas, fold), 713.25),
          "Feed three quarters gives the feed three quarters of the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopHalf, canvas, 0), 475.5),
          "Half without a fold is half the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, ApolloDuoSplitStopHalf, 1000, 480), 480),
          "Half with the toggle on ends the feed at the fold");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, (ApolloDuoSplitStop)7, canvas, 0), 475.5),
          "An unknown stored stop sizes the feed as Half");

    Check(ApolloDuoSplitStopSanitized(0) == ApolloDuoSplitStopHalf, "Sanitized 0 is Half");
    Check(ApolloDuoSplitStopSanitized(7) == ApolloDuoSplitStopHalf, "Sanitized 7 is Half");
    Check(ApolloDuoSplitStopSanitized(1) == ApolloDuoSplitStopFeedQuarter, "Sanitized 1 is kept");
    Check(ApolloDuoSplitStopSanitized(3) == ApolloDuoSplitStopFeedThreeQuarters, "Sanitized 3 is kept");

    printf("duo split stops tests passed (%u checks)\n", checks);
    return 0;
}
