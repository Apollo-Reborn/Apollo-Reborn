#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

#include "ApolloFeedGalleryGesturePolicy.h"

static ApolloFeedGalleryPanDisposition disposition(double offset,
                                                    double maximumOffset,
                                                    double velocityX,
                                                    double velocityY,
                                                    double touchX,
                                                    double width,
                                                    bool rightToLeft,
                                                    bool canGoBack,
                                                    bool canGoForward) {
    return ApolloFeedGalleryPanDispositionForGesture(offset,
                                                     maximumOffset,
                                                     velocityX,
                                                     velocityY,
                                                     touchX,
                                                     width,
                                                     rightToLeft,
                                                     canGoBack,
                                                     canGoForward);
}

int main(void) {
    const double maximumOffset = 640.0;
    const double width = 320.0;

    assert(ApolloFeedGalleryGestureOriginX(32.0, 12.0) == 20.0);
    assert(ApolloFeedGalleryGestureOriginX(width - 32.0, -12.0) == width - 20.0);

    // UIKit removes about 10pt of hysteresis before the begin callback, so a
    // physical 18pt edge start is reported near 28pt while a 26pt start is
    // reported near 36pt. Preserve the intended approximately 24pt edge band.
    assert(kApolloFeedGalleryScreenEdgeWidth == 34.0);
    assert(disposition(320.0, maximumOffset, 300.0, 10.0, 28.0, width,
                       false, true, false) == ApolloFeedGalleryPanDispositionYield);
    assert(disposition(320.0, maximumOffset, 300.0, 10.0, 36.0, width,
                       false, true, false) == ApolloFeedGalleryPanDispositionConsume);
    assert(disposition(320.0, maximumOffset, -300.0, 10.0, width - 28.0, width,
                       false, false, true) == ApolloFeedGalleryPanDispositionYield);
    assert(disposition(320.0, maximumOffset, -300.0, 10.0, width - 36.0, width,
                       false, false, true) == ApolloFeedGalleryPanDispositionConsume);

    assert(disposition(0.0, maximumOffset, 300.0, 10.0, 160.0, width,
                       false, false, false) == ApolloFeedGalleryPanDispositionYield);
    assert(disposition(maximumOffset, maximumOffset, -300.0, 10.0, 160.0, width,
                       false, false, false) == ApolloFeedGalleryPanDispositionYield);

    assert(disposition(0.0, maximumOffset, -300.0, 10.0, 160.0, width,
                       false, true, true) == ApolloFeedGalleryPanDispositionConsume);
    assert(disposition(maximumOffset, maximumOffset, 300.0, 10.0, 160.0, width,
                       false, true, true) == ApolloFeedGalleryPanDispositionConsume);
    assert(disposition(320.0, maximumOffset, 300.0, 10.0, 160.0, width,
                       false, true, true) == ApolloFeedGalleryPanDispositionConsume);

    assert(disposition(0.0, maximumOffset, 149.0, 0.0, 160.0, width,
                       false, true, true) == ApolloFeedGalleryPanDispositionConsume);
    assert(disposition(0.0, maximumOffset, 300.0, 350.0, 160.0, width,
                       false, true, true) == ApolloFeedGalleryPanDispositionConsume);

    assert(disposition(320.0, maximumOffset, 300.0, 10.0, 8.0, width,
                       false, true, false) == ApolloFeedGalleryPanDispositionYield);
    assert(disposition(320.0, maximumOffset, -300.0, 10.0, width - 8.0, width,
                       false, false, true) == ApolloFeedGalleryPanDispositionYield);
    assert(disposition(320.0, maximumOffset, 300.0, 10.0, 8.0, width,
                       false, false, true) == ApolloFeedGalleryPanDispositionConsume);

    assert(disposition(320.0, maximumOffset, -300.0, 10.0, width - 8.0, width,
                       true, true, false) == ApolloFeedGalleryPanDispositionYield);
    assert(disposition(320.0, maximumOffset, 300.0, 10.0, 8.0, width,
                       true, false, true) == ApolloFeedGalleryPanDispositionYield);

    puts("feed_gallery_gesture_policy_tests passed");
    return 0;
}
