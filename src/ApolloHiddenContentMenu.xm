#import "ApolloCommon.h"
#import "ApolloHiddenContentViewController.h"
#import "ApolloAccountCredentials.h"

// Defined in ApolloUserAvatars.xm -- more reliable than reading "userInfo"
// directly, which can be nil for the signed-in user's own profile.
extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);

// Shared entry point for the profile shortcut and own-profile menu.
void ApolloHiddenContentPresentFromProfile(UIViewController *profileViewController) {
    if (!profileViewController) return;
    NSString *profileUsername = ApolloUsernameFromProfileViewController(profileViewController);

    if (profileUsername.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hidden & Deleted"
                                                                         message:@"Couldn't confirm this profile's username yet. Try again once the profile has finished loading."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [profileViewController presentViewController:alert animated:YES completion:nil];
        return;
    }

    [ApolloHiddenContentViewController presentForUsername:profileUsername
                                       fromViewController:profileViewController];
}

// Profile shortcuts are Texture nodes. Append the archive control to the
// Saved or Comments node while preserving Apollo's section model.
#import <objc/runtime.h>
#import "ApolloThemeRuntime.h"

typedef struct { CGSize min; CGSize max; } ApolloHiddenSizeRange;
@interface ASDisplayNode : NSObject
- (instancetype)initWithViewBlock:(UIView *(^)(void))block;
- (void)addSubnode:(id)node;
- (void)onDidLoad:(void (^)(ASDisplayNode *node))body;
- (id)style;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) CALayer *layer;
- (void)displayImmediately;
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic) BOOL automaticallyManagesSubnodes;
@property (nonatomic, copy) id (^layoutSpecBlock)(id, ApolloHiddenSizeRange);
@end
@interface ASLayoutElementStyle : NSObject
@property (nonatomic) CGSize preferredSize;
@end
@interface ASStackLayoutSpec : NSObject
+ (id)stackLayoutSpecWithDirection:(unsigned char)direction spacing:(CGFloat)spacing
                   justifyContent:(unsigned char)justify alignItems:(unsigned char)align children:(NSArray *)children;
@end
@interface ASInsetLayoutSpec : NSObject
+ (id)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end
@interface ASImageNode : ASDisplayNode
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) id imageModificationBlock;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, strong) UIColor *tintColor;
@property (nonatomic) CGFloat alpha;
@end
@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

static id ApolloHiddenObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIViewController *ApolloHiddenProfileControllerForTableNode(ASDisplayNode *tableNode) {
    UIResponder *responder = tableNode.view;
    while (responder) {
        if ([responder isKindOfClass:NSClassFromString(@"_TtC6Apollo21ProfileViewController")]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    // A Texture node block can be evaluated before its table has joined the
    // responder chain. The visible Posts navigation stack is authoritative in
    // that short window and keeps own-profile placement deterministic.
    for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
        UIViewController *candidate = window.rootViewController;
        while (candidate.presentedViewController) candidate = candidate.presentedViewController;
        if ([candidate isKindOfClass:UITabBarController.class]) {
            candidate = ((UITabBarController *)candidate).selectedViewController;
        }
        if ([candidate isKindOfClass:UINavigationController.class]) {
            candidate = ((UINavigationController *)candidate).topViewController;
        }
        if ([candidate isKindOfClass:NSClassFromString(@"_TtC6Apollo21ProfileViewController")]) return candidate;
    }
    return nil;
}

// Mark only our duplicated native node's content. Apollo remains responsible
// for its layout, theme subscriptions, surfaces and disclosure rendering.
static char ApolloHiddenTitleKey;
static char ApolloHiddenIconKey;

%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    if (objc_getAssociatedObject(self, &ApolloHiddenTitleKey) && text.length) {
        NSMutableAttributedString *replacement = [text mutableCopy];
        [replacement replaceCharactersInRange:NSMakeRange(0, replacement.length) withString:@"Hidden & Deleted"];
        %orig(replacement);
    } else {
        %orig(text);
    }
}
%end

%hook ASImageNode
- (void)setImage:(UIImage *)image {
    if (objc_getAssociatedObject(self, &ApolloHiddenIconKey)) {
        // Preserve our original eye-slash artwork, but flatten its symbol
        // metadata so Apollo's redraws cannot change the symbol point size.
        static UIImage *icon;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
            UIImage *symbol = [[UIImage systemImageNamed:@"eye.slash" withConfiguration:configuration]
                imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGSize canvas = CGSizeMake(28, 28);
            // Match the native Hidden artwork's 28-by-21-point footprint.
            // SF Symbol images include optical padding, so fitting their full
            // image bounds into 28 points makes the visible glyph too small.
            CGSize size = CGSizeMake(32, 24);
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas];
            icon = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [symbol drawInRect:CGRectMake((canvas.width - size.width) / 2,
                                             (canvas.height - size.height) / 2, size.width, size.height)];
            }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        });
        image = icon;
    }
    %orig(image);
}
%end

@interface ApolloHiddenProfileTap : NSObject
+ (instancetype)shared;
- (void)open:(UITapGestureRecognizer *)gesture;
@end
@implementation ApolloHiddenProfileTap
+ (instancetype)shared {
    static ApolloHiddenProfileTap *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [self new]; });
    return target;
}
- (void)open:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    for (UIResponder *responder = gesture.view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:NSClassFromString(@"_TtC6Apollo21ProfileViewController")]) {
            ApolloHiddenContentPresentFromProfile((UIViewController *)responder);
            return;
        }
    }
}
@end

%hook _TtC6Apollo11ListAdapter
- (id)tableNode:(id)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    id (^originalBlock)(void) = %orig;
    if (!originalBlock) return nil;
    UIViewController *profileController = ApolloHiddenProfileControllerForTableNode((ASDisplayNode *)tableNode);
    NSString *profileUsername = ApolloUsernameFromProfileViewController(profileController);
    NSString *activeUsername = ApolloActiveAccountUsername();
    BOOL ownProfile = profileUsername.length > 0 && activeUsername.length > 0 &&
        [profileUsername caseInsensitiveCompare:activeUsername] == NSOrderedSame;
    // Profile rows alternate with native separator rows. Reuse the preceding
    // factory so the inserted divider retains Apollo's insets and live themes.
    id (^separatorBlock)(void) = nil;
    if (profileController && indexPath.row > 0) {
        NSIndexPath *previous = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
        separatorBlock = %orig(tableNode, previous);
    }
    return [^id {
        ASDisplayNode *original = originalBlock();
        if (![original isKindOfClass:NSClassFromString(@"_TtC6Apollo22ProfileFeatureCellNode")]) return original;
        ASTextNode *title = ApolloHiddenObjectIvar(original, "titleNode");
        NSString *saved = [[NSBundle mainBundle] localizedStringForKey:@"Saved" value:@"Saved" table:nil];
        NSString *comments = [[NSBundle mainBundle] localizedStringForKey:@"Comments" value:@"Comments" table:nil];
        NSString *insertionTitle = ownProfile ? saved : comments;
        if (![title.attributedText.string isEqualToString:insertionTitle]) return original;
        // The adapter's factory creates a fresh, fully themed native row.
        // Keep both nodes in the same adapter slot without altering its model.
        ASDisplayNode *shortcut = originalBlock();
        if (shortcut == original || ![shortcut isKindOfClass:[original class]]) return original;
        ASDisplayNode *separator = separatorBlock ? separatorBlock() : nil;
        if (![separator isKindOfClass:NSClassFromString(@"_TtC6Apollo21ThinSeparatorCellNode")]) {
            ApolloLog(@"[HiddenShortcut] Expected native separator before profile row");
            return original;
        }
        ASTextNode *shortcutTitle = ApolloHiddenObjectIvar(shortcut, "titleNode");
        ASImageNode *shortcutIcon = ApolloHiddenObjectIvar(shortcut, "iconNode");
        objc_setAssociatedObject(shortcutTitle, &ApolloHiddenTitleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(shortcutIcon, &ApolloHiddenIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        shortcutTitle.attributedText = shortcutTitle.attributedText;
        shortcutIcon.image = shortcutIcon.image;
        [shortcut onDidLoad:^(ASDisplayNode *loaded) {
            UIView *view = loaded.view;
            view.accessibilityLabel = @"Hidden & Deleted";
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[ApolloHiddenProfileTap shared] action:@selector(open:)];
            tap.cancelsTouchesInView = YES;
            [view addGestureRecognizer:tap];
        }];
        ASDisplayNode *wrapper = [NSClassFromString(@"ASCellNode") new];
        wrapper.backgroundColor = UIColor.clearColor;
        wrapper.automaticallyManagesSubnodes = YES;
        wrapper.layoutSpecBlock = ^id(id node, ApolloHiddenSizeRange range) {
            return [NSClassFromString(@"ASStackLayoutSpec") stackLayoutSpecWithDirection:0 spacing:0 justifyContent:0 alignItems:3 children:@[original, separator, shortcut]];
        };
        ApolloLog(@"[HiddenShortcut] Added profile archive shortcut after %@ (%@ profile)",
                  insertionTitle, ownProfile ? @"own" : @"other");
        return wrapper;
    } copy];
}
%end

// Apollo's selected Posts-tab behavior only knows about its own feed/profile
// controllers. This tweak-owned pushed list should participate in the same
// sequence: first re-selection scrolls it to the top, then a re-selection at
// the top returns to the profile underneath it.
%hook _TtC6Apollo13SceneDelegate

- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {
    if (tabBarController.selectedIndex == 0 &&
        viewController == tabBarController.selectedViewController &&
        [viewController isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *topViewController = navigationController.topViewController;
        if ([topViewController isKindOfClass:ApolloHiddenContentViewController.class]) {
            UITableView *tableView = ((ApolloHiddenContentViewController *)topViewController).tableView;
            CGFloat topOffset = -tableView.adjustedContentInset.top;
            BOOL isAtTop = fabs(tableView.contentOffset.y - topOffset) < 1.0;
            if (isAtTop) {
                [navigationController popViewControllerAnimated:YES];
                ApolloLog(@"[HiddenContent] Posts re-tap returned to profile");
            } else {
                [tableView setContentOffset:CGPointMake(0, topOffset) animated:YES];
                ApolloLog(@"[HiddenContent] Posts re-tap scrolled archive to top");
            }
            return NO;
        }
    }
    return %orig(tabBarController, viewController);
}

%end
