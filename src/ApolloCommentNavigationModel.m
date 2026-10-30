#import "ApolloCommentNavigationModel.h"
#include <math.h>

static const NSUInteger kCNMaximumSnapshotBytes = 2 * 1024 * 1024;
static const double kCNAnchorSlack = 2.0;

static NSString *CNBarePostID(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *identifier = [(NSString *)value lowercaseString];
    if ([identifier hasPrefix:@"t3_"]) identifier = [identifier substringFromIndex:3];
    return identifier.length > 0 ? identifier : nil;
}

static BOOL CNFiniteNumber(id value) {
    return [value isKindOfClass:NSNumber.class]
        && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && isfinite([(NSNumber *)value doubleValue]);
}

NSDate *ApolloCommentNavigationBaseline(NSData *snapshotJSON, NSString *postID) {
    NSString *wanted = CNBarePostID(postID);
    if (!wanted || ![snapshotJSON isKindOfClass:NSData.class]
        || snapshotJSON.length == 0 || snapshotJSON.length > kCNMaximumSnapshotBytes) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:snapshotJSON options:0 error:nil];
    if (![decoded isKindOfClass:NSArray.class] || [(NSArray *)decoded count] % 2 != 0) return nil;

    NSArray *entries = decoded;
    for (NSUInteger index = 0; index < entries.count; index += 2) {
        if (![CNBarePostID(entries[index]) isEqualToString:wanted]) continue;
        id snapshot = entries[index + 1];
        if (![snapshot isKindOfClass:NSDictionary.class]) continue;
        id timestamp = snapshot[@"timestamp"];
        if (!CNFiniteNumber(timestamp) || [(NSNumber *)timestamp doubleValue] <= 0) continue;
        // Keep the reference-date epoch intact. Treating this value as Unix
        // time would move the cutoff 31 years earlier and label every reply new.
        return [NSDate dateWithTimeIntervalSinceReferenceDate:[timestamp doubleValue]];
    }
    return nil;
}

BOOL ApolloCommentNavigationIsNew(NSDate *created, NSDate *baseline,
                                  NSString *author, NSString *activeUsername) {
    if (![created isKindOfClass:NSDate.class] || ![baseline isKindOfClass:NSDate.class]) return NO;
    NSTimeInterval createdTime = created.timeIntervalSinceReferenceDate;
    NSTimeInterval baselineTime = baseline.timeIntervalSinceReferenceDate;
    if (!isfinite(createdTime) || !isfinite(baselineTime) || createdTime <= baselineTime) return NO;
    if ([author isKindOfClass:NSString.class] && author.length > 0
        && [activeUsername isKindOfClass:NSString.class] && activeUsername.length > 0
        && [author caseInsensitiveCompare:activeUsername] == NSOrderedSame) return NO;
    return YES;
}

NSInteger ApolloCommentNavigationTargetIndex(NSArray<NSNumber *> *rowPositions,
                                             double anchorY,
                                             NSInteger direction,
                                             NSInteger currentIndex,
                                             BOOL useCurrentIndex,
                                             BOOL *wrapped) {
    if (wrapped) *wrapped = NO;
    if (![rowPositions isKindOfClass:NSArray.class] || rowPositions.count == 0 || direction == 0) return NSNotFound;
    // Fail closed on unexpected geometry instead of jumping to an arbitrary
    // row. The UIKit caller can retry after the pending table update settles.
    double previous = -INFINITY;
    for (id position in rowPositions) {
        if (!CNFiniteNumber(position) || [position doubleValue] < previous) return NSNotFound;
        previous = [position doubleValue];
    }

    NSInteger count = (NSInteger)rowPositions.count;
    if (useCurrentIndex && currentIndex >= 0 && currentIndex < count) {
        NSInteger next = currentIndex + (direction > 0 ? 1 : -1);
        if (next >= 0 && next < count) return next;
        if (wrapped) *wrapped = YES;
        return direction > 0 ? 0 : count - 1;
    }
    if (!isfinite(anchorY)) return NSNotFound;
    if (direction > 0) {
        for (NSInteger index = 0; index < count; index++) {
            if ([rowPositions[(NSUInteger)index] doubleValue] > anchorY + kCNAnchorSlack) return index;
        }
    } else {
        for (NSInteger index = count - 1; index >= 0; index--) {
            if ([rowPositions[(NSUInteger)index] doubleValue] < anchorY - kCNAnchorSlack) return index;
        }
    }
    if (wrapped) *wrapped = YES;
    return direction > 0 ? 0 : count - 1;
}
