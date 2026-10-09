#import <Foundation/Foundation.h>

// Classes the tweak looks up by name (Apollo's binary, Texture, RedditKit,
// private UIKit, and the tweak's own classes), resolved once by the
// constructor in ApolloClasses.m. That constructor is listed first in the
// Makefile so it runs before every module's %ctor, and every image these
// classes live in is mapped by then. A class absent for the whole process
// (an older OS, a framework that never loads) stays Nil, so callers nil-check.
//
// A class whose image can load after launch gets a lazy accessor below
// instead of a global.

__BEGIN_DECLS

extern Class ApolloClassASBackgroundLayoutSpec;
extern Class ApolloClassASButtonNode;
extern Class ApolloClassASCellNode;
extern Class ApolloClassASCenterLayoutSpec;
extern Class ApolloClassASCollectionView;
extern Class ApolloClassASControlNode;
extern Class ApolloClassASDisplayNode;
extern Class ApolloClassASEditableTextNode;
extern Class ApolloClassASImageNode;
extern Class ApolloClassASInsetLayoutSpec;
extern Class ApolloClassASLayout;
extern Class ApolloClassASLayoutSpec;
extern Class ApolloClassASNetworkImageNode;
extern Class ApolloClassASRatioLayoutSpec;
extern Class ApolloClassASStackLayoutSpec;
extern Class ApolloClassASTableNode;
extern Class ApolloClassASTableView;
extern Class ApolloClassASTableViewController;
extern Class ApolloClassASTextNode;
extern Class ApolloClassASTextNode2;
extern Class ApolloClassAccountManager;
extern Class ApolloClassActionController;
extern Class ApolloClassApolloContentBridge;
extern Class ApolloClassApolloDefaultTableViewCell;
extern Class ApolloClassApolloFeedGalleryCarouselView;
extern Class ApolloClassApolloFoundationModels;
extern Class ApolloClassApolloNavigationAnimator;
extern Class ApolloClassApolloNavigationController;
extern Class ApolloClassApolloOnscreenBridge;
extern Class ApolloClassApolloProfileHeaderView;
extern Class ApolloClassApolloProfileNavTitleView;
extern Class ApolloClassApolloSearchBarTextField;
extern Class ApolloClassApolloSettingsShortcutsViewController;
extern Class ApolloClassApolloSubredditHeaderWrapperView;
extern Class ApolloClassApolloSubtitleTableViewCell;
extern Class ApolloClassApolloTableViewController;
extern Class ApolloClassCAFilter;
extern Class ApolloClassCommentCellNode;
extern Class ApolloClassCommentsHeaderCellNode;
extern Class ApolloClassCommentsHeaderSectionController;
extern Class ApolloClassCommentsViewController;
extern Class ApolloClassCompactPostCellNode;
extern Class ApolloClassComposePostViewController;
extern Class ApolloClassComposeViewController;
extern Class ApolloClassCrosspostNode;
extern Class ApolloClassCrosspostPerformViewController;
extern Class ApolloClassDualStateButtonNode;
extern Class ApolloClassFLAnimatedImage;
extern Class ApolloClassFLAnimatedImageView;
extern Class ApolloClassJumpBar;
extern Class ApolloClassLGFeaturedStripCell;
extern Class ApolloClassLGPackGridRowCell;
extern Class ApolloClassLargePostCellNode;
extern Class ApolloClassLinkButtonNode;
extern Class ApolloClassMFMailComposeViewController;
extern Class ApolloClassMFMessageComposeViewController;
extern Class ApolloClassMarkdownNode;
extern Class ApolloClassMarkdownTextNode;
extern Class ApolloClassMediaPageViewController;
extern Class ApolloClassMediaViewerController;
extern Class ApolloClassMediaViewerPresentationController;
extern Class ApolloClassModeratorReportsController;
extern Class ApolloClassModmailInboxViewController;
extern Class ApolloClassPixelPalAddedSceneElementImageView;
extern Class ApolloClassPixelPalOverlayViewController;
extern Class ApolloClassPlayerLayerContainerView;
extern Class ApolloClassPollNode;
extern Class ApolloClassPollOptionNode;
extern Class ApolloClassPollResultNode;
extern Class ApolloClassPostInfoNode;
extern Class ApolloClassPostsSearchResultsViewController;
extern Class ApolloClassPostsViewController;
extern Class ApolloClassProfileFeatureCellNode;
extern Class ApolloClassProfileViewController;
extern Class ApolloClassRDKClient;
extern Class ApolloClassRDKComment;
extern Class ApolloClassRDKFlair;
extern Class ApolloClassRDKFlairOption;
extern Class ApolloClassRDKGallery;
extern Class ApolloClassRDKGalleryItemImage;
extern Class ApolloClassRDKLink;
extern Class ApolloClassRDKMessage;
extern Class ApolloClassRDKMultireddit;
extern Class ApolloClassRDKMultiredditDescription;
extern Class ApolloClassRDKObjectBuilder;
extern Class ApolloClassRDKSubreddit;
extern Class ApolloClassRecreatedTableSectionHeaderView;
extern Class ApolloClassRedditListTableViewCell;
extern Class ApolloClassRedditListViewController;
extern Class ApolloClassRichMediaNode;
extern Class ApolloClassSaveMediaActivity;
extern Class ApolloClassSearchViewController;
extern Class ApolloClassSettingsViewController;
extern Class ApolloClassShareAsImageViewController;
extern Class ApolloClassSubItemTableViewCell;
extern Class ApolloClassThickSeparatorCellNode;
extern Class ApolloClassThinSeparatorCellNode;
extern Class ApolloClassTranslatorViewController;
extern Class ApolloClassUIBarBadgeView;
extern Class ApolloClassUIButtonLabel;
extern Class ApolloClassUIContextMenuListView;
extern Class ApolloClassUIContextMenuPlatformMetricsGlass;
extern Class ApolloClassUIContinuousSelectionGestureRecognizer;
extern Class ApolloClassUICornerConfiguration;
extern Class ApolloClassUIDropShadowView;
extern Class ApolloClassUIFloatingTabBarSelectionContainerView;
extern Class ApolloClassUIGlassEffect;
extern Class ApolloClassUIKBKeyView;
extern Class ApolloClassUIKBVisualEffectView;
extern Class ApolloClassUINavigationBarHostedViewContainer;
extern Class ApolloClassUINavigationBarPlatterGlassView;
extern Class ApolloClassUINavigationBarPlatterView;
extern Class ApolloClassUINavigationBarTitleControl;
extern Class ApolloClassUIScrollEdgeEffectStyle;
extern Class ApolloClassUserCommentsViewController;

// TextInputUI is soft-linked by UIKit and loads the first time the keyboard
// needs it, so this retries until the class appears.
Class ApolloTUIVariantSelectorViewClass(void);

// Social.framework is not linked by Apollo or the tweak; it loads only if
// something (e.g. a share flow) pulls it in, and may never load at all. The
// lookup is retried only after a new image has been mapped, so a miss on a hot
// path (every view controller's layout pass) is a single atomic load.
Class ApolloSLComposeViewControllerClass(void);

__END_DECLS
