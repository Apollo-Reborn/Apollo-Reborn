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

    printf("OK: %u checks\n", checks);
    return 0;
}
