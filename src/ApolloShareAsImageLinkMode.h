#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, ApolloShareLinkMode) {
    ApolloShareLinkModeNone = 0,
    ApolloShareLinkModePost = 1,
    ApolloShareLinkModeComment = 2,
};

FOUNDATION_EXPORT NSString *const ApolloShareLinkModePreferenceKey;
FOUNDATION_EXPORT NSString *const ApolloShareLinkLegacyEnabledKey;

/// Returns the persisted selection, migrating the old Include Link boolean on
/// read. Post shares cannot target a comment, so a saved Comment choice appears
/// as Post without erasing the user's comment-share preference.
ApolloShareLinkMode ApolloShareLinkModeRead(NSUserDefaults *defaults, BOOL hasComment);

/// Persists the new mode and mirrors its enabled state to the legacy boolean so
/// the Share as Video module and older builds continue to attach a post link.
void ApolloShareLinkModeWrite(NSUserDefaults *defaults, ApolloShareLinkMode mode);

/// Resolves `-[RDKComment urlWithContext:]`. Apollo ignores the argument and
/// always builds reddit.com/r/<sub>/comments/<post>/_/<comment>/?context=1, the
/// same link its own comment Share uses. A missing, malformed, or throwing
/// comment object safely falls back to the post URL.
NSURL *ApolloShareLinkCommentURL(id comment, NSURL *postURL);

/// Makes Apollo's relative Reddit permalinks suitable for external share targets.
NSURL *ApolloShareLinkAbsoluteURL(NSURL *url);

/// Resolves the selected destination for image and video exports. Comment mode
/// falls back to the post; None returns nil.
NSURL *ApolloShareLinkURLForMode(ApolloShareLinkMode mode, id comment, NSURL *postURL);

#ifdef __cplusplus
}
#endif
