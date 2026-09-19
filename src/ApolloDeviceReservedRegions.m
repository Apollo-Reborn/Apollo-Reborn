#import "ApolloDeviceReservedRegions.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceGeometry.h"

#import <string.h>

// UIKit reservedRegions SIGSEGVs on Duo sim even with window+scene during
// first commit (x0=0 at +0x10); hinge gutters come from layoutMargins/chrome
// instead. Do not call reservedRegions / reservedRegionsForKind:options: /
// objc_msgSend of that selector.
static NSUInteger ApolloReservedCollect(UIView *view,
                                        CGRect *outRects,
                                        NSUInteger maxCount,
                                        BOOL includeInactive,
                                        UIEdgeInsets *outMargins) {
    (void)view;
    (void)outRects;
    (void)maxCount;
    (void)includeInactive;
    if (outMargins) *outMargins = UIEdgeInsetsZero;
    return 0;
}

static void ApolloReservedConvertRects(const CGRect *rects,
                                       NSUInteger count,
                                       ApolloReservedRect *outRects) {
    for (NSUInteger i = 0; i < count; i++) {
        outRects[i].x = rects[i].origin.x;
        outRects[i].y = rects[i].origin.y;
        outRects[i].width = rects[i].size.width;
        outRects[i].height = rects[i].size.height;
    }
}

NSUInteger ApolloDeviceCopyReservedRectsForView(UIView *view,
                                                CGRect *outRects,
                                                NSUInteger maxCount,
                                                BOOL includeInactive) {
    return ApolloReservedCollect(view, outRects, maxCount, includeInactive, NULL);
}

ApolloReservedAvoidance ApolloDeviceReservedAvoidanceForView(UIView *view) {
    ApolloReservedAvoidance empty;
    memset(&empty, 0, sizeof(empty));
    if (!view) return empty;
    CGRect rects[8];
    UIEdgeInsets margins = UIEdgeInsetsZero;
    NSUInteger count = ApolloReservedCollect(view, rects, 8, NO, &margins);
    ApolloReservedRect converted[8];
    ApolloReservedConvertRects(rects, count, converted);
    ApolloReservedAvoidance avoid = ApolloReservedAvoidanceMake(
        view.bounds.size.width, view.bounds.size.height, converted, (unsigned)count);
    avoid.edge.left = ApolloReservedMax(avoid.edge.left, margins.left);
    avoid.edge.top = ApolloReservedMax(avoid.edge.top, margins.top);
    avoid.edge.right = ApolloReservedMax(avoid.edge.right, margins.right);
    avoid.edge.bottom = ApolloReservedMax(avoid.edge.bottom, margins.bottom);
    return avoid;
}

BOOL ApolloDeviceHasDivisionRegionInView(UIView *view) {
    if (!view) return NO;
    CGRect rects[8];
    NSUInteger count = ApolloDeviceCopyReservedRectsForView(view, rects, 8, YES);
    if (count == 0) return NO;
    ApolloReservedRect converted[8];
    ApolloReservedConvertRects(rects, count, converted);
    ApolloReservedAvoidance avoid = ApolloReservedAvoidanceMake(
        view.bounds.size.width, view.bounds.size.height, converted, (unsigned)count);
    return avoid.hasVerticalGap != 0;
}

UIEdgeInsets ApolloDeviceMediaInsetsForView(UIView *view) {
    UIEdgeInsets chrome = ApolloDeviceChromeInsetsForView(view);
    if (!view) return chrome;
    ApolloReservedAvoidance avoid = ApolloDeviceReservedAvoidanceForView(view);
    ApolloReservedInsets chromeInsets = {
        .left = chrome.left, .top = chrome.top, .right = chrome.right, .bottom = chrome.bottom
    };
    ApolloReservedInsets media = ApolloMediaInsetsUnion(chromeInsets, avoid);
    return UIEdgeInsetsMake((CGFloat)media.top, (CGFloat)media.left,
                            (CGFloat)media.bottom, (CGFloat)media.right);
}

CGRect ApolloDeviceShiftRectOffReservedInView(UIView *container, CGRect frame) {
    if (!container) return frame;
    CGRect rects[8];
    NSUInteger count = ApolloDeviceCopyReservedRectsForView(container, rects, 8, NO);
    if (count == 0) return frame;
    ApolloReservedRect converted[8];
    ApolloReservedConvertRects(rects, count, converted);
    ApolloReservedRect shifted = ApolloReservedShiftRect(
        (ApolloReservedRect){ frame.origin.x, frame.origin.y, frame.size.width, frame.size.height },
        container.bounds.size.width, container.bounds.size.height,
        converted, (unsigned)count);
    return CGRectMake(shifted.x, shifted.y, shifted.width, shifted.height);
}

void ApolloDeviceAvoidReservedRegionsForView(UIView *view) {
    UIView *container = view.superview;
    if (!view || !container) return;
    CGRect next = ApolloDeviceShiftRectOffReservedInView(container, view.frame);
    if (!CGRectEqualToRect(view.frame, next)) {
        view.frame = next;
    }
}

void ApolloDevicePlaceHorizontalBarInView(UIView *view,
                                          CGFloat chromeLeft,
                                          CGFloat chromeRight,
                                          CGFloat *outX,
                                          CGFloat *outWidth) {
    ApolloReservedAvoidance avoid = ApolloDeviceReservedAvoidanceForView(view);
    double x = 0.0;
    double width = 0.0;
    ApolloReservedPlaceHorizontalBar(view ? view.bounds.size.width : 0.0,
                                     chromeLeft, chromeRight,
                                     &avoid, &x, &width);
    if (outX) *outX = (CGFloat)x;
    if (outWidth) *outWidth = (CGFloat)width;
}
