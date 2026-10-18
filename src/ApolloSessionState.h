#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedURLKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedItemKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedDeltaKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedOffsetKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailURLKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailItemKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailDeltaKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailOffsetKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateSavedAtKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateAccountScopeKey;

// Returns a property-list-safe, bounded session snapshot, or nil for malformed,
// unsupported, or expired data. Unknown keys are discarded so a future format
// cannot accidentally become an execution surface in an older build.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
ApolloSessionStateNormalize(NSDictionary * _Nullable candidate,
                            NSDate *now,
                            NSTimeInterval maximumAge);

// Apollo-owned destinations accepted by cold restoration. Feed and post routes
// are deliberately distinct so a modified plist cannot turn the detail phase
// into an arbitrary second navigation. The Reborn home sentinel is local; all
// Reddit destinations go through Apollo's own URL router.
FOUNDATION_EXPORT BOOL ApolloSessionStateFeedURLIsAllowed(NSString * _Nullable value);
FOUNDATION_EXPORT BOOL ApolloSessionStateDetailURLIsAllowed(NSString * _Nullable value);

NS_ASSUME_NONNULL_END
