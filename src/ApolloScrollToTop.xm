#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloAutoHideTabBar.h"
#import "ApolloTopBarScrollPresentation.h"
#import "ApolloScrollToTop.h"
#import "ApolloState.h"

// Apollo's status-bar proxy calls ASTableViewController rather than scrolling
// the table directly. The original callback only saves an offset and returns
// NO, relying on a second scroll-to-top participant to move the real table.
// Own both operations here, and use adjustedContentInset for modern UIKit.
//
// What Apollo does on its own (Hopper, -[ASTableViewController
// scrollViewShouldScrollToTop:] -> sub_1002c5554): post
// com.christianselig.StatusBarTapped, whose ApolloNavigationController observer
// parks the visible table at -safeAreaInsets.top; then compare
// round(contentOffset.y) with -round(contentInset.top). Away from the top it
// stores the offset in contentOffsetBeforeStatusBarJump; at the top with an
// offset stored it scrolls back there 250 ms later; it returns NO either way.
// That is the stock "tap again to return", and it works while Apollo owns the
// inset (contentInsetAdjustmentBehavior = .never, contentInset.top written
// from the safe area in viewDidLayoutSubviews). The native search bar
// (ApolloSearchNativeBar.xm) runs its feed and comment-thread tables with
// Automatic and relativizes those writes, so contentInset.top is 0 there and
// Apollo's at-top test never passes: a tap at the top was filed as "away from
// the top" and overwrote the stored offset, which is why the return stopped
// working under Liquid Glass. This module owns the whole sequence instead:
// the notification is not posted (Apollo's observer would fight the jump) and
// both the top and the return are measured against adjustedContentInset.
//
// The saved position and the second status-bar tap are always on. The Return
// Button setting (sScrollReturnButton) only governs the visible affordance:
// the arrow beside Back and the navigation-bar tap.
static char kApolloScrollReturn;
static char kApolloScrollReturnGeometryContext;

// Match the feed action strip and its independently positioned glass title.
static CASpringAnimation *ApolloScrollReturnSpring(void) {
    CASpringAnimation *spring = [CASpringAnimation animation];
    spring.mass = 1;
    spring.stiffness = 644;
    spring.damping = 2 * 0.78 * sqrt(spring.stiffness);
    spring.duration = 0.36;
    return spring;
}

static id ApolloReturnObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}
static NSString *ApolloReturnItemID(id node) {
    for (NSString *key in @[@"comment", @"link"]) {
        id model = ApolloReturnObjectIvar(node, key.UTF8String);
        SEL selector = NSSelectorFromString(@"fullName");
        if ([model respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
            if ([value isKindOfClass:NSString.class]) return value;
        }
    }
    return nil;
}

@interface ApolloScrollReturn : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic) CGPoint savedOffset;
@property (nonatomic) CGFloat savedTopInset;
@property (nonatomic) BOOL hasPosition;
@property (nonatomic, strong) id savedNode;
@property (nonatomic, copy) NSString *savedItemID;
@property (nonatomic) CGFloat savedRowOffset;
@property (nonatomic) BOOL restoring;
@property (nonatomic) BOOL itemLookupAttempted;
@property (nonatomic, strong) CADisplayLink *jumpLink;
@property (nonatomic) CFTimeInterval jumpStartTime;
@property (nonatomic) CGFloat jumpFromY;
@property (nonatomic, strong) UIScrollView *observedScroll;
@property (nonatomic) NSUInteger jumpGeneration;
@property (nonatomic) NSUInteger geometryRevision;
@property (nonatomic) BOOL anchorUpdatePending;
@property (nonatomic, strong) UIBarButtonItem *returnItem;
@property (nonatomic) BOOL supplementedBackButton;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIButton *retiringButton;
@property (nonatomic, strong) UITapGestureRecognizer *navigationTap;
- (void)clear;
- (void)clearAnimated:(BOOL)animated;
- (void)retireButtonAnimated:(BOOL)animated;
- (void)returnToPosition;
@end

@implementation ApolloScrollReturn
- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clear)
            name:@"com.christianselig.RedditAccountChanged" object:nil];
    }
    return self;
}
- (void)clear {
    [self clearAnimated:YES];
}
- (void)clearAnimated:(BOOL)animated {
    [self stopTopJump];
    ApolloTabBarCancelScrollToTopReveal(self.owner.tabBarController);
    self.hasPosition = NO;
    self.savedNode = nil;
    self.savedItemID = nil;
    ApolloTopBarSetScrollToTopActive(self.owner.navigationController, NO);
    [self retireButtonAnimated:animated];
}
// The arrow and its exit animation, apart from the saved position: turning the
// Return Button setting off removes the arrow now but keeps the position, so
// the second status-bar tap still returns.
- (void)retireButtonAnimated:(BOOL)animated {
    [self.retiringButton.layer removeAllAnimations];
    [self.retiringButton removeFromSuperview];
    self.retiringButton = nil;
    UIButton *button = self.button;
    UINavigationBar *bar = self.owner.navigationController.navigationBar;
    UINavigationItem *item = self.owner.navigationItem;
    BOOL visible = bar.window && bar.topItem == item;
    BOOL animate = animated && visible;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CASpringAnimation *spring = animate && !reduceMotion ? ApolloScrollReturnSpring() : nil;
    if (self.returnItem) {
        if (visible) {
            [bar layoutIfNeeded];
            ApolloNavigationTitleActionsWillChange(bar);
        }
        // Keep the actual glass button on screen while removing its layout
        // reservation. The title can return at the same time as the arrow
        // slides out; UIKit must not tear down the arrow before it can animate.
        CGRect frame = button.superview ? [button.superview convertRect:button.frame toView:bar] : CGRectZero;
        CALayer *presentation = button.layer.presentationLayer;
        CGFloat opacity = presentation ? presentation.opacity : button.alpha;
        [button.layer removeAllAnimations];
        [button removeFromSuperview];
        NSMutableArray *leftItems = [item.leftBarButtonItems mutableCopy];
        [leftItems removeObjectIdenticalTo:self.returnItem];
        [UIView performWithoutAnimation:^{
            [item setLeftBarButtonItems:leftItems.count ? leftItems : nil animated:NO];
            item.leftItemsSupplementBackButton = self.supplementedBackButton;
            if (visible) [bar layoutIfNeeded];
        }];
        self.returnItem = nil;
        if (animate && button) {
            button.transform = CGAffineTransformIdentity;
            button.translatesAutoresizingMaskIntoConstraints = YES;
            button.frame = frame;
            button.alpha = opacity;
            button.userInteractionEnabled = NO;
            [bar addSubview:button];
            self.retiringButton = button;
            CGFloat direction = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft ? 1 : -1;
            __weak ApolloScrollReturn *weakSelf = self;
            [UIView animateWithDuration:reduceMotion ? 0.15 : spring.duration delay:0
                 usingSpringWithDamping:0.78 initialSpringVelocity:0
                                options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                button.alpha = 0;
                if (!reduceMotion) button.transform = CGAffineTransformMakeTranslation(direction * 18, 0);
            } completion:^(__unused BOOL finished) {
                [button removeFromSuperview];
                if (weakSelf.retiringButton == button) weakSelf.retiringButton = nil;
            }];
        }
        if (visible) ApolloNavigationTitleActionsDidChange(bar, spring);
    }
    self.button = nil;
}
// A one-shot UIKit animation can be cancelled by ASDK's asynchronous row
// measurement/content-offset preservation. Own the short jump frame by frame,
// recomputing the real top as the search/header inset changes. Afterwards only
// geometry changes re-anchor it; ordinary programmatic navigation is untouched.
- (void)stopTopJump {
    self.restoring = NO;
    self.jumpGeneration++;
    self.anchorUpdatePending = NO;
    [self.jumpLink invalidate];
    self.jumpLink = nil;
    if (self.observedScroll) {
        [self.observedScroll removeObserver:self forKeyPath:@"contentOffset" context:&kApolloScrollReturnGeometryContext];
        [self.observedScroll removeObserver:self forKeyPath:@"contentSize" context:&kApolloScrollReturnGeometryContext];
        [self.observedScroll removeObserver:self forKeyPath:@"adjustedContentInset" context:&kApolloScrollReturnGeometryContext];
        self.observedScroll = nil;
    }
}
- (BOOL)canContinueTopJump {
    UIScrollView *scroll = self.scrollView;
    return (self.hasPosition || self.restoring) && scroll.window && self.owner.view.window &&
        self.owner.navigationController.topViewController == self.owner &&
        !scroll.isTracking && !scroll.isDragging;
}
// Save the cell identity and the viewport's position within it, not a row
// number: insertions and asynchronous image measurement can move the row.
- (void)captureVisibleItem {
    self.itemLookupAttempted = NO;
    UITableView *table = [self.scrollView isKindOfClass:UITableView.class] ? (id)self.scrollView : nil;
    id tableNode = ApolloReturnObjectIvar(self.owner, "tableNode");
    SEL selector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!table || ![tableNode respondsToSelector:selector]) return;
    CGFloat y = self.savedOffset.y + self.savedTopInset;
    for (NSIndexPath *path in [table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]) {
        CGRect row = [table rectForRowAtIndexPath:path];
        if (CGRectGetMaxY(row) <= y) continue;
        self.savedNode = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, selector, path);
        self.savedItemID = ApolloReturnItemID(self.savedNode);
        self.savedRowOffset = y - row.origin.y;
        break;
    }
}
- (CGFloat)returnTargetY {
    UITableView *table = [self.scrollView isKindOfClass:UITableView.class] ? (id)self.scrollView : nil;
    id tableNode = ApolloReturnObjectIvar(self.owner, "tableNode");
    SEL lookup = NSSelectorFromString(@"indexPathForNode:");
    NSIndexPath *path = self.savedNode && [tableNode respondsToSelector:lookup]
        ? ((id (*)(id, SEL, id))objc_msgSend)(tableNode, lookup, self.savedNode) : nil;
    // A rebuilt node can still represent the same Reddit item.
    SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!path && self.savedItemID && !self.itemLookupAttempted && [tableNode respondsToSelector:nodeSelector]) {
        self.itemLookupAttempted = YES;
        for (NSInteger section = 0; section < table.numberOfSections && !path; section++) {
            for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
                NSIndexPath *candidate = [NSIndexPath indexPathForRow:row inSection:section];
                id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSelector, candidate);
                if ([ApolloReturnItemID(node) isEqualToString:self.savedItemID]) {
                    self.savedNode = node;
                    path = candidate;
                    break;
                }
            }
        }
    }
    CGFloat top = self.scrollView.adjustedContentInset.top;
    if (path && path.section < table.numberOfSections && path.row < [table numberOfRowsInSection:path.section]) {
        return [table rectForRowAtIndexPath:path].origin.y + self.savedRowOffset - top;
    }
    // Once an item was captured, its removal invalidates the destination.
    // Pixel fallback is only for screens where no row could be captured.
    if (self.savedNode || self.savedItemID) return NAN;
    return self.savedOffset.y + self.savedTopInset - top;
}
- (CGFloat)jumpTargetY {
    UIScrollView *scroll = self.scrollView;
    CGFloat top = -scroll.adjustedContentInset.top;
    if (!self.restoring) return top;
    CGFloat target = [self returnTargetY];
    if (!isfinite(target)) return target;
    return MAX(top, MIN(target, MAX(top,
        scroll.contentSize.height - scroll.bounds.size.height + scroll.adjustedContentInset.bottom)));
}
- (void)anchorAtTop {
    if (![self canContinueTopJump]) return;
    UIScrollView *scroll = self.scrollView;
    CGFloat top = [self jumpTargetY];
    if (!isfinite(top)) {
        [self clearAnimated:YES];
        return;
    }
    if (fabs(scroll.contentOffset.y - top) > 0.5) {
        scroll.contentOffset = CGPointMake(scroll.contentOffset.x, top);
        ApolloLog(@"[ScrollReturn] Re-anchored after feed geometry changed");
    }
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context != &kApolloScrollReturnGeometryContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if ([keyPath isEqualToString:@"contentOffset"]) {
        if (self.jumpLink || self.anchorUpdatePending ||
            fabs(self.scrollView.contentOffset.y + self.scrollView.adjustedContentInset.top) < 1) return;
        // A separate programmatic action (for example Next Comment) also
        // ends the top anchor. Wait one turn so a batch which publishes its
        // new contentSize AFTER its offset can still identify itself.
        NSUInteger generation = self.jumpGeneration;
        NSUInteger revision = self.geometryRevision;
        __weak ApolloScrollReturn *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloScrollReturn *state = weakSelf;
            if (state && state.jumpGeneration == generation && state.geometryRevision == revision &&
                !state.anchorUpdatePending && !state.jumpLink &&
                fabs(state.scrollView.contentOffset.y + state.scrollView.adjustedContentInset.top) >= 1) {
                [state stopTopJump];
            }
        });
        return;
    }
    self.geometryRevision++;
    // Batch row updates adjust the offset AFTER publishing contentSize.
    // Coalesce until the update unwinds, then correct the final viewport.
    if (self.jumpLink || self.anchorUpdatePending || !self.hasPosition) return;
    self.anchorUpdatePending = YES;
    NSUInteger generation = self.jumpGeneration;
    __weak ApolloScrollReturn *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloScrollReturn *state = weakSelf;
        if (!state || state.jumpGeneration != generation) return;
        state.anchorUpdatePending = NO;
        [state anchorAtTop];
    });
}
- (void)stepTopJump:(CADisplayLink *)link {
    if (![self canContinueTopJump]) {
        [self clearAnimated:YES];
        return;
    }
    if (self.jumpStartTime == 0) self.jumpStartTime = link.timestamp;
    CGFloat progress = MIN(1.0, MAX(0.0, (link.timestamp - self.jumpStartTime) / 0.45));
    CGFloat eased = 1.0 - pow(1.0 - progress, 3.0);
    UIScrollView *scroll = self.scrollView;
    CGFloat top = [self jumpTargetY];
    if (!isfinite(top)) {
        [self clearAnimated:YES];
        return;
    }
    scroll.contentOffset = CGPointMake(scroll.contentOffset.x,
        self.jumpFromY + (top - self.jumpFromY) * eased);
    if (progress >= 1) {
        if (self.restoring) {
            [self anchorAtTop];
            [self stopTopJump];
            self.savedNode = nil;
            self.savedItemID = nil;
            return;
        }
        [self.jumpLink invalidate];
        self.jumpLink = nil;
        [self anchorAtTop];
        ApolloTabBarRevealAfterScrollToTop(self.owner.tabBarController);
        ApolloLog(@"[ScrollReturn] Reached current feed top");
    }
}
- (void)startTopJump {
    [self stopTopJump];
    UIScrollView *scroll = self.scrollView;
    // Stop existing deceleration/scroll animation before installing our driver.
    [scroll setContentOffset:scroll.contentOffset animated:NO];
    self.observedScroll = scroll;
    [scroll addObserver:self forKeyPath:@"contentOffset" options:0 context:&kApolloScrollReturnGeometryContext];
    [scroll addObserver:self forKeyPath:@"contentSize" options:0 context:&kApolloScrollReturnGeometryContext];
    [scroll addObserver:self forKeyPath:@"adjustedContentInset" options:0 context:&kApolloScrollReturnGeometryContext];
    self.jumpFromY = scroll.contentOffset.y;
    self.jumpStartTime = 0;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [self anchorAtTop];
        ApolloTabBarRevealAfterScrollToTop(self.owner.tabBarController);
        return;
    }
    self.jumpLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(stepTopJump:)];
    [self.jumpLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)returnToPosition {
    UIScrollView *scroll = self.scrollView;
    if (!self.hasPosition || !scroll.window || !self.owner.view.window) return;
    if (!isfinite([self returnTargetY])) {
        [self clear];
        ApolloLog(@"[ScrollReturn] Saved item no longer exists; cancelled return");
        return;
    }
    id node = self.savedNode;
    NSString *itemID = self.savedItemID;
    [self clear];
    self.savedNode = node;
    self.savedItemID = itemID;
    // Use the same interruptible driver in both directions. Re-resolve the
    // saved row each frame as offscreen cells acquire their measured heights.
    self.restoring = YES;
    self.jumpFromY = scroll.contentOffset.y;
    self.jumpStartTime = 0;
    [scroll setContentOffset:scroll.contentOffset animated:NO];
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [self anchorAtTop];
        [self clearAnimated:NO];
    } else {
        self.jumpLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(stepTopJump:)];
        [self.jumpLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    ApolloLog(@"[ScrollReturn] Restored saved position");
}
- (void)dragged:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) [self clear];
}
- (void)navigationTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) [self returnToPosition];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    // The navigation-bar tap is part of the Return Button affordance.
    if (!sScrollReturnButton) return NO;
    if (!self.hasPosition || self.owner.navigationController.topViewController != self.owner) return NO;
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) return NO;
        if (view == gesture.view) break;
    }
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)showButton {
    if (!sScrollReturnButton || self.returnItem) return;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 44);
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:[UIImage systemImageNamed:@"arrow.uturn.down"] forState:UIControlStateNormal];
    [button setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium]
                            forImageInState:UIControlStateNormal];
    if (@available(iOS 26.0, *)) {
        if (IsLiquidGlass()) {
            // Match the back button's 44-point glass surface. A configured
            // glass button adds optical background insets inside its bounds,
            // making the bubble smaller even when the touch target is larger.
            UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            effect.interactive = YES;
            UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
            glass.frame = CGRectMake(0, 0, 44, 44);
            glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            glass.userInteractionEnabled = NO;
            glass.clipsToBounds = YES;
            glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
            // Effect foreground belongs inside contentView. UIButton may
            // reorder its internal image view underneath a custom effect.
            [button setImage:nil forState:UIControlStateNormal];
            UIImage *symbol = [UIImage systemImageNamed:@"arrow.uturn.down"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium]];
            UIImageView *arrow = [[UIImageView alloc] initWithImage:symbol];
            arrow.translatesAutoresizingMaskIntoConstraints = NO;
            arrow.tintColor = UIColor.labelColor;
            arrow.isAccessibilityElement = NO;
            [glass.contentView addSubview:arrow];
            [NSLayoutConstraint activateConstraints:@[
                [arrow.centerXAnchor constraintEqualToAnchor:glass.contentView.centerXAnchor],
                [arrow.centerYAnchor constraintEqualToAnchor:glass.contentView.centerYAnchor]
            ]];
            [button addSubview:glass];
        } else {
            button.backgroundColor = UIColor.secondarySystemBackgroundColor;
        }
    } else {
        button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    }
    button.tintColor = UIColor.labelColor;
    button.layer.cornerRadius = 22;
    button.accessibilityIdentifier = @"apollo.scrollReturn";
    button.accessibilityLabel = @"Return to your spot";
    button.alpha = 0;
    [button addTarget:self action:@selector(returnToPosition) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:44],
        [button.heightAnchor constraintEqualToConstant:44]
    ]];
    self.button = button;
    UINavigationItem *item = self.owner.navigationItem;
    self.supplementedBackButton = item.leftItemsSupplementBackButton;
    self.returnItem = [[UIBarButtonItem alloc] initWithCustomView:button];
    // The custom button already supplies glass. Suppress the bar's additional
    // shared background while letting UIKit place it beside the native back.
    SEL hideBackground = NSSelectorFromString(@"setHidesSharedBackground:");
    if ([self.returnItem respondsToSelector:hideBackground]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.returnItem, hideBackground, YES);
    }
    UINavigationBar *bar = self.owner.navigationController.navigationBar;
    [bar layoutIfNeeded];
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CASpringAnimation *spring = reduceMotion ? nil : ApolloScrollReturnSpring();
    ApolloNavigationTitleActionsWillChange(bar);
    // Enter from beside the back button while UIKit reallocates the leading
    // item space. Animate the navigation bar's own layout so a long title
    // shifts/compresses with the insertion instead of jumping or overlapping.
    CGFloat direction = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft ? 1 : -1;
    button.transform = reduceMotion ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(direction * 18, 0);
    NSMutableArray *leftItems = [item.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
    // Existing leading items may already implement a custom back button.
    // Supplement the system back only when this is the first leading item.
    if (leftItems.count == 0) item.leftItemsSupplementBackButton = YES;
    [leftItems addObject:self.returnItem];
    [UIView performWithoutAnimation:^{
        [item setLeftBarButtonItems:leftItems animated:NO];
        [bar layoutIfNeeded];
    }];
    [UIView animateWithDuration:reduceMotion ? 0.15 : spring.duration delay:0
         usingSpringWithDamping:0.78 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        button.alpha = 1;
        button.transform = CGAffineTransformIdentity;
    } completion:nil];
    ApolloNavigationTitleActionsDidChange(bar, spring);
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTopJump];
    [self.retiringButton removeFromSuperview];
    [self.scrollView.panGestureRecognizer removeTarget:self action:@selector(dragged:)];
    [self.navigationTap.view removeGestureRecognizer:self.navigationTap];
}
@end

static UIScrollView *ApolloScrollReturnTable(id owner) {
    Ivar ivar = class_getInstanceVariable([owner class], "tableNode");
    id node = ivar ? object_getIvar(owner, ivar) : nil;
    SEL viewSelector = @selector(view);
    id view = [node respondsToSelector:viewSelector] ? ((id (*)(id, SEL))objc_msgSend)(node, viewSelector) : nil;
    return [view isKindOfClass:UIScrollView.class] ? view : nil;
}

// Every live state, weakly, so the Return Button setting turning off can drop
// the arrow from screens that are not in front right now (a feed behind the
// settings stack keeps its saved position and its button until this runs).
static NSHashTable<ApolloScrollReturn *> *sApolloScrollReturnStates;

void ApolloScrollReturnButtonSettingChanged(void) {
    if (!NSThread.isMainThread || sScrollReturnButton) return;
    for (ApolloScrollReturn *state in sApolloScrollReturnStates.allObjects) {
        [state retireButtonAnimated:YES];
    }
    ApolloLog(@"[ScrollReturn] Return Button off: retired %lu live button(s)",
              (unsigned long)sApolloScrollReturnStates.count);
}

static ApolloScrollReturn *ApolloScrollReturnState(UIViewController *owner) {
    ApolloScrollReturn *state = objc_getAssociatedObject(owner, &kApolloScrollReturn);
    if (!state) {
        state = [ApolloScrollReturn new];
        state.owner = owner;
        objc_setAssociatedObject(owner, &kApolloScrollReturn, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sApolloScrollReturnStates) sApolloScrollReturnStates = [NSHashTable weakObjectsHashTable];
        [sApolloScrollReturnStates addObject:state];
    }
    UIScrollView *scroll = ApolloScrollReturnTable(owner);
    if (state.scrollView != scroll) {
        [state.scrollView.panGestureRecognizer removeTarget:state action:@selector(dragged:)];
        [state clearAnimated:NO];
        state.scrollView = scroll;
        [scroll.panGestureRecognizer addTarget:state action:@selector(dragged:)];
    }
    UINavigationBar *bar = owner.navigationController.navigationBar;
    if (state.navigationTap.view != bar) {
        [state.navigationTap.view removeGestureRecognizer:state.navigationTap];
        state.navigationTap = [[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(navigationTapped:)];
        state.navigationTap.delegate = state;
        state.navigationTap.cancelsTouchesInView = NO;
        [bar addGestureRecognizer:state.navigationTap];
    }
    return state;
}

%hook ApolloScrollReturnTableController
- (void)textFieldEditingChangedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
- (BOOL)textFieldShouldReturn:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    return %orig;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloScrollReturn *state = ApolloScrollReturnState((UIViewController *)self);
    Ivar ivar = class_getInstanceVariable([self class], "interceptingScrollView");
    UIScrollView *proxy = ivar ? object_getIvar(self, ivar) : nil;
    if ([proxy isKindOfClass:UIScrollView.class]) {
        // UIKit refuses status-bar scrolling when two visible scroll views
        // opt in. Apollo's real table and its full-screen proxy both did.
        state.scrollView.scrollsToTop = NO;
        proxy.scrollsToTop = YES;
        proxy.delegate = (id<UIScrollViewDelegate>)self;
    }
}
- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)sender {
    UIViewController *owner = (UIViewController *)self;
    ApolloScrollReturn *state = ApolloScrollReturnState(owner);
    UIScrollView *scroll = state.scrollView;
    if (!scroll || !owner.view.window || owner.navigationController.topViewController != owner) return %orig;
    // Capture the old viewport before revealing legacy UIKit chrome, whose
    // inset changes. The modern hide-header path is presentation-only.
    CGPoint previousOffset = scroll.contentOffset;
    CGFloat previousInset = scroll.adjustedContentInset.top;
    UINavigationController *navigation = owner.navigationController;
    ApolloTopBarSetScrollToTopActive(navigation, YES);
    if (navigation.navigationBarHidden) {
        [navigation setNavigationBarHidden:NO animated:!UIAccessibilityIsReduceMotionEnabled()];
    }
    // A second top tap is an undo, including while the first animation runs.
    if (state.hasPosition) {
        [state returnToPosition];
        return NO;
    }
    if (previousOffset.y <= -previousInset + 1) {
        ApolloTabBarRevealAfterScrollToTop(owner.tabBarController);
        ApolloTopBarSetScrollToTopActive(navigation, NO);
        return NO;
    }
    state.savedOffset = previousOffset;
    state.savedTopInset = previousInset;
    state.hasPosition = YES;
    [state captureVisibleItem];
    [state startTopJump];
    [state showButton];
    ApolloLog(@"[ScrollReturn] Saved position and scrolled to top");
    return NO;
}
- (void)viewWillDisappear:(BOOL)animated {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:NO];
    %orig;
}
%end

// The title dropdown reuses the same PostsViewController, so switching its
// feed never calls viewWillDisappear. Clear before the selection loads rows:
// the old top anchor and saved offset belong only to the previous feed.
%hook ApolloScrollReturnPostsController
- (void)refreshControlActivatedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
- (void)sortBarButtonItemTappedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}

- (void)redditAccountChangedWithNotification:(id)notification {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
- (void)reloadPostsWithNotification:(id)notification {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    Ivar ivar = class_getInstanceVariable([self class], "dropDownTableView");
    UITableView *dropdown = ivar ? object_getIvar(self, ivar) : nil;
    if (dropdown && tableView == dropdown) {
        [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
        ApolloLog(@"[ScrollReturn] Cleared position for title feed selection");
    }
    %orig;
}
%end

%hook ApolloScrollReturnCommentsController

- (void)refreshControlActivatedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
- (void)sortBarButtonItemTappedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
%end

%hook ApolloScrollReturnUserCommentsController
- (void)refreshControlActivatedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
- (void)sortBarButtonItemTappedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
%end
%hook ApolloScrollReturnSavedController
- (void)refreshControlActivatedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
%end
%hook ApolloScrollReturnSubredditCommentsController
- (void)refreshControlActivatedWithSender:(id)sender {
    [objc_getAssociatedObject(self, &kApolloScrollReturn) clearAnimated:YES];
    %orig;
}
%end

// The Posts tab's native re-selection dispatch recognizes only a few controller
// classes. Handle the navigation stack once, including profiles, trophies,
// multireddits, comment lists, and tweak-owned lists. This is independent of
// status-bar taps, whose second tap deliberately restores the saved position.
static UIScrollView *ApolloPostsTabContentScrollView(UIView *view, CGRect viewport) {
    if (view.hidden || view.alpha < 0.01 || !view.window) return nil;
    CGRect visible = CGRectIntersection([view convertRect:view.bounds toView:nil], viewport);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return nil;
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view;
        // Ignore Apollo's empty status-bar proxy and horizontal media carousels.
        // Stop at the outer content list so an embedded post cannot win over it.
        BOOL list = [scroll isKindOfClass:UITableView.class] ||
                    [scroll isKindOfClass:UICollectionView.class];
        BOOL vertical = scroll.contentSize.height + scroll.adjustedContentInset.top +
                        scroll.adjustedContentInset.bottom > scroll.bounds.size.height + 1;
        if (scroll.scrollEnabled && (vertical || (list && scroll.alwaysBounceVertical))) return scroll;
    }
    UIScrollView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *child in view.subviews) {
        UIScrollView *candidate = ApolloPostsTabContentScrollView(child, viewport);
        if (!candidate) continue;
        CGRect frame = CGRectIntersection([candidate convertRect:candidate.bounds toView:nil], viewport);
        CGFloat area = frame.size.width * frame.size.height;
        if (area > bestArea) {
            best = candidate;
            bestArea = area;
        }
    }
    return best;
}

%hook ApolloPostsTabSceneDelegate
- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {
    if (tabBarController.selectedIndex != 0 ||
        viewController != tabBarController.selectedViewController ||
        ![viewController isKindOfClass:UINavigationController.class]) {
        return %orig(tabBarController, viewController);
    }
    UINavigationController *nav = (UINavigationController *)viewController;
    UIViewController *owner = nav.topViewController;
    // Do not navigate behind a modal or interrupt an interactive push/pop.
    if (nav.presentedViewController || tabBarController.presentedViewController || nav.transitionCoordinator) return NO;
    UIView *content = owner.viewIfLoaded;
    if (!content.window) return NO;
    // Texture's real table is authoritative even when empty or short. Do not
    // use scrollsToTop: the status-bar implementation intentionally disables it.
    UIScrollView *scroll = ApolloScrollReturnTable(owner);
    if (!scroll.window || scroll.hidden) {
        scroll = ApolloPostsTabContentScrollView(content, [content convertRect:content.bounds toView:nil]);
    }
    CGFloat top = -scroll.adjustedContentInset.top;
    if (scroll && scroll.contentOffset.y > top + 1) {
        // A tab tap must never enter the status-bar undo path.
        [objc_getAssociatedObject(owner, &kApolloScrollReturn) clearAnimated:NO];
        [scroll setContentOffset:CGPointMake(scroll.contentOffset.x, top)
                       animated:!UIAccessibilityIsReduceMotionEnabled()];
        ApolloLog(@"[PostsTab] Scrolled %@ to top", NSStringFromClass(owner.class));
    } else if (nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
        ApolloLog(@"[PostsTab] Returned one page from %@", NSStringFromClass(owner.class));
    }
    // Returning NO also prevents UIKit/Apollo from popping again after our scroll.
    return NO;
}
%end

%ctor {
    %init(ApolloPostsTabSceneDelegate = objc_getClass("_TtC6Apollo13SceneDelegate"),
          ApolloScrollReturnTableController = objc_getClass("_TtC6Apollo21ASTableViewController"),
          ApolloScrollReturnPostsController = objc_getClass("_TtC6Apollo19PostsViewController"),
          ApolloScrollReturnCommentsController = objc_getClass("_TtC6Apollo22CommentsViewController"),
          ApolloScrollReturnUserCommentsController = objc_getClass("_TtC6Apollo26UserCommentsViewController"),
          ApolloScrollReturnSavedController = objc_getClass("_TtC6Apollo32SavedPostsCommentsViewController"),
          ApolloScrollReturnSubredditCommentsController = objc_getClass("_TtC6Apollo34AllSubredditCommentsViewController"));
    ApolloLog(@"[ScrollReturn] Scroll-to-top hook installed");
}
