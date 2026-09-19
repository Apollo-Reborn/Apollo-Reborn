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
    Check(ApolloDuoRailEdgeGutter == 4,
          "trailing hug is a 4pt gutter");
    Check(ApolloDuoRailMinTopClearance == 104,
          "rail top floor is 104pt so it stays under the status band");
    Check(ApolloDuoRailTrailingChrome() == 4.0,
          "trailing chrome is the tiny hug, not safe.right");
    Check(ApolloDuoRailContentRightInset() == 68.0,
          "content additional right inset is rail + tiny gutter");
    Check(ApolloDuoRailContentFillWidth(1000.0) == 932.0,
          "open-Duo fill width is container minus rail and gutter");
    Check(ApolloDuoRailContentIsLetterboxed(390.0, 1000.0),
          "a phone-width column on the inner canvas is letterboxed");
    Check(!ApolloDuoRailContentIsLetterboxed(932.0, 1000.0),
          "content already filling left of the rail is not letterboxed");
    Check(ApolloDuoRailTopInset(0.0, 0.0) == 104.0,
          "missing pill still uses the 104pt status-band floor");
    Check(ApolloDuoRailTopInset(20.0, 0.0) == 104.0,
          "a short safe.top does not climb into the status band");
    Check(ApolloDuoRailTopInset(20.0, 72.0) == 104.0,
          "a short status-pill maxY is still floored at 104pt");
    Check(ApolloDuoRailTopInset(20.0, 110.0) == 114.0,
          "a taller live pill starts the rail just under that band");
    Check(ApolloDuoRailSectionIndexTrailing() == 68.0,
          "A–Z index sits on the list immediately leading the rail");
    Check(ApolloDuoCoverPillWidth == 80 && ApolloDuoCoverPillBottom == 120,
          "cover pill clearance is 80 trailing x 120 bottom");
    Check(ApolloDuoCoverChromeShouldApply(0, 1),
          "Compact + dual displays apply cover pill clearance");
    Check(!ApolloDuoCoverChromeShouldApply(1, 1),
          "Regular open-inner does not apply cover clearance");
    Check(!ApolloDuoCoverChromeShouldApply(0, 0),
          "ordinary single-screen Compact does not apply cover clearance");

    ApolloDuoRailRect hug = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 0.0, 0.0);
    Check(hug.x == 1000.0 - 64.0 - 4.0 && hug.y == 104.0
              && hug.width == 64.0 && hug.height == 800.0 - 104.0,
          "rail hugs the trailing edge and starts at the 104pt floor");

    ApolloDuoRailRect under = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 34.0, 72.0);
    Check(under.x == 1000.0 - 64.0 - 4.0 && under.y == 104.0
              && under.width == 64.0 && under.height == 800.0 - 104.0 - 34.0,
          "short pill still uses the 104pt floor and hugs the edge");

    ApolloDuoRailRect tall = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 34.0, 120.0);
    Check(tall.x == 1000.0 - 64.0 - 4.0 && tall.y == 124.0
              && tall.width == 64.0 && tall.height == 800.0 - 124.0 - 34.0,
          "taller live pill starts the rail just under that band");
    printf("OK: %u checks\n", checks);
    return 0;
}
