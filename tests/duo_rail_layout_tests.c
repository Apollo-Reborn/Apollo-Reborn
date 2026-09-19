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
    Check(!ApolloDuoRailShouldShow(0, 1, 900.0),
          "Compact never shows the rail");
    Check(!ApolloDuoRailShouldShow(0, 1, 400.0),
          "cover/front Compact canvas never gets a second Apollo rail");
    Check(!ApolloDuoRailShouldShow(1, 1, 500.0),
          "Regular below the two-column floor stays on the tab bar");
    Check(ApolloDuoRailShouldShow(1, 1, 652.0),
          "Regular + dual screens at the floor shows the rail");
    Check(!ApolloDuoRailShouldShow(1, 0, 736.0),
          "Plus landscape (single screen, ~736pt) keeps the tab bar");
    Check(ApolloDuoRailShouldShow(1, 0, 800.0),
          "A single wide inner canvas shows the rail");
    Check(ApolloDuoRailWidth == 64,
          "rail width is the slim mock strip");
    Check(ApolloDuoRailEdgeGutter == 8,
          "min edge gutter is 8pt");
    Check(ApolloDuoRailTrailingChrome(0.0, 16.0) == (double)ApolloDuoRailEdgeGutter,
          "zero right inset still leaves the min gutter");
    Check(ApolloDuoRailTrailingChrome(48.0, 64.0) == 48.0,
          "status-pill right inset wins over the 16pt system margin");
    Check(ApolloDuoRailTrailingChrome(48.0, 80.0) == 64.0,
          "hinge-sized layout-margin extra adds to the right chrome");
    Check(ApolloDuoRailContentRightInset() == 72.0,
          "content additional right inset is rail + gutter");
    Check(ApolloDuoRailStatusBandMin == 120,
          "status-band floor clears the nav/pill row even when safe.top is 0");
    Check(ApolloDuoRailTopInset(0.0, 0.0) == 128.0,
          "zero chrome still starts below the 120pt status/nav band");
    Check(ApolloDuoRailTopInset(59.0, 0.0) == 128.0,
          "a small island inset does not leave Subs beside the pill");
    Check(ApolloDuoRailTopInset(103.0, 0.0) == 128.0,
          "content safe top below the floor still uses the 120pt band");
    Check(ApolloDuoRailTopInset(59.0, 150.0) == 158.0,
          "a taller live nav/status band wins the top inset");
    Check(ApolloDuoRailSectionIndexTrailing(48.0) == 120.0,
          "A–Z index trailing is rail+gutter plus the status gutter");

    ApolloDuoRailRect flush = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 0.0, 0.0, 16.0, 0.0);
    Check(flush.x == 1000.0 - 64.0 - 8.0 && flush.y == 128.0
              && flush.width == 64.0 && flush.height == 800.0 - 128.0,
          "zero-safe frame uses the min gutter and starts below the status band");

    ApolloDuoRailRect pill = ApolloDuoRailFrameInBounds(1000.0, 800.0, 59.0, 48.0, 34.0, 64.0, 0.0);
    Check(pill.x == 1000.0 - 64.0 - 48.0 && pill.y == 128.0
              && pill.width == 64.0 && pill.height == 800.0 - 128.0 - 34.0,
          "rail starts below the status band and left of the trailing gutter");
    printf("OK: %u checks\n", checks);
    return 0;
}
