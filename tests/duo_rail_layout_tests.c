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
    Check(ApolloDuoModeFromBounds(0, 390.0, 844.0) == ApolloDuoModePhone,
          "regular iPhone portrait is Phone");
    Check(ApolloDuoModeFromBounds(0, 736.0, 414.0) == ApolloDuoModePhone,
          "Plus landscape is Phone");
    Check(ApolloDuoModeFromBounds(0, 932.0, 430.0) == ApolloDuoModePhone,
          "Max landscape is Phone");
    Check(ApolloDuoModeFromBounds(1, 400.0, 900.0) == ApolloDuoModeClosed,
          "dual + portrait-sized window is Closed");
    Check(ApolloDuoModeFromBounds(1, 390.0, 844.0) == ApolloDuoModeClosed,
          "dual + leftover phone column is Closed until fill");
    Check(ApolloDuoModeFromBounds(0, 744.0, 1133.0) == ApolloDuoModeClosed,
          "wide portrait window is Closed (stock tab bar, no rail)");
    Check(ApolloDuoModeFromBounds(1, 1133.0, 744.0) == ApolloDuoModeOpen,
          "dual + wide landscape is Open");
    Check(ApolloDuoModeFromBounds(0, 1133.0, 744.0) == ApolloDuoModeOpen,
          "wide landscape window is Open even without dual");
    Check(ApolloDuoModeFromBounds(1, 652.0, 500.0) == ApolloDuoModePhone,
          "dual landscape that is not wide is not yet Open or Closed");
    Check(ApolloDuoModeIsLeading(ApolloDuoModeOpen),
          "Open rail is leading");
    Check(!ApolloDuoModeIsLeading(ApolloDuoModeClosed),
          "Closed rail is trailing");
    Check(!ApolloDuoRailShouldShow(0, 1, 400.0, 900.0),
          "Closed cover/front Compact keeps the stock tab bar");
    Check(!ApolloDuoRailShouldShow(1, 1, 390.0, 844.0),
          "Closed leftover portrait Duo window keeps the stock tab bar");
    Check(!ApolloDuoRailShouldShow(1, 0, 736.0, 400.0),
          "Plus landscape (single screen, ~736pt) keeps the tab bar");
    Check(!ApolloDuoRailShouldShow(1, 0, 800.0, 500.0),
          "the old 800pt single-canvas floor is not Open");
    Check(!ApolloDuoRailShouldShow(0, 0, 390.0, 844.0),
          "regular iPhone portrait keeps the tab bar");
    Check(ApolloDuoRailShouldShow(1, 1, 1133.0, 744.0),
          "Open inner landscape shows the left rail");
    Check(!ApolloDuoRailShouldShow(1, 0, 744.0, 1133.0),
          "wide inner portrait is Closed: stock tab bar, no Apollo rail");
    Check(ApolloDuoIsWideBounds(1133.0, 744.0),
          "wide-window math keys off UIWindow-sized bounds");
    Check(!ApolloDuoIsWideBounds(390.0, 844.0),
          "phone-column bounds are not wide");
    Check(ApolloDuoRailWidth == 112,
          "rail width is the 100–120pt sidebar");
    Check(ApolloDuoRailEdgeGutter == 0,
          "sidebar is flush to the leading edge");
    Check(ApolloDuoRailContentGutter == 8,
          "content gutter is 8pt past the rail hairline");
    Check(ApolloDuoRailLeadingChrome() == 0.0,
          "leading chrome is flush, not a 4pt hug");
    Check(ApolloDuoRailContentLeftInset() == 120.0,
          "content additional left inset is rail + 8pt gutter");
    Check(ApolloDuoRailContentRightInset() == 0.0,
          "open-inner ContentRightInset helper stays 0");
    Check(ApolloDuoRailChromeLeftForMode(ApolloDuoModeOpen) == 120.0,
          "Open chrome insets the leading edge");
    Check(ApolloDuoRailChromeRightForMode(ApolloDuoModeOpen) == 0.0,
          "Open chrome does not inset the trailing edge");
    Check(ApolloDuoRailChromeLeftForMode(ApolloDuoModeClosed) == 0.0,
          "Closed chrome does not inset the leading edge");
    Check(ApolloDuoRailChromeRightForMode(ApolloDuoModeClosed) == 0.0,
          "Closed chrome does not reserve a trailing column");
    Check(ApolloDuoRailChromeLeftForMode(ApolloDuoModePhone) == 0.0
              && ApolloDuoRailChromeRightForMode(ApolloDuoModePhone) == 0.0,
          "Phone chrome has no rail insets");
    Check(ApolloDuoRailContentFillWidth(1000.0) == 880.0,
          "open-Duo fill width is container minus leading rail and gutter");
    Check(ApolloDuoRailContentIsLetterboxed(390.0, 1000.0),
          "a phone-width column on the inner canvas is letterboxed");
    Check(!ApolloDuoRailContentIsLetterboxed(880.0, 1000.0),
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
          "Open A–Z stays stock; no extra trailing pin");
    Check(ApolloDuoRailSectionIndexTrailingForMode(ApolloDuoModeOpen) == 0.0,
          "Open section-index trailing is 0");
    Check(ApolloDuoRailSectionIndexTrailingForMode(ApolloDuoModeClosed)
              == (double)ApolloDuoRailWidthClosed,
          "Closed A–Z pins immediately left of the overlay rail");
    Check(ApolloDuoRailWidthClosed == 72,
          "Closed overlay rail is a narrow 72pt strip");
    Check(ApolloDuoRailWidthForMode(ApolloDuoModeOpen) == 112.0,
          "Open rail width stays the 112pt reserved sidebar");
    Check(ApolloDuoRailWidthForMode(ApolloDuoModeClosed) == 72.0,
          "Closed rail width is the overlay strip");
    Check(ApolloDuoRailContentFillWidthForMode(400.0, ApolloDuoModeClosed) == 400.0,
          "Closed fill width is the full container (no reserved column)");
    Check(ApolloDuoRailContentFillWidthForMode(1000.0, ApolloDuoModeOpen) == 880.0,
          "Open fill width still subtracts the leading 120pt column");
    Check(!ApolloDuoRailClosedContentIsCrushed(400.0, 400.0),
          "a full-bleed Closed list is not crushed");
    Check(ApolloDuoRailClosedContentIsCrushed(280.0, 400.0),
          "reserving ~120pt on a 400pt Closed list is the 20–25% crush");
    Check(ApolloDuoRailClosedOverlayClearance() == 88.0,
          "Closed visible trailing chrome is rail + A–Z");
    Check(ApolloDuoRailClosedStarMaxX(400.0) == 312.0,
          "Closed star sits at the visible row trailing edge");
    Check(ApolloDuoRailClosedStarMinX(400.0, 28.0) == 284.0,
          "Closed star origin is just left of A–Z");
    Check(ApolloDuoRailClosedShouldNudgeStar(250.0, 312.0),
          "a mid-column Closed star must be nudged to the row edge");
    Check(!ApolloDuoRailClosedShouldNudgeStar(312.0, 312.0),
          "an already-anchored Closed star is a no-op");
    Check(ApolloDuoCoverPillWidth == 80 && ApolloDuoCoverPillBottom == 120,
          "cover pill clearance is 80 trailing x 120 bottom");
    Check(ApolloDuoCoverChromeShouldApply(0, 1),
          "Compact + dual displays apply cover pill clearance");
    Check(!ApolloDuoCoverChromeShouldApply(1, 1),
          "Regular open-inner does not apply cover clearance");
    Check(!ApolloDuoCoverChromeShouldApply(0, 0),
          "ordinary single-screen Compact does not apply cover clearance");

    ApolloDuoRailRect hug = ApolloDuoRailFrameInBounds(1000.0, 800.0, 0.0, 0.0, 0.0);
    Check(hug.x == 0.0 && hug.y == 8.0
              && hug.width == 112.0 && hug.height == 800.0 - 8.0,
          "sidebar is flush to the leading edge");

    ApolloDuoRailRect under = ApolloDuoRailFrameInBounds(1000.0, 800.0, 20.0, 34.0, 72.0);
    Check(under.x == 0.0 && under.y == 28.0
              && under.width == 112.0 && under.height == 800.0 - 28.0 - 34.0,
          "leading rail uses safe.top + 8 and ignores the trailing pill");

    ApolloDuoRailRect closed = ApolloDuoRailFrameInBoundsOnSide(400.0, 900.0, 20.0, 34.0, 0.0, 0);
    Check(closed.x == 400.0 - 72.0 && closed.y == 28.0
              && closed.width == 72.0 && closed.height == 900.0 - 28.0 - 34.0,
          "Closed overlay rail is flush to the trailing edge");

    ApolloDuoRailRect closedContent = ApolloDuoRailContentFrameInBoundsForMode(400.0, 900.0,
                                                                              ApolloDuoModeClosed);
    Check(closedContent.x == 0.0 && closedContent.width == 400.0,
          "Closed content is full-bleed; the rail overlays");

    ApolloDuoRailRect content = ApolloDuoRailContentFrameInBounds(1000.0, 800.0);
    Check(content.x == 120.0 && content.y == 0.0
              && content.width == 880.0 && content.height == 800.0,
          "open content starts at x=120 so feed chrome cannot sit under Posts/Subs");
    Check(ApolloDuoRailContentNeedsLeadingClearance(0.0, 1000.0, 1000.0),
          "a full-bleed view under the rail needs leading clearance");
    Check(ApolloDuoRailContentNeedsLeadingClearance(68.0, 932.0, 1000.0),
          "the old 68pt flush edge still needs clearance past the 112pt sidebar");
    Check(!ApolloDuoRailContentNeedsLeadingClearance(120.0, 880.0, 1000.0),
          "a view already starting at 120 and filling the rest does not");
    Check(ApolloDuoRailContentNeedsLeadingClearance(0.0, 390.0, 1000.0),
          "a letterboxed phone column needs leading clearance");
    Check(ApolloDuoRailRowTrailingExtra(480.0) == 0.0,
          "a 480pt row needs no extra trailing cluster");
    Check(ApolloDuoRailRowTrailingExtra(920.0) == 440.0,
          "trailing-extra math stays locked but is not applied at runtime");
    Check(ApolloDuoRailRowMaxContentWidth == 480 && ApolloDuoRailRowStarGap == 28,
          "legacy cluster constants remain 480 / 28 and are unused at runtime");
    Check(ApolloDuoRailHeaderTitleMinX(0.0, 18.0) == 138.0,
          "legacy header 18→138 math stays locked (unused at runtime)");
    Check(ApolloDuoRailHeaderTitleMinX(0.0, (double)ApolloDuoRailRowStockLead)
              == ApolloDuoRailShortcutLeadMinX(0.0),
          "legacy header/shortcut helpers still share one inset");
    Check(ApolloDuoRailHeaderTitleMinX(120.0, 18.0) == 18.0,
          "a header already past the rail keeps the stock 18pt title");
    Check(ApolloDuoRailRowTitleBump(0.0) == 120.0,
          "a title under the rail is bumped by the full 120pt inset");
    Check(ApolloDuoRailRowTitleBump(18.0) == 102.0,
          "a stock-18 title under the rail is bumped to the inset");
    Check(ApolloDuoRailRowTitleBump(120.0) == 0.0,
          "a title already at the inset is not bumped again");
    Check(ApolloDuoRailRowTitleBump(138.0) == 0.0,
          "a safe-area-inset title is not double-shifted");
    Check(ApolloDuoRailRowTitleMinX(0.0, 18.0) == 138.0,
          "a full-bleed favorite row matches the FAVORITES header at x=138");
    Check(ApolloDuoRailRowTitleMinX(120.0, 18.0) == 18.0,
          "a cell already past the rail keeps the stock 18pt title");
    Check(ApolloDuoRailRowTitleMinX(0.0, 18.0) == ApolloDuoRailHeaderTitleMinX(0.0, 18.0),
          "header-keyed RowTitleMinX stays 18→138 (not used at runtime)");
    Check(ApolloDuoRailRowStockLead == 16,
          "shortcut-row stock lead is UITableView's 16pt, not the header 18");
    Check(ApolloDuoRailShortcutLeadMinX(0.0) == 136.0,
          "full-bleed fallback wantX is safe-area 120 + 16");
    Check(ApolloDuoRailShortcutLeadMinX(120.0) == 16.0,
          "a cell already past the rail keeps stock 16");
    Check(ApolloDuoRailShortcutLeadMinX(0.0) != ApolloDuoRailRowTitleMinX(0.0, 18.0),
          "runtime wantX is not the header column");
    Check(ApolloDuoRailFavoriteTitleWantX(96.0, 137.0, 96.0) == 137.0,
          "live Home textLabel wins over the shortcut icon");
    Check(ApolloDuoRailFavoriteTitleWantX(0.0, 137.0, 96.0) == 137.0,
          "textLabel is used when there is no icon");
    Check(ApolloDuoRailFavoriteTitleWantX(96.0, 0.0, 96.0) == 96.0,
          "icon is the fallback when textLabel is missing");
    Check(ApolloDuoRailFavoriteTitleWantX(0.0, 0.0, 96.0) == 96.0,
          "no live shortcut uses the 96pt fallback");
    Check(ApolloDuoRailRowShouldClaimLeading(0) == 1,
          "first layout may disable horizontal constraints once");
    Check(ApolloDuoRailRowShouldClaimLeading(1) == 0,
          "already-claimed rows must not re-toggle constraints (25f8a7b hang)");

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
          "an under-rail title is pushed toward wantX");
    Check(ApolloDuoRailRowLeadDelta(0.0, 138.0) == 120.0,
          "right-shift is capped at the 120pt rail inset");
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

    /* 2eba156 leftover: stack +80 then a stale convertRect remainder
       +80 parked titles at ~178 (Image 1). Remainder must not run after
       a real stack move. */
    Check(ApolloDuoRailRowShouldApplyTitleRemainder(1, 80.0) == 0,
          "stale +80 remainder is skipped after the stack already moved");
    Check(ApolloDuoRailRowShouldApplyTitleRemainder(1, -82.0) == 0,
          "stale negative remainder is also skipped after a stack move");
    Check(ApolloDuoRailRowShouldApplyTitleRemainder(0, 80.0) == 1,
          "remainder still runs when the stack write was a no-op");
    Check(ApolloDuoRailRowShouldApplyTitleRemainder(0, -80.0) == 1,
          "a no-op stack can still pull a mid-stack title left");
    Check(ApolloDuoRailRowShouldApplyTitleRemainder(0, 0.0) == 0,
          "a zero remainder is a no-op");
    {
        double have = 18.0;
        double want = ApolloDuoRailShortcutLeadMinX(0.0);
        double delta = ApolloDuoRailRowLeadDelta(have, want);
        double afterStack = have + delta;
        double staleRemain = ApolloDuoRailRowLeadDelta(18.0, want);
        double applied = ApolloDuoRailRowShouldApplyTitleRemainder(1, staleRemain)
            ? staleRemain : 0.0;
        Check(afterStack == 136.0,
              "one stack delta from stock 18 lands at shortcut lead 136");
        Check(afterStack + applied == 136.0,
              "gating remainder keeps 136; does not stack a second remainder");
        Check(afterStack + staleRemain == 254.0,
              "an ungated double-apply is still the leftover second column");
    }
    Check(ApolloDuoRailRowLeadDelta(178.0, 96.0) == -82.0,
          "Image 1 settled titles (header 98 + leftover 80) pull to 96");
    Check(ApolloDuoRailRowLeadDelta(178.0, 137.0) == -41.0,
          "4a76cd3 leftover 178 pulls to the live Home text (~137)");
    Check(ApolloDuoRailRowStarMinX(96.0, 40.0, 28.0) == 164.0,
          "star still sits after the drawn text at the new 96pt title lead");

    /* Portrait organization: one leading column. Landscape must use
       stock margin (safe+16), not a readable-centered second column. */
    Check(ApolloDuoRailRowStockMarginLeft(80.0) == 96.0,
          "full-bleed stock leading is rail safe-area + 16");
    Check(ApolloDuoRailRowStockMarginLeft(0.0) == 16.0,
          "an already-inset contentView keeps portrait's 16pt lead");
    Check(ApolloDuoRailRowStockMarginLeft(80.0)
              != 16.0 + ApolloDuoRailReadableLeading(920.0, 672.0),
          "readable-column extra must not become the favorite indent");
    Check(ApolloDuoRailRowIsPortraitOrganized(96.0, 96.0),
          "titles on the shortcut lead are portrait-organized");
    Check(ApolloDuoRailRowIsPortraitOrganized(98.0, 96.0),
          "header 98 is within a few points of shortcut 96");
    Check(!ApolloDuoRailRowIsPortraitOrganized(178.0, 96.0),
          "Image 1 leftover 178 is a second indented column");
    Check(!ApolloDuoRailRowIsPortraitOrganized(18.0 + ApolloDuoRailReadableLeading(920.0, 672.0), 96.0),
          "18 + wide readable leading is the landscape waste Aaron sees");
    Check(ApolloDuoRailRowIsPortraitOrganized(137.0, 137.0),
          "titles on the live Home textLabel are portrait-organized");
    Check(!ApolloDuoRailRowIsPortraitOrganized(178.0, 137.0),
          "4a76cd3 leftover 178 is still a second column vs Home text");
    Check(ApolloDuoRailRowWastedLeading(178.0, 137.0) == 41.0,
          "Image 1 wastes 41pt left of the Home text lead");
    Check(ApolloDuoRailRowWastedLeading(178.0, 96.0) == 82.0,
          "Image 1 wastes 82pt left of the shortcut icon lead");
    Check(ApolloDuoRailRowWastedLeading(96.0, 96.0) == 0.0,
          "portrait organization has no wasted leading");
    Check(!ApolloDuoRailRowShouldNudgeStack(96.0, 96.0),
          "an already-organized row must not write frames again");
    Check(!ApolloDuoRailRowShouldNudgeStack(98.0, 96.0),
          "a 2pt header slop is already organized; do not nudge");
    Check(ApolloDuoRailRowShouldNudgeStack(178.0, 96.0),
          "Image 1 leftover 178 still needs one stack nudge");
    Check(ApolloDuoRailRowShouldNudgeStack(178.0, 137.0),
          "178 vs live Home text (~137) still needs one stack nudge");
    Check(!ApolloDuoRailRowShouldNudgeStack(137.0, 137.0),
          "titles already on Home text must not write frames again");
    Check(ApolloDuoRailRowShouldNudgeStack(18.0 + ApolloDuoRailReadableLeading(920.0, 672.0), 96.0),
          "readable-centered landscape still needs one stack nudge");

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
    Check(ApolloDuoSubsChromeTitleLeading(ApolloDuoModeOpen, 0.0) == 120.0,
          "Open title leading is at least the rail content inset");
    Check(ApolloDuoSubsChromeTitleLeading(ApolloDuoModeOpen, 140.0) == 140.0,
          "Open title leading honors a larger chrome inset");
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
    Check(ApolloDuoRailShouldShow(1, 1, 1133.0, 744.0),
          "Subs chrome must not change Open rail show");
    Check(!ApolloDuoRailShouldShow(1, 1, 400.0, 900.0),
          "Subs chrome must not reintroduce a Closed rail");
    Check(ApolloDuoRailContentFillWidthForMode(400.0, ApolloDuoModeClosed) == 400.0,
          "Subs chrome does not reserve a Closed trailing column");
    Check(ApolloDuoRailChromeLeftForMode(ApolloDuoModeOpen) == 120.0,
          "Open list inset is unchanged by Subs chrome");
    printf("OK: %u checks\n", checks);
    return 0;
}
