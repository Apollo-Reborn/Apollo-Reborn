#include "ApolloDuoSplitPosition.h"

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

static ApolloDuoSplitStored Share(double share) {
    return (ApolloDuoSplitStored){ true, share, 0 };
}

static ApolloDuoSplitStored Legacy(long stop) {
    return (ApolloDuoSplitStored){ false, 0, stop };
}

int main(void) {
    // The Duo unfolded: 951 pt canvas, hinge at 475.5, 84 pt rail, 260 pt for the post's actions.
    const CGFloat canvas = 951;
    const CGFloat fold = 475.5;
    const CGFloat inset = 84;
    const CGFloat wide = 260;
    const CGFloat minimum = 240;

    // Limits.
    Check(Near(ApolloDuoSplitLeftLimit(canvas), 237.75), "Left limit is 25% of the canvas");
    Check(Near(ApolloDuoSplitRightLimit(canvas, fold, inset, wide), 607),
          "Right limit leaves the thread what its post actions need beside the rail (951 - 84 - 260)");
    Check(Near(ApolloDuoSplitRightLimit(2000, 0, inset, wide), 1500),
          "Right limit is capped at 75% of a canvas wide enough for it");
    Check(Near(ApolloDuoSplitRightLimit(canvas, fold, 0, wide), 691),
          "Right limit without a rail inset is the smaller of 75% and canvas - 260");
    Check(Near(ApolloDuoSplitRightLimit(1100, 0, 0, wide), 825), "Right limit is 75% where that leaves 260");
    Check(Near(ApolloDuoSplitRightLimit(600, 300, inset, wide), 300), "Right limit never sits left of Half");
    Check(Near(ApolloDuoSplitRightLimit(600, 0, inset, wide), 300), "Right limit on a narrow canvas is mid-canvas without a fold");
    Check(Near(ApolloDuoSplitHalfDivider(canvas, fold), 475.5), "Half sits at the fold");
    Check(Near(ApolloDuoSplitHalfDivider(canvas, 0), 475.5), "Half is mid-canvas without a fold");
    Check(Near(ApolloDuoSplitHalfDivider(1000, 480), 480), "Half prefers the fold over half the canvas");
    Check(ApolloDuoSplitHasRange(canvas, fold, inset, wide), "The Duo has room to move the divider");
    Check(!ApolloDuoSplitHasRange(100, 10, inset, wide), "A fold left of the left limit leaves only Half");

    // Landing: wherever it is let go, between the limits.
    ApolloDuoSplitRelease r = ApolloDuoSplitReleaseFor(400, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 400) && Near(r.share, 400 / canvas) && !r.closesThread && !r.coversFeed,
          "400 lands at 400, remembered as a share of the canvas");
    r = ApolloDuoSplitReleaseFor(530, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 530) && Near(r.share, 530 / canvas), "530 lands at 530");
    r = ApolloDuoSplitReleaseFor(480, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 475.5) && r.share == 0 && !r.closesThread && !r.coversFeed,
          "480 is magnetised to Half, stored as 0 so it follows the fold");
    r = ApolloDuoSplitReleaseFor(491.5, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 475.5) && r.share == 0, "16 pt from Half is still Half");
    r = ApolloDuoSplitReleaseFor(491.6, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 491.6) && r.share > 0, "Past 16 pt from Half it lands where it is");
    r = ApolloDuoSplitReleaseFor(459.5, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 475.5) && r.share == 0, "The magnet works left of Half too");
    r = ApolloDuoSplitReleaseFor(700, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 607) && !r.closesThread && !r.coversFeed,
          "700 is below the close threshold and clamps to the right limit");
    r = ApolloDuoSplitReleaseFor(180, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 237.75) && !r.closesThread && !r.coversFeed,
          "180 is above the cover threshold and clamps to the left limit");
    r = ApolloDuoSplitReleaseFor(237.75, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 237.75) && Near(r.share, 0.25), "The left limit itself is kept");
    r = ApolloDuoSplitReleaseFor(607, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 607) && !r.closesThread, "The right limit itself is kept");

    // Close and cover: past a limit by the commit share, or flicked past it.
    // 607 + 0.35 * (951 - 607) = 727.4 on the right, 237.75 - 0.35 * 237.75 = 154.54 on the left.
    r = ApolloDuoSplitReleaseFor(727, 0, canvas, fold, inset, wide);
    Check(!r.closesThread && Near(r.divider, 607), "Just inside the close threshold clamps to the right limit");
    r = ApolloDuoSplitReleaseFor(728, 0, canvas, fold, inset, wide);
    Check(r.closesThread && !r.coversFeed, "Just past the close threshold closes the thread");
    r = ApolloDuoSplitReleaseFor(900, 0, canvas, fold, inset, wide);
    Check(r.closesThread && !r.coversFeed, "900 closes the thread");
    r = ApolloDuoSplitReleaseFor(720, 600, canvas, fold, inset, wide);
    Check(r.closesThread, "A rightward flick past the right limit closes the thread");
    r = ApolloDuoSplitReleaseFor(607, 600, canvas, fold, inset, wide);
    Check(r.closesThread, "A rightward flick from exactly the right limit closes the thread");
    r = ApolloDuoSplitReleaseFor(600, 600, canvas, fold, inset, wide);
    Check(!r.closesThread && Near(r.divider, 600), "A rightward flick short of the right limit does not close");
    r = ApolloDuoSplitReleaseFor(720, 400, canvas, fold, inset, wide);
    Check(!r.closesThread, "A slow release just past the right limit does not close");
    r = ApolloDuoSplitReleaseFor(155, 0, canvas, fold, inset, wide);
    Check(!r.coversFeed && Near(r.divider, 237.75), "Just inside the cover threshold clamps to the left limit");
    r = ApolloDuoSplitReleaseFor(154, 0, canvas, fold, inset, wide);
    Check(r.coversFeed && !r.closesThread, "Just past the cover threshold covers the feed");
    r = ApolloDuoSplitReleaseFor(50, 0, canvas, fold, inset, wide);
    Check(r.coversFeed && !r.closesThread, "50 covers the feed");
    r = ApolloDuoSplitReleaseFor(230, -600, canvas, fold, inset, wide);
    Check(r.coversFeed && !r.closesThread, "A leftward flick past the left limit covers the feed");
    r = ApolloDuoSplitReleaseFor(237.75, -600, canvas, fold, inset, wide);
    Check(r.coversFeed, "A leftward flick from exactly the left limit covers the feed");
    r = ApolloDuoSplitReleaseFor(350, -600, canvas, fold, inset, wide);
    Check(!r.coversFeed && Near(r.divider, 350), "A leftward flick short of the left limit does not");
    r = ApolloDuoSplitReleaseFor(230, -400, canvas, fold, inset, wide);
    Check(!r.coversFeed, "A slow leftward release just past the left limit does not");
    r = ApolloDuoSplitReleaseFor(500, 2000, canvas, fold, inset, wide);
    Check(!r.closesThread && !r.coversFeed, "A flick in the middle of the range lands, it does not commit");

    // Nothing to land on: no canvas, or a position that is not a number.
    r = ApolloDuoSplitReleaseFor(0, 0, 0, 0, inset, wide);
    Check(!r.closesThread && !r.coversFeed && r.share == 0, "A zero canvas never reports a close");
    r = ApolloDuoSplitReleaseFor(500, 900, 0, 0, inset, wide);
    Check(!r.closesThread && !r.coversFeed, "A zero canvas ignores a flick");
    r = ApolloDuoSplitReleaseFor(NAN, 0, canvas, fold, inset, wide);
    Check(Near(r.divider, 475.5) && r.share == 0 && !r.closesThread && !r.coversFeed,
          "A position that is not a number lands on Half");

    // Book fold: the display half is 455.7 and the limits move with the canvas.
    r = ApolloDuoSplitReleaseFor(460, 0, 911.4, 455.7, inset, wide);
    Check(Near(r.divider, 455.7) && r.share == 0, "Book: Half is the fold at 455.7");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0), 911.4, 455.7, inset, wide), 455.7),
          "Book: a stored 0 follows the fold");

    // Tiny canvas / a fold left of the left limit: only Half.
    r = ApolloDuoSplitReleaseFor(20, 0, 100, 10, inset, wide);
    Check(Near(r.divider, 10) && r.share == 0 && !r.closesThread && !r.coversFeed,
          "With no room to move, a release lands on Half");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0.4), 100, 10, inset, wide), 10),
          "With no room to move, any stored share sizes the feed as Half");
    r = ApolloDuoSplitReleaseFor(120, 0, 300, 150, inset, wide);
    Check(!r.coversFeed && !r.closesThread && r.divider >= 75 && r.divider <= 150,
          "A narrow canvas still keeps a landing inside its limits (75 to 150)");

    // The stored share and its migration.
    Check(Near(ApolloDuoSplitDividerForStored(Share(400.0 / canvas), canvas, fold, inset, wide), 400),
          "A stored share gives the feed that share of the canvas");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0.1), canvas, fold, inset, wide), 237.75),
          "A stored share left of the left limit is re-clamped");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0.9), canvas, fold, inset, wide), 607),
          "A stored share right of the right limit is re-clamped");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0.5), 600, 0, inset, wide), 300),
          "A share re-clamps on a narrower canvas (0.5 of 600 against a right limit of 300)");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0.7), 700, 0, inset, wide), 356),
          "A wide share on a narrower canvas keeps the thread its 260 beside the rail (700 - 84 - 260)");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0), canvas, fold, inset, wide), 475.5),
          "A stored 0 is Half at the fold");
    Check(Near(ApolloDuoSplitDividerForStored(Share(0), canvas, 0, inset, wide), 475.5),
          "A stored 0 is mid-canvas without a fold");
    Check(Near(ApolloDuoSplitDividerForStored(Share(-0.3), canvas, fold, inset, wide), 475.5),
          "A negative stored share is Half");
    Check(Near(ApolloDuoSplitDividerForStored(Share(1.5), canvas, fold, inset, wide), 475.5),
          "A share past the canvas is Half");
    Check(Near(ApolloDuoSplitDividerForStored(Share(NAN), canvas, fold, inset, wide), 475.5),
          "A share that is not a number is Half");
    Check(Near(ApolloDuoSplitDividerForStored(Legacy(1), canvas, fold, inset, wide), 237.75),
          "Migration: the old quarter stop is 25%");
    Check(Near(ApolloDuoSplitDividerForStored(Legacy(2), canvas, fold, inset, wide), 475.5),
          "Migration: the old half stop is Half");
    Check(Near(ApolloDuoSplitDividerForStored(Legacy(3), canvas, fold, inset, wide), 607),
          "Migration: the old wide stop is the right limit");
    Check(Near(ApolloDuoSplitDividerForStored(Legacy(0), canvas, fold, inset, wide), 475.5),
          "Migration: nothing stored is Half");
    Check(Near(ApolloDuoSplitDividerForStored(Legacy(9), canvas, fold, inset, wide), 475.5),
          "Migration: an unknown old stop is Half");
    ApolloDuoSplitStored both = { true, 400.0 / canvas, 1 };
    Check(Near(ApolloDuoSplitDividerForStored(both, canvas, fold, inset, wide), 400),
          "Migration: a stored share wins over the legacy stop");

    // The feed width the split uses.
    Check(Near(ApolloDuoPostsPrimaryWidth(false, Share(0.3), canvas, fold, inset, wide), 475.5),
          "Toggle off keeps the feed at half the canvas");
    Check(Near(ApolloDuoPostsPrimaryWidth(false, Legacy(3), 1000, 480, inset, wide), 500),
          "Toggle off ignores the position and the fold, as before the setting");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, Share(0.3), canvas, fold, inset, wide), 285.3),
          "Toggle on gives the feed the stored share");
    Check(Near(ApolloDuoPostsPrimaryWidth(true, Share(0), 1000, 480, inset, wide), 480),
          "Half with the toggle on ends the feed at the fold");

    // UIKit tiles the thread beside the feed only while the thread, less its
    // trailing safe area (the rail), keeps the split's 240 pt minimum width;
    // measured on the Duo simulator: a 627 pt feed tiles, 627.67 does not.
    Check(ApolloDuoSplitDividerFits(627, canvas, 84, 240) && !ApolloDuoSplitDividerFits(627.67, canvas, 84, 240),
          "Fit: the thread less the rail keeps the split's minimum, as UIKit tiles it");
    Check(!ApolloDuoSplitDividerFits(713.25, canvas, 84, 240),
          "Fit: 75% of the Duo leaves a 154 pt thread beside the rail, which UIKit won't tile");
    Check(ApolloDuoSplitDividerFits(ApolloDuoSplitRightLimit(canvas, fold, inset, wide), canvas, inset, minimum),
          "Fit: the Duo's right limit keeps the thread tiled");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, Share(0.6), canvas, fold, 84, wide, 240), 570.6),
          "Fitted: a workable position is kept");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, Legacy(3), canvas, 0, 84, wide, 240), 607),
          "Fitted: the right limit on the Duo is kept, no fallback");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, Share(0.6), 600, 300, 84, wide, 240), 300),
          "Fitted: a canvas too narrow to tile at any position falls back to Half (the fold)");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, Share(0.6), 600, 0, 84, wide, 240), 300),
          "Fitted: Half without a fold is mid-canvas");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(true, Share(0.75), 1400, 0, 84, wide, 240), 1050),
          "Fitted: the 75% cap is kept where the canvas leaves the thread room");
    Check(Near(ApolloDuoPostsFittedPrimaryWidth(false, Share(0.6), canvas, fold, 84, wide, 240), 475.5),
          "Fitted: toggle off is half the canvas, as before the setting");

    // The uncover drag: the divider dragged back from the screen's edge, where
    // it sits while the post covers the feed. Its picture begins there, so the
    // divider is how far it has come; the same release decides where it goes.
    r = ApolloDuoSplitReleaseFor(100, 0, canvas, fold, inset, wide);
    Check(r.coversFeed && !r.closesThread, "Uncover: let go short of the cover threshold, the feed is covered again");
    r = ApolloDuoSplitReleaseFor(0, 0, canvas, fold, inset, wide);
    Check(r.coversFeed && !r.closesThread, "Uncover: not moved at all, the feed stays covered");
    r = ApolloDuoSplitReleaseFor(200, 0, canvas, fold, inset, wide);
    Check(!r.coversFeed && !r.closesThread && Near(r.divider, 237.75),
          "Uncover: past the cover threshold but short of the left limit, the feed comes back at the left limit");
    r = ApolloDuoSplitReleaseFor(420, 0, canvas, fold, inset, wide);
    Check(!r.coversFeed && !r.closesThread && Near(r.divider, 420) && Near(r.share, 420 / canvas),
          "Uncover: dropped mid screen, the feed comes back there");
    r = ApolloDuoSplitReleaseFor(470, 0, canvas, fold, inset, wide);
    Check(!r.coversFeed && Near(r.divider, 475.5) && r.share == 0, "Uncover: the hinge magnet still applies");
    r = ApolloDuoSplitReleaseFor(800, 0, canvas, fold, inset, wide);
    Check(r.closesThread && !r.coversFeed, "Uncover: dragged far right, the thread closes");
    r = ApolloDuoSplitReleaseFor(650, 700, canvas, fold, inset, wide);
    Check(r.closesThread, "Uncover: a rightward flick past the right limit closes");
    r = ApolloDuoSplitReleaseFor(300, 2000, canvas, fold, inset, wide);
    Check(!r.closesThread && !r.coversFeed && Near(r.divider, 300),
          "Uncover: a rightward flick inside the range lands, it does not close");
    r = ApolloDuoSplitReleaseFor(60, -900, canvas, fold, inset, wide);
    Check(r.coversFeed, "Uncover: a leftward flick near the edge covers again");

    // The cover's lifetime: it lasts for that thread alone, in the unfolded
    // landscape split with the setting on. Nothing is persisted for it.
    ApolloDuoSplitCoverFacts holds = { .adjustable = true, .landscape = true, .sameThread = true };
    Check(ApolloDuoSplitCoverEndReason(holds) == NULL, "Cover holds: the same thread, landscape, setting on");
    ApolloDuoSplitCoverFacts closed = holds;
    closed.sameThread = false;
    Check(ApolloDuoSplitCoverEndReason(closed) != NULL, "Cover ends when the thread is closed or another replaces it");
    ApolloDuoSplitCoverFacts portrait = holds;
    portrait.landscape = false;
    Check(ApolloDuoSplitCoverEndReason(portrait) != NULL, "Cover ends on rotation to portrait");
    ApolloDuoSplitCoverFacts off = holds;
    off.adjustable = false;
    Check(ApolloDuoSplitCoverEndReason(off) != NULL, "Cover ends when the setting is turned off, or the device folds");
    Check(ApolloDuoSplitCoverEndReason(holds) == NULL && ApolloDuoSplitCoverEndReason(closed) != NULL
          && ApolloDuoSplitCoverEndReason(portrait) != NULL && ApolloDuoSplitCoverEndReason(off) != NULL,
          "Cover holds only while every fact holds");

    // The guide at Half lights where the release would land on Half, no wider.
    Check(ApolloDuoSplitDividerAtHalf(475.5, canvas, fold, inset, wide), "The guide lights on Half itself");
    Check(ApolloDuoSplitDividerAtHalf(491.5, canvas, fold, inset, wide), "The guide lights at the magnet's edge, right");
    Check(!ApolloDuoSplitDividerAtHalf(491.6, canvas, fold, inset, wide), "The guide is faint just past the magnet, right");
    Check(ApolloDuoSplitDividerAtHalf(459.5, canvas, fold, inset, wide), "The guide lights at the magnet's edge, left");
    Check(!ApolloDuoSplitDividerAtHalf(459.4, canvas, fold, inset, wide), "The guide is faint just past the magnet, left");
    Check(!ApolloDuoSplitDividerAtHalf(700, canvas, fold, inset, wide), "The guide is faint where the thread would close");
    Check(!ApolloDuoSplitDividerAtHalf(100, canvas, fold, inset, wide), "The guide is faint where the feed would be covered");
    Check(!ApolloDuoSplitDividerAtHalf(NAN, canvas, fold, inset, wide), "The guide is faint for a position that is not a number");
    Check(!ApolloDuoSplitDividerAtHalf(10, 100, 10, inset, wide), "The guide never lights with no range to move in");
    Check(ApolloDuoSplitDividerAtHalf(500, 1000, 0, 0, wide), "The guide lights around mid-canvas without a fold");

    // The guide lights when the drag is aiming for Half, not on a pass through it.
    Check(!ApolloDuoSplitGuideLit(true, 600, 0.0, false), "A fast pass into the zone does not light the guide");
    Check(!ApolloDuoSplitGuideLit(true, -600, 0.04, false), "A fast pass still in the zone under 80 ms stays faint");
    Check(ApolloDuoSplitGuideLit(true, 100, 0.0, false), "A slow approach lights the guide at once");
    Check(ApolloDuoSplitGuideLit(true, -100, 0.0, false), "A slow approach from the other side lights it too");
    Check(!ApolloDuoSplitGuideLit(true, 150, 0.0, false), "150 pt/s is not slower than the threshold");
    Check(ApolloDuoSplitGuideLit(true, 600, 0.08, false), "Lingering 80 ms in the zone lights it, speed aside");
    Check(ApolloDuoSplitGuideLit(true, 0, 0.5, false), "A still finger in the zone lights it");
    Check(!ApolloDuoSplitGuideLit(false, 0, 1.0, false), "Outside the zone it is faint, however slow");
    Check(!ApolloDuoSplitGuideLit(false, 0, 1.0, true), "Leaving the zone unlights it");
    Check(ApolloDuoSplitGuideLit(true, 900, 0.01, true), "Lit, it stays lit in the zone as the speed rises");
    Check(ApolloDuoSplitGuideLit(true, 40, 0.3, true), "Lit, it stays lit as the speed falls");
    {
        // One pass through the zone at a varying speed: it lights once and unlights once.
        const CGFloat speeds[] = { 300, 200, 100, 400, 800, 120, 500 };
        bool lit = false;
        int toggles = 0;
        for (unsigned i = 0; i < sizeof speeds / sizeof speeds[0]; i++) {
            bool next = ApolloDuoSplitGuideLit(true, speeds[i], 0.01 * i, lit);
            if (next != lit) toggles++;
            lit = next;
        }
        Check(lit && toggles == 1, "At a varying speed in the zone the guide lights once and does not toggle");
        bool next = ApolloDuoSplitGuideLit(false, 800, 0, lit);
        Check(!next, "And it unlights when it leaves");
    }

    printf("duo split position tests passed (%u checks)\n", checks);
    return 0;
}
