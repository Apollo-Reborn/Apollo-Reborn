#import <UIKit/UIKit.h>

#import "ApolloState.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    BOOL usesFlexibleSideBySideLayout;
    CGFloat centerXOffset;
    CGFloat horizontalMargin;
} ApolloFeedShortcutItemGeometry;

NSArray<UIView *> *ApolloFeedShortcutInstallLayout(UIView *hostView,
                                                    NSArray<UIView *> *items,
                                                    NSArray<UIView *> *contentViews,
                                                    NSArray<NSLayoutConstraint *> *contentCenterXConstraints,
                                                    ApolloSubredditFeedLayout layout,
                                                    UIColor *separatorColor,
                                                    CGFloat stackHorizontalOffset);

// Apollo's own feed rows in section 0 (Home, Popular, All, Moderator: 0-3),
// in native row order. Row mapping (taps, hiding, validation) uses these.
NSArray<NSNumber *> *ApolloFeedShortcutVisibleIndexes(void);
// Feed index for the Reborn-only Pal Home shortcut (no native row).
static const NSInteger ApolloFeedShortcutPalHomeIndex = 4;
// Whether the Pal Home shortcut shows (Pal Home on, not hidden).
BOOL ApolloFeedShortcutShowsPalHome(void);
// What to draw: the native indexes plus Pal Home when it shows.
NSArray<NSNumber *> *ApolloFeedShortcutDisplayIndexes(void);
// Grid and Side-by-side shrink type for four or more; Side-by-side splits
// five onto two lines (ApolloFeedShortcutInstallLayout does the split).
BOOL ApolloFeedShortcutUsesCompactLayout(ApolloSubredditFeedLayout layout, NSUInteger itemCount, CGFloat availableWidth, CGFloat widthLimit);
BOOL ApolloFeedShortcutSplitsOntoTwoLines(ApolloSubredditFeedLayout layout, NSUInteger itemCount);
// Title size for the compact (four/five-up) Grid and Side-by-side.
CGFloat ApolloFeedShortcutCompactTitlePointSize(ApolloSubredditFeedLayout layout, NSUInteger itemCount);
CGFloat ApolloFeedShortcutLayoutHeightForCount(ApolloSubredditFeedLayout layout,
                                               UITraitCollection *traitCollection,
                                               NSUInteger itemCount);
NSString *ApolloFeedShortcutShortTitle(NSInteger index);
NSString *ApolloFeedShortcutRowTitle(NSInteger index);
NSString *ApolloFeedShortcutDetail(NSInteger index);
UIColor *ApolloFeedShortcutColor(NSInteger index);
UIImage *ApolloFeedShortcutIconImage(NSInteger index,
                                     ApolloSubredditFeedIconStyle style,
                                     ApolloSubredditFeedLayout layout,
                                     NSUInteger itemCount);
UIImage *ApolloSubredditClassicMetaFeedIcon(NSInteger index);

ApolloSubredditFeedLayout ApolloFeedShortcutEffectiveLayout(ApolloSubredditFeedLayout preferredLayout,
                                                             NSUInteger itemCount,
                                                             UITraitCollection *traitCollection);
ApolloFeedShortcutItemGeometry ApolloFeedShortcutItemGeometryForLayout(ApolloSubredditFeedLayout layout,
                                                                        NSUInteger itemCount,
                                                                        NSInteger feedIndex);
CGFloat ApolloFeedShortcutLayoutHeight(ApolloSubredditFeedLayout layout,
                                       UITraitCollection *traitCollection);
CGFloat ApolloFeedShortcutRowHeight(UITraitCollection *traitCollection);
CGFloat ApolloFeedShortcutPreviewRowItemHeight(UITraitCollection *traitCollection);
CGFloat ApolloFeedShortcutDisplayIconSize(ApolloSubredditFeedIconStyle style,
                                          ApolloSubredditFeedLayout layout,
                                          NSUInteger itemCount);
CGFloat ApolloFeedShortcutContentSpacing(ApolloSubredditFeedLayout layout, NSUInteger itemCount);

#ifdef __cplusplus
}
#endif
