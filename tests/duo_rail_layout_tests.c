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
    Check(!ApolloDuoRailShouldShow(0, 1, 900.0, 400.0),
          "Compact never shows the rail");
    Check(!ApolloDuoRailShouldShow(0, 1, 400.0, 900.0),
          "cover/front Compact canvas never gets a second Apollo rail");
    Check(!ApolloDuoRailShouldShow(1, 1, 500.0, 400.0),
          "Regular below the two-column floor stays on the tab bar");
    Check(ApolloDuoRailShouldShow(1, 1, 652.0, 500.0),
          "Regular + dual screens at the floor shows the rail");
    Check(!ApolloDuoRailShouldShow(1, 1, 652.0, 900.0),
          "Regular portrait / vertical hides the rail");
    Check(!ApolloDuoRailShouldShow(1, 0, 736.0, 400.0),
          "Plus landscape (single screen, ~736pt) keeps the tab bar");
    Check(ApolloDuoRailShouldShow(1, 0, 800.0, 500.0),
          "A single wide inner canvas shows the rail");
    Check(!ApolloDuoRailShouldShow(1, 0, 800.0, 1000.0),
          "a tall portrait canvas never installs the rail");
    Check(ApolloDuoRailWidth == 64,
          "rail width is the slim mock strip");
    Check(ApolloDuoRailEdgeGutter == 4,
          "leading hug is a 4pt gutter");
    Check(ApolloDuoRailLeadingChrome() == 4.0,
          "leading chrome is the tiny hug");
    Check(ApolloDuoRailContentLeftInset() == 68.0,
          "content additional left inset is rail + tiny gutter");
    Check(ApolloDuoRailContentRightInset() == 0.0,
          "open-inner content has no extra trailing inset");
    Check(ApolloDuoRailContentFillWidth(1000.0) == 932.0,
          "open-Duo fill width is container minus leading rail and gutter");
    Check(ApolloDuoRailContentIsLetterboxed(390.0, 1000.0),
          "a phone-width column on the inner canvas is letterboxed");
    Check(!ApolloDuoRailContentIsLetterboxed(932.0, 1000.0),
          "content already filling right of the rail is not letterboxed");
    Check(ApolloDuoRailTopInset(0.0, 0.0) == 8.0,
          "top is safe.top + 8 when the safe area is 0");
    Check(ApolloDuoRailTopInset(20.0, 0.0) == 28.0,
          "top follows safe.top + 8");
    Check(ApolloDuoRailTopInset(20.0, 72.0) == 28.0,
          "trailing status-pill maxY is ignored on the leading rail");
    Check(ApolloDuoRailTopInset(20.0, 110.0) == 28.0,
          "a tall trailing pill still does not move the leading rail");
    Check(ApolloDuoRailSectionIndexTrailing() == 0.0,
          "A–Z stays stock; no extra trailing pin");
    Check(ApolloDuoCoverPillWidth == 80 && ApolloDuoCoverPillBottom == 120,
          "cover pill clearance is 80 trailing x 120 bottom");
    Check(ApolloDuoCoverChromeShouldApply(0, 1),
          "Compact + dual displays apply cover pill clearance");
    Check(!ApolloDuoCoverChromeShouldApply(1, 1),
          "Regular open-inner does not apply cover clearance");
    Check(!ApolloDuoCoverChromeShouldApply(0, 0),
          "ordinary single-screen Compact does not apply cover clearance");

    ApolloDuoRailRect hug = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 0.0, 0.0);
    Check(hug.x == 4.0 && hug.y == 8.0
              && hug.width == 64.0 && hug.height == 800.0 - 8.0,
          "rail hugs the leading edge with only a 4pt gutter");

    ApolloDuoRailRect under = ApolloDuoRailFrameInBounds(1000.0, 800.0, 20.0, 34.0, 72.0);
    Check(under.x == 4.0 && under.y == 28.0
              && under.width == 64.0 && under.height == 800.0 - 28.0 - 34.0,
          "leading rail uses safe.top + 8 and ignores the trailing pill");

    ApolloDuoRailRect content = ApolloDuoRailContentFrameInBounds(1000.0, 800.0);
    Check(content.x == 68.0 && content.y == 0.0
              && content.width == 932.0 && content.height == 800.0,
          "open content starts at x=68 so headers cannot sit under Subs");
    Check(ApolloDuoRailContentNeedsLeadingClearance(0.0, 1000.0, 1000.0),
          "a full-bleed view under the rail needs leading clearance");
    Check(!ApolloDuoRailContentNeedsLeadingClearance(68.0, 932.0, 1000.0),
          "a view already starting at 68 and filling the rest does not");
    Check(ApolloDuoRailContentNeedsLeadingClearance(0.0, 390.0, 1000.0),
          "a letterboxed phone column needs leading clearance");
    Check(ApolloDuoRailRowTrailingExtra(480.0) == 0.0,
          "a 480pt row needs no extra trailing cluster");
    Check(ApolloDuoRailRowTrailingExtra(932.0) == 452.0,
          "a wide Duo row pulls stars toward a 480pt title cluster");
    Check(ApolloDuoRailRowMaxContentWidth == 480 && ApolloDuoRailRowStarGap == 28,
          "title+star cluster is 480pt with a 28pt star gap");
    Check(ApolloDuoRailHeaderTitleMinX(0.0, 18.0) == 86.0,
          "a header under the rail shifts FAVORITES from x=18 to x=86");
    Check(ApolloDuoRailHeaderTitleMinX(68.0, 18.0) == 18.0,
          "a header already past the rail keeps the stock 18pt title");
    printf("OK: %u checks\n", checks);
    return 0;
}
