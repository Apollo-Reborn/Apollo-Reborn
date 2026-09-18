#import "ApolloDeviceReservedRegions.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceGeometry.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"

// iOS 27.1 UIKit spelling (Swift: UIView.reservedRegions(kind:options:)).
// Step 5 pins a 27.1 *device* SDK when iPhoneOS27.1.sdk is present, but CI
// and many Macs still compile against 26.0. Public iOS 27.0 headers have no
// reservedRegions types/enums (and 27.1 ObjC names are not in this tree),
// so we keep respondsToSelector: + kind probe 0..2 instead of inventing
// UIReservedRegionKind* that would fail a 26-only toolchain or silently
// mismatch. Options bit 0 is `.includeInactive` per Apple's Tech Talk.
enum {
    kApolloReservedKindProbeMin = 0,
    kApolloReservedKindProbeMax = 2,
    kApolloReservedOptionIncludeInactive = 1 << 0,
};

static SEL ApolloReservedRegionsSelector(void) {
    static SEL selector = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([UIView instancesRespondToSelector:@selector(reservedRegionsForKind:options:)]) {
            selector = @selector(reservedRegionsForKind:options:);
        } else {
            SEL alt = NSSelectorFromString(@"reservedRegionsWithKind:options:");
            if ([UIView instancesRespondToSelector:alt]) {
                selector = alt;
            } else {
                alt = NSSelectorFromString(@"reservedRegionsOfKind:options:");
                if ([UIView instancesRespondToSelector:alt]) selector = alt;
            }
        }
        if (selector) {
            ApolloLog(@"[MediaHinge] reservedRegions selector=%s", sel_getName(selector));
        } else {
            ApolloLog(@"[MediaHinge] reservedRegions unavailable; chrome/safe-area fallback");
        }
        if (objc_getClass("UIArrangementViewController")) {
            ApolloLog(@"[MediaHinge] UIArrangementViewController present (unused: media is full-bleed, not a primary/secondary pair)");
        }
    });
    return selector;
}

static BOOL ApolloReservedRegionIsActive(id region, BOOL includeInactive) {
    if (includeInactive || !region) return YES;
    if ([region respondsToSelector:@selector(isActive)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(region, @selector(isActive));
    }
    id value = [region respondsToSelector:@selector(valueForKey:)]
        ? [region valueForKey:@"isActive"] : nil;
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    return YES;
}

static BOOL ApolloReservedReadFrame(id region, CGRect *outRect, BOOL allowEmpty) {
    if (!region || !outRect) return NO;
    CGRect frame = CGRectNull;
    if ([region respondsToSelector:@selector(frame)]) {
        frame = ((CGRect (*)(id, SEL))objc_msgSend)(region, @selector(frame));
    } else if ([region isKindOfClass:[NSValue class]]) {
        frame = [(NSValue *)region CGRectValue];
    } else {
        return NO;
    }
    if (CGRectIsNull(frame)) return NO;
    if (!allowEmpty && CGRectIsEmpty(frame)) return NO;
    if (frame.size.width < 0.0 || frame.size.height < 0.0) return NO;
    *outRect = frame;
    return YES;
}

static BOOL ApolloReservedReadMargins(id region, UIEdgeInsets *outInsets) {
    if (!region || !outInsets) return NO;
    if (![region respondsToSelector:@selector(margins)]) return NO;
    UIEdgeInsets margins = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(region, @selector(margins));
    if (margins.top < 0.0 || margins.left < 0.0
        || margins.bottom < 0.0 || margins.right < 0.0) {
        return NO;
    }
    *outInsets = margins;
    return YES;
}

static NSUInteger ApolloReservedCollect(UIView *view,
                                        CGRect *outRects,
                                        NSUInteger maxCount,
                                        BOOL includeInactive,
                                        UIEdgeInsets *outMargins) {
    if (outMargins) *outMargins = UIEdgeInsetsZero;
    SEL selector = ApolloReservedRegionsSelector();
    if (!view || !outRects || maxCount == 0 || !selector) return 0;

    typedef NSArray *(*ReservedIMP)(id, SEL, NSInteger, NSUInteger);
    ReservedIMP imp = (ReservedIMP)objc_msgSend;
    NSUInteger options = includeInactive ? kApolloReservedOptionIncludeInactive : 0;
    NSUInteger count = 0;
    UIEdgeInsets margins = UIEdgeInsetsZero;

    for (NSInteger kind = kApolloReservedKindProbeMin; kind <= kApolloReservedKindProbeMax; kind++) {
        NSArray *regions = nil;
        @try {
            regions = imp(view, selector, kind, options);
        } @catch (__unused NSException *exception) {
            regions = nil;
        }
        if (![regions isKindOfClass:[NSArray class]]) continue;
        for (id region in regions) {
            if (!ApolloReservedRegionIsActive(region, includeInactive)) continue;
            CGRect frame = CGRectZero;
            if (!ApolloReservedReadFrame(region, &frame, includeInactive)) continue;
            UIEdgeInsets regionMargins;
            if (ApolloReservedReadMargins(region, &regionMargins)) {
                margins.top = MAX(margins.top, regionMargins.top);
                margins.left = MAX(margins.left, regionMargins.left);
                margins.bottom = MAX(margins.bottom, regionMargins.bottom);
                margins.right = MAX(margins.right, regionMargins.right);
            }
            if (count < maxCount) {
                outRects[count] = frame;
                count++;
            }
        }
    }
    if (outMargins) *outMargins = margins;
    return count;
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
