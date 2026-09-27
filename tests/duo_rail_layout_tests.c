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
    Check(ApolloDuoSubsChromeTitleCenterBetween(120.0, 1000.0) == 560.0,
          "Open title centers over the list, not the full window");
    Check(ApolloDuoSubsChromeTitleCenterBetween(120.0, 1000.0) != 500.0,
          "window-midpoint 500 would sit on the rail side of the list");
    Check(ApolloDuoSubsChromeTitleCenterBetween(0.0, 400.0) == 200.0,
          "Closed title centers in the full bar");
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
    printf("OK: %u checks\n", checks);
    return 0;
}
