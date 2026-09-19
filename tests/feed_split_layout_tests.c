#include "ApolloDeviceChromeInsets.h"
#include "ApolloFeedSplitLayout.h"

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

static int Near(double actual, double expected) {
    return fabs(actual - expected) < 0.51;
}

int main(void) {
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassCompact, 900.0, 1)
              == ApolloFeedSplitModeStacked,
          "Compact stays stacked even when wide");
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassUnspecified, 900.0, 1)
              == ApolloFeedSplitModeStacked,
          "unspecified size class stays stacked");
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassRegular, 500.0, 1)
              == ApolloFeedSplitModeStacked,
          "Regular below two-column minimum stays stacked");
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassRegular,
                                       (double)ApolloFeedSplitMinRegularWidth - 1.0, 1)
              == ApolloFeedSplitModeStacked,
          "Regular one point under the minimum stays stacked");
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassRegular,
                                       (double)ApolloFeedSplitMinRegularWidth, 1)
              == ApolloFeedSplitModeTiled,
          "Regular at the two-column minimum tiles");
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassRegular, 800.0, 1)
              == ApolloFeedSplitModeTiled,
          "Regular + detail tiles");
    Check(ApolloFeedSplitModeForTraits(ApolloFeedSplitSizeClassRegular, 800.0, 0)
              == ApolloFeedSplitModeCentered,
          "Regular without detail centers the feed");

    Check(ApolloDeviceChromeExtra(47.0, 63.0) == 0.0,
          "standard safe+16 extra is zero");
    Check(ApolloDeviceChromeExtra(0.0, 80.0) == 64.0,
          "hinge-sized margin extra is honored without the safe area");
    Check(ApolloDeviceChromeExtra(80.0, 80.0) == 0.0,
          "hinge reported as safe area is not double-counted as extra");

    Check(Near(ApolloFeedSplitUsableWidth(800.0, 20.0, 10.0), 770.0),
          "usable width subtracts left/right extras");

    ApolloFeedSplitFrames stacked = ApolloFeedSplitFramesMake(
        400.0, 800.0, 20.0, 10.0, ApolloFeedSplitModeStacked, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(stacked.feed.x, 0.0) && Near(stacked.feed.width, 400.0)
              && Near(stacked.feed.height, 800.0) && !stacked.showsDetail,
          "stacked fills the container and ignores extras");

    ApolloFeedSplitFrames centered = ApolloFeedSplitFramesMake(
        736.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(centered.feed.width, (double)ApolloFeedSplitCenteredMaxWidth),
          "centered caps the feed column on Plus-landscape widths");
    Check(Near(centered.feed.x, (736.0 - (double)ApolloFeedSplitCenteredMaxWidth) / 2.0),
          "centered feed sits in the remaining width");
    Check(!centered.showsDetail, "centered has no detail frame");

    double wideLeading = ApolloFeedSplitLeadingColumnWidth(900.0, 0.0);
    ApolloFeedSplitFrames centeredWide = ApolloFeedSplitFramesMake(
        900.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(centeredWide.feed.width, wideLeading) && Near(centeredWide.feed.x, 0.0),
          "wide Duo canvas pins a lone feed to the leading half");
    Check(centeredWide.feed.x + centeredWide.feed.width + 0.5 <= 450.0
              && !centeredWide.showsDetail,
          "lone Duo feed stops at the container mid (hinge)");

    ApolloFeedSplitFrames centeredWideRTL = ApolloFeedSplitFramesMake(
        900.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeCentered, 1,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(centeredWideRTL.feed.x, 450.0 + 6.0)
              && Near(centeredWideRTL.feed.width, 900.0 - (450.0 + 6.0)),
          "RTL Duo feed-only sits on the trailing physical half");

    ApolloFeedSplitFrames centeredRail = ApolloFeedSplitFramesMake(
        736.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 1);
    Check(Near(centeredRail.feed.width, ApolloFeedSplitLeadingColumnWidth(736.0, 0.0))
              && Near(centeredRail.feed.x, 0.0),
          "rail-active Plus-width still pins leading instead of centering");

    ApolloFeedSplitFrames centeredChrome = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 64.0, 0.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 1);
    Check(Near(centeredChrome.feed.x, 64.0),
          "rail/chrome extra only shifts the left pane start");
    Check(Near(centeredChrome.feed.width, 500.0 - 64.0 - 6.0),
          "left pane still reaches the container mid, not 50% of shrunk usable");

    ApolloFeedSplitFrames centeredFatMargin = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 400.0, 400.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 1);
    Check(Near(centeredFatMargin.feed.x, 0.0)
              && Near(centeredFatMargin.feed.width, ApolloFeedSplitLeadingColumnWidth(1000.0, 400.0)),
          "a half-width readable margin is not stacked on the book split");
    Check(centeredFatMargin.feed.width + 0.5 >= 400.0,
          "fat margins do not crumple the feed into a skinny left strip");

    ApolloFeedSplitFrames centeredInset = ApolloFeedSplitFramesMake(
        780.0, 400.0, 20.0, 20.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(centeredInset.feed.width, (double)ApolloFeedSplitCenteredMaxWidth),
          "centered still caps after extras on a Plus-width canvas");
    Check(Near(centeredInset.feed.x, 20.0 + (740.0 - (double)ApolloFeedSplitCenteredMaxWidth) / 2.0),
          "centered origin honors extras then remaining slack");

    ApolloFeedSplitFrames centeredNarrow = ApolloFeedSplitFramesMake(
        650.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(centeredNarrow.feed.width, 650.0) && Near(centeredNarrow.feed.x, 0.0),
          "centered below the cap uses the full usable width");

    ApolloFeedSplitFrames tiled = ApolloFeedSplitFramesMake(
        800.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(tiled.showsDetail, "tiled exposes a detail frame");
    Check(Near(tiled.feed.x, 0.0), "LTR feed starts at the leading extra");
    Check(Near(tiled.feed.width, (double)ApolloFeedSplitFeedPreferredWidth),
          "LTR feed uses the preferred column width");
    Check(Near(tiled.detail.x, (double)ApolloFeedSplitFeedPreferredWidth + (double)ApolloFeedSplitGutterWidth),
          "LTR detail sits after the gutter");
    Check(Near(tiled.detail.width,
               800.0 - (double)ApolloFeedSplitFeedPreferredWidth - (double)ApolloFeedSplitGutterWidth),
          "LTR detail gets the remaining usable width");
    Check(Near(tiled.feed.height, 400.0) && Near(tiled.detail.height, 400.0),
          "both columns use the container height");

    ApolloFeedSplitFrames tiledExtra = ApolloFeedSplitFramesMake(
        800.0, 400.0, 20.0, 10.0, ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(tiledExtra.feed.x, 20.0), "tiled feed honors left extra");
    Check(Near(tiledExtra.feed.width, (double)ApolloFeedSplitFeedPreferredWidth),
          "extras do not shrink a preferred feed that still fits");
    Check(Near(tiledExtra.detail.x,
               20.0 + (double)ApolloFeedSplitFeedPreferredWidth + (double)ApolloFeedSplitGutterWidth),
          "tiled detail origin includes left extra + feed + gutter");
    Check(Near(tiledExtra.detail.width,
               770.0 - (double)ApolloFeedSplitFeedPreferredWidth - (double)ApolloFeedSplitGutterWidth),
          "tiled detail width is usable minus feed minus gutter");

    ApolloFeedSplitFrames tiledRTL = ApolloFeedSplitFramesMake(
        800.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeTiled, 1,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(tiledRTL.feed.x, 800.0 - (double)ApolloFeedSplitFeedPreferredWidth),
          "RTL feed sits on the trailing edge");
    Check(Near(tiledRTL.detail.x, 0.0), "RTL detail sits on the physical left");
    Check(Near(tiledRTL.detail.width,
               800.0 - (double)ApolloFeedSplitFeedPreferredWidth - (double)ApolloFeedSplitGutterWidth),
          "RTL detail width matches LTR");

    ApolloFeedSplitFrames tiledMin = ApolloFeedSplitFramesMake(
        (double)ApolloFeedSplitMinRegularWidth, 400.0, 0.0, 0.0, ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 0);
    Check(Near(tiledMin.feed.width, (double)ApolloFeedSplitFeedMinWidth)
              || tiledMin.feed.width + tiledMin.detail.width + (double)ApolloFeedSplitGutterWidth
                     == (double)ApolloFeedSplitMinRegularWidth,
          "minimum Regular width still produces two columns");
    Check(tiledMin.feed.width + 0.5 >= (double)ApolloFeedSplitFeedMinWidth
              && tiledMin.detail.width + 0.5 >= (double)ApolloFeedSplitFeedMinWidth,
          "neither column drops below the feed minimum at the Regular floor");

    Check(ApolloFeedSplitTileStyleForPair(1, 800.0) == ApolloFeedSplitTileBalanced,
          "feed|comments on a wide canvas uses the mock's balanced split");
    Check(ApolloFeedSplitTileStyleForPair(0, 900.0) == ApolloFeedSplitTileBalanced,
          "Duo-wide list|feed uses the same leading half as feed|comments");
    Check(ApolloFeedSplitTileStyleForPair(1, 736.0) == ApolloFeedSplitTileMaster,
          "Plus landscape feed|comments stays master-detail");
    Check(Near(ApolloFeedSplitLeadingColumnWidth(900.0, 0.0),
               450.0 - (double)ApolloFeedSplitGutterWidth * 0.5),
          "leading column runs from origin to container mid minus half gutter");
    Check(Near(ApolloFeedSplitBookStart(1000.0, 400.0), 0.0),
          "a margin that already is the left pane is not added again");
    Check(Near(ApolloFeedSplitBookStart(736.0, 64.0), 64.0),
          "slim left chrome still shifts content even when extra+minColumn > mid");
    Check(Near(ApolloFeedSplitBookEnd(736.0, 64.0), 736.0 - 64.0),
          "slim trailing rail still insets even when extra+minColumn > mid");
    Check(Near(ApolloFeedSplitLeadingExtra(0.0, 1), 0.0),
          "leading extra is chrome-only (rail is trailing)");
    Check(Near(ApolloFeedSplitTrailingExtra(0.0, 1), (double)ApolloDuoRailWidth),
          "rail-active trailing extra is the rail width");
    Check(Near(ApolloFeedSplitTrailingExtra(120.0, 1), 120.0),
          "chrome extra larger than the rail wins on the trailing side");
    Check(Near(ApolloFeedSplitTrailingExtra(0.0, 0), 0.0),
          "rail-inactive trailing extra stays chrome-only");
    Check(Near(ApolloFeedSplitLeadingExtra(0.0, 0), 0.0),
          "rail-inactive leading extra stays chrome-only");

    ApolloFeedSplitRect spanRect;
    spanRect.x = 0.0; spanRect.y = 0.0; spanRect.width = 900.0; spanRect.height = 400.0;
    Check(ApolloFeedSplitRectSpansMidX(spanRect, 450.0),
          "full-bleed column spans the container mid");
    ApolloFeedSplitRect clampedLead = ApolloFeedSplitClampRectToHalf(spanRect, 900.0, 400.0, 0);
    Check(clampedLead.x + clampedLead.width + 0.5 <= 450.0
              && Near(clampedLead.x, 0.0),
          "clamp-to-leading refuses to cross midX");
    ApolloFeedSplitRect clampedTrail = ApolloFeedSplitClampRectToHalf(spanRect, 900.0, 400.0, 1);
    Check(clampedTrail.x + 0.5 >= 450.0
              && Near(clampedTrail.x + clampedTrail.width, 900.0),
          "clamp-to-trailing starts at midX");

    ApolloFeedSplitFrames stackedPinned = ApolloFeedSplitFramesMake(
        900.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeStacked, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 1);
    Check(!stackedPinned.showsDetail
              && stackedPinned.feed.x + stackedPinned.feed.width + 0.5 <= 450.0,
          "pinLeading stacked becomes centered leading, not full-bleed");

    ApolloFeedSplitFrames railCentered = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 0.0, ApolloFeedSplitTrailingExtra(0.0, 1),
        ApolloFeedSplitModeCentered, 0,
        ApolloFeedSplitTileMaster, 0.0, 0.0, 1);
    Check(Near(railCentered.feed.x, 0.0)
              && railCentered.feed.x + railCentered.feed.width + 0.5 <= 500.0,
          "lone feed stays left of the hinge; trailing rail does not shift it");

    ApolloFeedSplitFrames railTiled = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 0.0, ApolloFeedSplitTrailingExtra(0.0, 1),
        ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileBalanced, 0.0, 0.0, 1);
    Check(railTiled.showsDetail
              && railTiled.detail.x + 0.5 >= 500.0
              && Near(railTiled.detail.x + railTiled.detail.width, 1000.0 - (double)ApolloDuoRailWidth),
          "tiled comments stop before the trailing rail");

    ApolloFeedSplitRect fullBleed = spanRect;
    fullBleed.width = 1000.0;
    ApolloFeedSplitRect trailUnderRail = ApolloFeedSplitClampRectToHalfInsets(
        fullBleed, 1000.0, 400.0, 1, 0.0, (double)ApolloDuoRailWidth);
    Check(Near(trailUnderRail.x + trailUnderRail.width, 1000.0 - (double)ApolloDuoRailWidth),
          "trailing clamp honors the rail book end");

    ApolloFeedSplitFrames balanced = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileBalanced, 0.0, 0.0, 0);
    Check(Near(balanced.feed.width, (1000.0 - (double)ApolloFeedSplitGutterWidth) * 0.5),
          "balanced feed takes half the canvas minus gutter");
    Check(Near(balanced.detail.width, balanced.feed.width),
          "balanced comments pane matches the feed pane");
    Check(Near(balanced.detail.x, 500.0 + (double)ApolloFeedSplitGutterWidth * 0.5),
          "balanced comments sit on the right of the container mid");
    Check(balanced.detail.x + 0.5 >= 500.0,
          "detail is not stacked on the left pane");

    ApolloFeedSplitFrames bookTiledExtra = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 64.0, 20.0, ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileBalanced, 0.0, 0.0, 0);
    Check(Near(bookTiledExtra.feed.x, 64.0)
              && bookTiledExtra.feed.x + bookTiledExtra.feed.width + 0.5 <= 500.0,
          "tiled feed stays in the left physical pane after chrome extra");
    Check(bookTiledExtra.detail.x + 0.5 >= 500.0
              && Near(bookTiledExtra.detail.x + bookTiledExtra.detail.width, 980.0),
          "tiled comments fill the right physical pane");

    ApolloFeedSplitFrames hinged = ApolloFeedSplitFramesMake(
        1000.0, 400.0, 0.0, 0.0, ApolloFeedSplitModeTiled, 0,
        ApolloFeedSplitTileBalanced, 490.0, 20.0, 0);
    Check(Near(hinged.feed.width, 490.0) && Near(hinged.feed.x, 0.0),
          "hinge-aware feed stops at the reserved gap");
    Check(Near(hinged.detail.x, 510.0) && Near(hinged.detail.width, 490.0),
          "hinge-aware comments start after the reserved gap");

    printf("OK: %u checks\n", checks);
    return 0;
}
