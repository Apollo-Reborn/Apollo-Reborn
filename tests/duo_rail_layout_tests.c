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
    Check(ApolloDuoRailTrailingChrome() == 4.0,
          "trailing chrome is the tiny hug, not safe.right");
    Check(ApolloDuoRailContentRightInset() == 68.0,
          "content additional right inset is rail + tiny gutter");
    Check(ApolloDuoRailTopInset(0.0, 0.0) == 4.0,
          "no pill uses a modest safe.top padding, not a 120pt floor");
    Check(ApolloDuoRailTopInset(20.0, 0.0) == 24.0,
          "safe.top plus a small gap when the pill frame is unknown");
    Check(ApolloDuoRailTopInset(20.0, 72.0) == 76.0,
          "live status-pill maxY plus gap starts the rail just under Wi-Fi");
    Check(ApolloDuoRailSectionIndexTrailing() == 68.0,
          "A–Z index sits on the list immediately leading the rail");
    Check(ApolloDuoCoverChromeShouldApply(0, 1),
          "Compact + dual displays apply cover pill clearance");
    Check(!ApolloDuoCoverChromeShouldApply(1, 1),
          "Regular open-inner does not apply cover clearance");
    Check(!ApolloDuoCoverChromeShouldApply(0, 0),
          "ordinary single-screen Compact does not apply cover clearance");

    ApolloDuoRailRect hug = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 0.0, 0.0);
    Check(hug.x == 1000.0 - 64.0 - 4.0 && hug.y == 4.0
              && hug.width == 64.0 && hug.height == 800.0 - 4.0,
          "rail hugs the trailing edge with only a 4pt gutter");

    ApolloDuoRailRect under = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 34.0, 72.0);
    Check(under.x == 1000.0 - 64.0 - 4.0 && under.y == 76.0
              && under.width == 64.0 && under.height == 800.0 - 76.0 - 34.0,
          "rail starts just under the status pill and still hugs the edge");
    printf("OK: %u checks\n", checks);
    return 0;
}
