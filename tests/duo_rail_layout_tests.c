#include "ApolloDuoCompatibility.h"
#include "ApolloDuoRailLayout.h"

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

int main(void) {
    Check(ApolloDuoCoverChromeShouldApply(0, 1),
          "Compact dual displays apply cover clearance");
    Check(!ApolloDuoCoverChromeShouldApply(1, 1),
          "Regular inner display does not apply cover clearance");
    Check(!ApolloDuoCoverChromeShouldApply(0, 0),
          "Ordinary compact iPhone does not apply cover clearance");

    /* Subs chrome (title / Edit / floating +). Does not change rail
       show/hide or list width. Phone is a no-op. */
    Check(ApolloDuoSubsChromeShouldApply(ApolloDuoModeOpen),
          "Open Duo applies Subs chrome");
    Check(ApolloDuoSubsChromeShouldApply(ApolloDuoModeClosed),
          "Closed Duo still gets sensible Subs chrome");
    Check(!ApolloDuoSubsChromeShouldApply(ApolloDuoModePhone),
          "regular iPhone keeps stock RedditList chrome");
    Check(ApolloDuoSubsChromeShouldForceInlineTitle(ApolloDuoModeOpen, 1),
          "Open Regular forces an inline centered title");
    Check(ApolloDuoSubsChromeShouldForceInlineTitle(ApolloDuoModeOpen, 0),
          "Open Compact also uses inline title (wide landscape)");
    Check(!ApolloDuoSubsChromeShouldForceInlineTitle(ApolloDuoModeClosed, 0),
          "Closed Compact keeps Apollo's large title");
    Check(ApolloDuoSubsChromeShouldForceInlineTitle(ApolloDuoModeClosed, 1),
          "Closed Regular (wide portrait) uses inline title");
    Check(!ApolloDuoSubsChromeShouldForceInlineTitle(ApolloDuoModePhone, 1),
          "Phone never forces an inline title");
    Check(ApolloDuoSubsChromeTitleLeading(ApolloDuoModeOpen, 0.0) == 0.0,
          "Open title does not reserve a removed custom rail");
    Check(ApolloDuoSubsChromeTitleLeading(ApolloDuoModeOpen, 140.0) == 140.0,
          "Open title honors the native chrome inset");
    Check(ApolloDuoSubsChromeTitleLeading(ApolloDuoModeClosed, 16.0) == 16.0,
          "Closed title leading is chrome only (no rail)");
    Check(ApolloDuoSubsChromeTitleTrailing(0.0) == (double)ApolloDuoSubsChromeCornerGutter,
          "title trailing uses the corner gutter when chrome is 0");
    Check(ApolloDuoSubsChromeTitleTrailing(32.0) == 32.0,
          "title trailing honors a larger chrome/hinge extra");
    Check(ApolloDuoSubsChromeTitleMaxWidth(120.0, 980.0, 22.0) == 816.0,
          "title max width is the band minus padding");
    Check(ApolloDuoSubsChromeTitleMaxWidth(120.0, 130.0, 22.0) == 0.0,
          "a collapsed title band is zero, not negative");

    ApolloDuoRailRect fab = ApolloDuoSubsChromeFABFrame(1000.0, 800.0, 0.0, 34.0,
                                                       56.0, 56.0);
    Check(fab.width == 56.0 && fab.height == 56.0,
          "FAB keeps the stock 56pt circle");
    Check(fab.x == 1000.0 - 20.0 - 16.0 - 56.0,
          "FAB trailing is corner gutter + margin");
    Check(fab.y == 800.0 - 34.0 - 16.0 - 56.0,
          "FAB bottom honors chrome (home indicator) plus margin");
    ApolloDuoRailRect fabCover = ApolloDuoSubsChromeFABFrame(400.0, 900.0, 80.0, 120.0,
                                                            56.0, 56.0);
    Check(fabCover.x == 400.0 - 80.0 - 16.0 - 56.0,
          "cover FAB trailing uses the pill width");
    Check(fabCover.y == 900.0 - 120.0 - 16.0 - 56.0,
          "cover FAB bottom uses the pill lift");
    Check(!ApolloDuoSubsChromeShouldNudgeFrame(fab.x, fab.y, fab.x, fab.y),
          "an already-placed FAB is a no-op");
    Check(ApolloDuoSubsChromeShouldNudgeFrame(fab.x + 8.0, fab.y, fab.x, fab.y),
          "a FAB sitting in the corner is nudged once");
    /* Subreddit drawer spring: continue a release's speed toward the
       target without overshooting it. */
    double omega = ApolloDuoDrawerSpringOmega();
    Check(omega > 17.9 && omega < 18.0,
          "drawer spring settles with a 0.35 s response");
    Check(ApolloDuoDrawerSpringInitialVelocity(-372, 0, 0) == 0,
          "a programmatic open starts at rest");
    Check(ApolloDuoDrawerSpringInitialVelocity(-372, 0, 1860) == 5,
          "an opening flick becomes travel fractions per second");
    Check(ApolloDuoDrawerSpringInitialVelocity(-100, -372, -1360) == 5,
          "a closing flick keeps its speed toward the edge");
    Check(ApolloDuoDrawerSpringInitialVelocity(-100, 0, -800) == 0,
          "a release away from the target starts at rest");
    Check(ApolloDuoDrawerSpringInitialVelocity(-20, 0, 4000) == omega,
          "a fast release near the target is capped so it does not overshoot");
    Check(ApolloDuoDrawerSpringInitialVelocity(0, 0, 900) == 0,
          "a zero-distance slide has no velocity");

    /* Feed anchor across a column resize: the same point of the same row
       stays at the same height on screen, within the scrollable range. */
    Check(ApolloDuoAnchoredOffset(1000, 200, 0.5, 300, -50, 5000) == 800,
          "a row that keeps its height keeps its screen position");
    Check(ApolloDuoAnchoredOffset(1200, 300, 0.5, 300, -50, 5000) == 1050,
          "a row that rewraps taller keeps its middle under the same point");
    Check(ApolloDuoAnchoredOffset(100, 200, 0.0, 400, -50, 5000) == -50,
          "the offset never scrolls above the top inset");
    Check(ApolloDuoAnchoredOffset(9000, 200, 1.0, 0, -50, 5000) == 5000,
          "the offset never scrolls past the end");
    /* A feed resting at its top stays at its top: anchoring a row there
       scrolls the first post under the search bar, which then collapses. */
    Check(ApolloDuoFeedRestsAtTop(-136, -136), "the top rest is the top");
    Check(ApolloDuoFeedRestsAtTop(-135.5, -136), "half a point below the rest is still the top");
    Check(!ApolloDuoFeedRestsAtTop(-122.5, -136), "a feed scrolled a little is anchored");
    Check(!ApolloDuoFeedRestsAtTop(400, -136), "a feed scrolled down is anchored");

    /* Comment jump button: Apollo stores CommentJumpButtonPosition as a
       string. In a split pane every position stays inside the pane. */
    Check(ApolloDuoJumpButtonPositionKind("center") == ApolloDuoJumpButtonCenter,
          "the center jump button position is centered");
    Check(ApolloDuoJumpButtonPositionKind("bottom-right") == ApolloDuoJumpButtonRight,
          "bottom right is a right jump button position");
    Check(ApolloDuoJumpButtonPositionKind("middle-right") == ApolloDuoJumpButtonRight,
          "middle right is a right jump button position");
    Check(ApolloDuoJumpButtonPositionKind("top-left") == ApolloDuoJumpButtonLeft,
          "top left is a left jump button position");
    Check(ApolloDuoJumpButtonPositionKind("middle-left") == ApolloDuoJumpButtonLeft,
          "middle left is a left jump button position");
    Check(ApolloDuoJumpButtonPositionKind("bottom-left") == ApolloDuoJumpButtonLeft,
          "bottom left is a left jump button position");
    Check(ApolloDuoJumpButtonPositionKind("") == ApolloDuoJumpButtonRight,
          "an empty jump button position falls back to right");
    Check(ApolloDuoJumpButtonPositionKind("left") == ApolloDuoJumpButtonRight,
          "an unknown jump button position falls back to right");
    Check(ApolloDuoJumpButtonPositionKind(0) == ApolloDuoJumpButtonRight,
          "the unset default (bottom right) is a right position");

    /* Pane 400..1000, 56pt button. Trailing limit is the pane's 16pt margin
       (984), or 15pt before a rail at 920 (905). */
    Check(ApolloDuoJumpButtonPaneTrailingLimit(400.0, 600.0, 0, 0.0) == 984.0,
          "without a rail the trailing limit is the pane's margin");
    Check(ApolloDuoJumpButtonPaneTrailingLimit(400.0, 600.0, 1, 920.0) == 905.0,
          "a visible rail pulls the trailing limit 15pt before the rail");
    Check(ApolloDuoJumpButtonPaneTrailingLimit(400.0, 600.0, 1, 1100.0) == 984.0,
          "a rail beyond the pane keeps the pane's margin");

    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonCenter, 1, 400.0, 600.0, 1, 920.0, 56.0, 572.0) == 672.0,
          "a centered jump button centers on the split pane's column");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonLeft, 1, 400.0, 600.0, 1, 920.0, 56.0, 20.0) == 416.0,
          "a left jump button sits at the split pane's leading margin");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonRight, 1, 400.0, 600.0, 1, 920.0, 56.0, 300.0) == 849.0,
          "a right jump button ends at the rail's trailing limit");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonRight, 1, 400.0, 600.0, 0, 0.0, 56.0, 300.0) == 928.0,
          "a right jump button without a rail ends at the pane's trailing margin");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonRight, 1, 400.0, 600.0, 1, 920.0, 56.0, 380.0) == 849.0,
          "a right jump button Apollo put under the posts column moves to the pane's trailing limit");

    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonCenter, 0, 0.0, 0.0, 1, 920.0, 56.0, 572.0) == 572.0,
          "a centered jump button outside a split keeps Apollo's x");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonLeft, 0, 0.0, 0.0, 0, 0.0, 56.0, 20.0) == 20.0,
          "a left jump button outside a split keeps Apollo's x");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonRight, 0, 0.0, 0.0, 1, 920.0, 56.0, 300.0) == 300.0,
          "a right jump button outside a split keeps Apollo's x");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonLeft, 1, 400.0, 0.0, 0, 0.0, 56.0, 20.0) == 20.0,
          "a collapsed pane keeps Apollo's x");
    Check(ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonRight, 1, 400.0, 60.0, 0, 0.0, 56.0, 300.0) == 400.0,
          "a pane narrower than the button keeps it at the pane's leading edge");
    {
        const int kinds[] = { ApolloDuoJumpButtonRight, ApolloDuoJumpButtonCenter, ApolloDuoJumpButtonLeft };
        const double currents[] = { -40.0, 0.0, 20.0, 380.0, 416.0, 672.0, 849.0, 920.0 };
        const int rails[] = { 0, 1 };
        for (unsigned k = 0; k < sizeof(kinds) / sizeof(kinds[0]); k++) {
            for (unsigned r = 0; r < sizeof(rails) / sizeof(rails[0]); r++) {
                double limit = ApolloDuoJumpButtonPaneTrailingLimit(400.0, 600.0, rails[r], 920.0);
                double first = ApolloDuoJumpButtonPaneX(kinds[k], 1, 400.0, 600.0, rails[r], 920.0, 56.0, 0.0);
                Check(ApolloDuoJumpButtonPaneX(kinds[k], 1, 400.0, 600.0, rails[r], 920.0, 56.0, first) == first,
                      "a split jump button position is stable across layout passes");
                for (unsigned c = 0; c < sizeof(currents) / sizeof(currents[0]); c++) {
                    double x = ApolloDuoJumpButtonPaneX(kinds[k], 1, 400.0, 600.0, rails[r], 920.0, 56.0, currents[c]);
                    Check(x == first, "a split jump button ignores Apollo's x");
                    Check(x >= 400.0 && x + 56.0 <= limit,
                          "a split jump button stays between the pane's leading edge and its trailing limit");
                }
            }
        }
    }

    /* Book posture: when the divider rests on the fold (Half at the fold's
       leading edge, 455.7 on the Duo) or inside it (475.5, mid fold), the
       thread pane's usable part starts past the fold, so a left or center
       button never sits on the hinge. */
    Check(ApolloDuoJumpButtonPaneAfterFold(455.7, 495.3, 1, 455.7, 495.3) == 495.3,
          "a fold starting at the pane's leading edge moves the pane past it");
    Check(ApolloDuoJumpButtonPaneAfterFold(475.5, 475.5, 1, 455.7, 495.3) == 495.3,
          "a divider resting inside the fold moves the pane past it");
    Check(ApolloDuoJumpButtonPaneAfterFold(237.75, 713.25, 1, 455.7, 495.3) == 237.75,
          "a fold well inside a wide pane leaves its leading edge alone");
    Check(ApolloDuoJumpButtonPaneAfterFold(713.25, 237.75, 1, 455.7, 495.3) == 713.25,
          "a fold behind the posts column leaves the pane alone");
    Check(ApolloDuoJumpButtonPaneAfterFold(475.5, 475.5, 0, 0.0, 0.0) == 475.5,
          "flat open, no fold, the pane is unchanged");
    {
        double leading = ApolloDuoJumpButtonPaneAfterFold(455.7, 495.3, 1, 455.7, 495.3);
        double width = 455.7 + 495.3 - leading;
        double x = ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonLeft, 1, leading, width, 1, 882.0, 70.0, 20.0);
        Check(x >= 495.3, "a left jump button at the fold sits in the pane past the hinge");
        x = ApolloDuoJumpButtonPaneX(ApolloDuoJumpButtonCenter, 1, leading, width, 1, 882.0, 70.0, 20.0);
        Check(x >= 495.3 && x + 70.0 <= 882.0 - 15.0, "a centered jump button at the fold stays clear of the hinge and the rail");
    }

    printf("OK: %u checks\n", checks);
    return 0;
}
