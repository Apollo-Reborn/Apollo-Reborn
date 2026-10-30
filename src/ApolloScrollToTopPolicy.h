#pragma once

#import <Foundation/Foundation.h>

// iOS 27's native minimized header can leave the feed under the status-bar
// tap region on adaptive devices. UIKit still asks the status-bar proxy to
// scroll, but also delivers the same touch to the row underneath. The content
// list needs a cancelling tap recognizer only for that narrow region.
static inline BOOL ApolloScrollToTopNeedsContentTapShield(
    BOOL adaptiveBars,
    BOOL hideHeaderOnScroll,
    BOOL ownerVisible,
    double touchY,
    double statusBarHeight) {
    return adaptiveBars && hideHeaderOnScroll && ownerVisible &&
        statusBarHeight > 0.0 && touchY >= 0.0 && touchY <= statusBarHeight + 1.0;
}
