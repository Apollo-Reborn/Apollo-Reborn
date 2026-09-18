#ifndef APOLLO_DEVICE_CHROME_INSETS_H
#define APOLLO_DEVICE_CHROME_INSETS_H

// One edge of chrome that must stay out of a hinge / reserved strip without
// changing the everyday 16pt system layout margin on a normal iPhone.
//
// UIKit's layoutMargins are typically safe-area + 16. Extra beyond that is a
// fold/hinge/readable-width reservation we should honor. C-only so host tests
// can compile this header without UIKit.

static inline double ApolloDeviceChromeInset(double safe, double margin) {
    const double kSystemLayoutMargin = 16.0;
    double extra = margin - safe - kSystemLayoutMargin;
    if (extra < 0.5) extra = 0.0;
    return safe + extra;
}

#endif
