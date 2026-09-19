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
    Check(ApolloDuoRailContentGutter == 16,
          "content gutter is 16pt past the rail hairline");
    Check(ApolloDuoRailLeadingChrome() == 4.0,
          "leading chrome is the tiny hug");
    Check(ApolloDuoRailContentLeftInset() == 80.0,
          "content additional left inset is rail + 16pt gutter");
    Check(ApolloDuoRailContentRightInset() == 0.0,
          "open-inner content has no extra trailing inset");
    Check(ApolloDuoRailContentFillWidth(1000.0) == 920.0,
          "open-Duo fill width is container minus leading rail and gutter");
    Check(ApolloDuoRailContentIsLetterboxed(390.0, 1000.0),
          "a phone-width column on the inner canvas is letterboxed");
    Check(!ApolloDuoRailContentIsLetterboxed(920.0, 1000.0),
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
    Check(content.x == 80.0 && content.y == 0.0
              && content.width == 920.0 && content.height == 800.0,
          "open content starts at x=80 so feed chrome cannot sit under Subs");
    Check(ApolloDuoRailContentNeedsLeadingClearance(0.0, 1000.0, 1000.0),
          "a full-bleed view under the rail needs leading clearance");
    Check(ApolloDuoRailContentNeedsLeadingClearance(68.0, 932.0, 1000.0),
          "the old 68pt flush edge still needs the 16pt hairline gap");
    Check(!ApolloDuoRailContentNeedsLeadingClearance(80.0, 920.0, 1000.0),
          "a view already starting at 80 and filling the rest does not");
    Check(ApolloDuoRailContentNeedsLeadingClearance(0.0, 390.0, 1000.0),
          "a letterboxed phone column needs leading clearance");
    Check(ApolloDuoRailRowTrailingExtra(480.0) == 0.0,
          "a 480pt row needs no extra trailing cluster");
    Check(ApolloDuoRailRowTrailingExtra(920.0) == 440.0,
          "trailing-extra math stays locked but is not applied at runtime");
    Check(ApolloDuoRailRowMaxContentWidth == 480 && ApolloDuoRailRowStarGap == 28,
          "legacy cluster constants remain 480 / 28 and are unused at runtime");
    Check(ApolloDuoRailHeaderTitleMinX(0.0, 18.0) == 98.0,
          "a header under the rail shifts FAVORITES from x=18 to x=98");
    Check(ApolloDuoRailHeaderTitleMinX(80.0, 18.0) == 18.0,
          "a header already past the rail keeps the stock 18pt title");
    Check(ApolloDuoRailRowTitleBump(0.0) == 80.0,
          "a title under the rail is bumped by the full 80pt inset");
    Check(ApolloDuoRailRowTitleBump(18.0) == 62.0,
          "a stock-18 title under the rail is bumped to the inset");
    Check(ApolloDuoRailRowTitleBump(80.0) == 0.0,
          "a title already at the inset is not bumped again");
    Check(ApolloDuoRailRowTitleBump(98.0) == 0.0,
          "a safe-area-inset title is not double-shifted");
    Check(ApolloDuoRailRowTitleMinX(0.0, 18.0) == 98.0,
          "a full-bleed favorite row matches the FAVORITES header at x=98");
    Check(ApolloDuoRailRowTitleMinX(80.0, 18.0) == 18.0,
          "a cell already past the rail keeps the stock 18pt title");
    Check(ApolloDuoRailRowTitleMinX(0.0, 18.0) == ApolloDuoRailHeaderTitleMinX(0.0, 18.0),
          "favorite-row and header leading use the same minX");

    /* Image 1 / 92ea260 regressions. These fail on the policies we already
       shipped: only-push-right (mid-pane left alone), title.frame bump
       stacked on safe-area (double-shift), and star at label.maxX / 452
       (star-on-letter or star missing at the trailing edge). */
    Check(ApolloDuoRailLabelTextMinX(18.0, 800.0, 50.0, ApolloDuoRailTextAlignCenter) == 393.0,
          "center-aligned text in a stretchy label sits mid-pane (Image 1 glyph)");
    Check(ApolloDuoRailLabelTextMinX(18.0, 800.0, 50.0, ApolloDuoRailTextAlignLeft) == 18.0,
          "left-aligned text in the same stretchy label is at the label origin");
    Check(ApolloDuoRailRowLeadDelta(400.0, 98.0) == -302.0,
          "a mid-pane title column (Image 1, have≈400) must be pulled left");
    Check(ApolloDuoRailRowLeadDelta(400.0, 98.0) < -0.5,
          "92ea260 only-positive deficit would leave Image 1 untouched");
    Check(ApolloDuoRailRowLeadDelta(18.0, 98.0) == 80.0,
          "an under-rail title is pushed by at most the 80pt rail inset");
    Check(ApolloDuoRailRowLeadDelta(0.0, 98.0) == 80.0,
          "right-shift is capped at 80 so we cannot stack a second inset");
    Check(ApolloDuoRailRowLeadDelta(98.0, 98.0) == 0.0,
          "Image 2 / header-aligned titles are a no-op");
    Check(ApolloDuoRailRowLeadDelta(178.0, 98.0) == -80.0,
          "a double-shifted title (98+80) is pulled back, not pushed again");
    Check(ApolloDuoRailRowLeadDelta(18.0, 98.0) != 18.0 + ApolloDuoRailRowTrailingExtra(920.0),
          "trailing-extra must not be applied as a leading indent");
    Check(ApolloDuoRailRowStarMinX(98.0, 40.0, 28.0) == 166.0,
          "star sits after the drawn text, not at RowMaxContentWidth");
    Check(ApolloDuoRailRowStarMinX(98.0, 40.0, 28.0) > 98.0 + 40.0 - 0.5,
          "star is not on the first letter");
    Check(ApolloDuoRailRowStarMinX(98.0, 40.0, 28.0) < (double)ApolloDuoRailRowMaxContentWidth,
          "star is not parked at the 480pt cluster cap");
    Check(ApolloDuoRailReadableLeading(390.0, 672.0) == 0.0,
          "portrait phone width has no readable-column extra (Aaron's good look)");
    Check(ApolloDuoRailReadableLeading(920.0, 672.0) == 124.0,
          "wide Regular landscape adds a centered readable leading inset");
    Check(ApolloDuoRailRowLeadDelta(18.0 + ApolloDuoRailReadableLeading(920.0, 672.0), 98.0) < -0.5,
          "readable-column leading on Duo landscape must be pulled back to 98");
    printf("OK: %u checks\n", checks);
    return 0;
}
