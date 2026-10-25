// Foundation-only rules shared by the native comments navigator and its host
// tests. No UIKit, runtime layout, or network access belongs in this module.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Apollo encodes PostCommentsSnapshots as alternating post IDs and snapshots.
// timestamp uses Swift Date's seconds since 2001-01-01, not Unix seconds.
NSDate *_Nullable ApolloCommentNavigationBaseline(NSData *_Nullable snapshotJSON,
                                                   NSString *_Nullable postID);

// "New" follows the previous-visit baseline for the duration of a visit.
// Own comments are excluded, matching Apollo's native highlight behavior.
BOOL ApolloCommentNavigationIsNew(NSDate *_Nullable created,
                                  NSDate *_Nullable baseline,
                                  NSString *_Nullable author,
                                  NSString *_Nullable activeUsername);

// Positions are in ascending table/display order. A valid retained cursor
// advances by ordinal; otherwise navigation starts from the viewport anchor.
// The anchor has a two-point dead band so a just-landed row is not reselected.
// direction > 0 is next, < 0 is previous; zero or invalid input has no target.
// Returns NSNotFound for no target and always initializes wrapped when given.
NSInteger ApolloCommentNavigationTargetIndex(NSArray<NSNumber *> *rowPositions,
                                             double anchorY,
                                             NSInteger direction,
                                             NSInteger currentIndex,
                                             BOOL useCurrentIndex,
                                             BOOL *_Nullable wrapped);

__END_DECLS

NS_ASSUME_NONNULL_END
