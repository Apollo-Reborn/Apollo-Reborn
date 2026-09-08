// ApolloFindInComments.xm
//
// Two improvements to Apollo's native "Find in Comments" (the keyboard-docked
// in-thread search bar: searchTextField + "n/m" searchIndexInfoLabel + prev/next
// chevrons on ASTableViewController, logic in CommentsViewController).
//
// 1) Scroll-into-view watchdog (#946)
//
//    Native flow (RE, Apollo 1.15.11): a query edit rebuilds the match list
//    (CommentsSearchMatch = { NSRange in the node's text, weak ASTextNode,
//    optional row IndexPath }) and selects match 0; the chevrons move the
//    wrapping current index. Selecting a match (sub_10070cf14) computes the
//    match's rect via -[ASTextNode frameForTextRange:] plus the node's origin
//    in table space, checks CGRectContainsRect against the visible rect
//    (table bounds inset by adjustedContentInset), and if the match is outside
//    it fires ONE animated setContentOffset: to a clamped target. There is no
//    follow-up: the target is computed from the geometry at tap time. Rows
//    that re-measure right after (inline images / avatars / previews loading)
//    shift the content under the animation, and an in-flight table update can
//    kill the animation outright — the match lands "a few comments below the
//    window" (issue #946, ~3/10 taps right after opening a thread). Same
//    stale-target family as the isolated-thread landing bug fixed in
//    ApolloInboxCommentScroll.xm.
//
//    Fix: capture the current match while Apollo selects it — every selection
//    path (query edit, next, prev) funnels through the visibility check's
//    -frameForTextRange: call on the match's text node, so a hook on that
//    method inside a narrow reentrancy window records exactly the node+range
//    Apollo itself used. Then, after the native scroll has had time to land
//    (and again after row heights settle), re-derive the match rect from the
//    live geometry (cell node -> indexPathForNode -> rectForRowAtIndexPath)
//    and, if the match is not comfortably inside the visible rect, issue a
//    minimal corrective scroll. Never fights the user: any tracking/dragging/
//    decelerating cancels the pending passes for that selection.
//
// 2) Multi-term search: "word1, word2" finds matches of EITHER word
//
//    The native matcher walks every text node (post body, authors, subreddit,
//    comment bodies) calling
//        [haystack rangeOfString:query options:NSCaseInsensitiveSearch range:remaining]
//    in a loop, appending one CommentsSearchMatch per hit and advancing past
//    it. A comma query like "Leao, why, socks" is searched literally today and
//    finds nothing (0/0). We split the query on commas and, only while the
//    native rebuild is executing with a comma query, answer that exact
//    rangeOfString call with the EARLIEST match of ANY term. The native loop
//    then advances past it and asks again — enumerating every match of every
//    term in document order through Apollo's own pipeline, so the match list,
//    the "n/m" label, the highlight overlays, wrap-around and the scrolling
//    all keep working natively.
//
// Diagnostics: `log show --predicate 'subsystem == "apollofix"'`, lines tagged
// [FindInComments].

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ipad/ApolloPaneLayout.h"

// MARK: - minimal local Texture declarations
//
// Per-file copies on purpose (see ApolloTextureDecls.h's note): only what this
// file touches, resolved at runtime against Apollo's bundled AsyncDisplayKit.

@interface ASDisplayNode : NSObject
@property (nonatomic, readonly, weak) ASDisplayNode *supernode;
@property (nonatomic, readonly) BOOL isNodeLoaded;
- (CGRect)convertRect:(CGRect)rect toNode:(ASDisplayNode *)node;
@end

@interface ASTextNode : ASDisplayNode
- (CGRect)frameForTextRange:(NSRange)range;
- (void)setNeedsDisplay;
@end

@interface ASCellNode : ASDisplayNode
@end

@interface ASTableNode : ASDisplayNode
- (UITableView *)view;
- (NSIndexPath *)indexPathForNode:(ASCellNode *)cellNode;
@end

// MARK: - tunables

static const NSTimeInterval kFICVerifyDelay1 = 0.45;  // after the native animated scroll (~0.25s) lands
static const NSTimeInterval kFICVerifyDelay2 = 0.60;  // between subsequent passes (row heights settling)
static const int kFICMaxPasses = 4;                   // per selection: verify/correct at most this many times
                                                      // (a corrective animation can itself be killed by an
                                                      // in-flight row update — seen live — so leave headroom)
static const CGFloat kFICEdgePadding = 12.0;          // keep the match this clear of the visible edges
static const CGFloat kFICContainSlack = 2.0;          // treat within-this-of-visible as "in view"
static const CGFloat kFICMinCorrection = 2.0;         // skip corrections smaller than this

// MARK: - state
//
// Each controller owns its asynchronous verification. A second window or a
// disappearing thread must never cancel another controller's active search.
@interface ApolloCommentsFindSession : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) ASTextNode *matchNode;
@property (nonatomic) NSRange matchRange;
@property (nonatomic) NSUInteger generation;
@end
@implementation ApolloCommentsFindSession
- (void)sceneDeactivated:(NSNotification *)notification {
    if (notification.object != self.controller.viewIfLoaded.window.windowScene) return;
    self.generation++;
    self.matchNode = nil;
    self.matchRange = NSMakeRange(NSNotFound, 0);
}
@end

static char kFICSessionKey;
// Only the synchronous native matcher uses a process-local scope. Save/restore
// it across reentrancy; asynchronous work never consults this pointer.
static ApolloCommentsFindSession *sFICCaptureSession;

static ApolloCommentsFindSession *FICSession(UIViewController *controller) {
    ApolloCommentsFindSession *session = objc_getAssociatedObject(controller, &kFICSessionKey);
    if (!session) {
        session = [ApolloCommentsFindSession new];
        session.controller = controller;
        [NSNotificationCenter.defaultCenter addObserver:session selector:@selector(sceneDeactivated:) name:UISceneWillDeactivateNotification object:nil];
        session.matchRange = NSMakeRange(NSNotFound, 0);
        objc_setAssociatedObject(controller, &kFICSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return session;
}

static void FICCancel(UIViewController *controller) {
    ApolloCommentsFindSession *session = objc_getAssociatedObject(controller, &kFICSessionKey);
    session.generation++;
    session.matchNode = nil;
    session.matchRange = NSMakeRange(NSNotFound, 0);
}

// Multi-term (comma) search: armed only for the synchronous native rebuild.
static BOOL sFICMultiActive = NO;
static NSArray<NSString *> *sFICMultiTerms = nil; // trimmed, non-empty terms from a comma query
static NSString *sFICMultiQuery = nil;            // full query the native code will pass as the needle

// MARK: - helpers

static ptrdiff_t FICIvarOffset(id obj, const char *name) {
    if (!obj) return -1;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? ivar_getOffset(iv) : -1;
}

static id FICObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

// The comments search state Swift struct stored inline in ASTableViewController:
// { Int currentIndex; [CommentsSearchMatch] matches } — matches' storage pointer
// is NULL when no search is active (verified against sub_1002bbe18, which
// renders the "index+1/count" label from these exact two words).
static BOOL FICSearchIsActive(id vc) {
    ptrdiff_t off = FICIvarOffset(vc, "commentsSearch");
    if (off < 0) return NO;
    uintptr_t matches = *(uintptr_t *)((char *)(__bridge void *)vc + off + sizeof(intptr_t));
    return matches != 0;
}

// Comments in-thread search shares ASTableViewController with the feed search
// bar; searchBarShouldStickToKeyboard is what the app itself uses to tell them
// apart (YES == the comments find bar).
static BOOL FICIsCommentsSearchVC(id vc) {
    ptrdiff_t off = FICIvarOffset(vc, "searchBarShouldStickToKeyboard");
    if (off < 0) return NO;
    return *((char *)(__bridge void *)vc + off) != 0;
}

// Split "a, b, c" into trimmed non-empty terms. Only comma queries qualify;
// without one the native literal search runs untouched. A comma query with a
// single term ("linux," mid-typing) still searches that term, so the match
// count stays live between typing the comma and the next word.
static NSArray<NSString *> *FICParseMultiTerms(NSString *query) {
    if (!query || [query rangeOfString:@","].location == NSNotFound) return nil;
    NSMutableArray<NSString *> *terms = [NSMutableArray array];
    for (NSString *piece in [query componentsSeparatedByString:@","]) {
        NSString *term = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (term.length) [terms addObject:term];
    }
    return terms.count >= 1 ? terms : nil;
}

// MARK: - verification / correction

static void FICScheduleVerifyPass(ApolloCommentsFindSession *session, NSUInteger gen, int passesLeft, NSTimeInterval delay);

// One verification pass: recompute where the current match actually sits now
// and nudge it into view if the native scroll left it outside. Returns YES if
// a follow-up pass is worth scheduling (we corrected, or geometry wasn't ready).
static BOOL FICVerifyOnce(ApolloCommentsFindSession *session, NSUInteger gen) {
    if (!session || gen != session.generation) return NO;

    UIViewController *vc = session.controller;
    ASTextNode *node = session.matchNode;
    if (!vc || !node || !vc.viewLoaded) return NO;
    if (session.matchRange.location == NSNotFound) return NO;
    if (!FICSearchIsActive(vc)) return NO;   // bar dismissed / query cleared

    ASTableNode *tableNode = FICObjectIvar(vc, "tableNode");
    UITableView *tableView = [tableNode isNodeLoaded] ? [tableNode view] : nil;
    if (!tableView || !tableView.window) return NO;
    if (@available(iOS 13.0, *)) {
        if (tableView.window.windowScene.activationState != UISceneActivationStateForegroundActive) return NO;
    }

    // Highlight repaint: when the selected match's node was far off-screen,
    // its first display (kicked off while the animated scroll approached) can
    // race the rendering-block install and come out with NO highlight drawn —
    // reproduced reliably by wrapping from match 1 to the last match. Apollo's
    // highlight block stays attached to the node, so one redisplay after the
    // dust settles paints the missing highlight; a no-op when it already drew.
    if ([node isNodeLoaded]) {
        [node setNeedsDisplay];
    }

    // The user took over — never fight a live touch or its deceleration.
    if (tableView.isTracking || tableView.isDragging || tableView.isDecelerating) {
        ApolloLog(@"[FindInComments] verify: user is scrolling, standing down");
        return NO;
    }

    // Locate the match's row from live geometry: text node -> owning cell node
    // -> index path -> row rect (all current, unlike the native one-shot math).
    ASDisplayNode *cellNode = node;
    Class cellClass = objc_getClass("ASCellNode");
    while (cellNode && ![cellNode isKindOfClass:cellClass]) cellNode = cellNode.supernode;
    if (!cellNode) return NO;
    NSIndexPath *indexPath = [tableNode indexPathForNode:(ASCellNode *)cellNode];
    if (!indexPath || indexPath.section >= tableView.numberOfSections ||
        indexPath.row >= [tableView numberOfRowsInSection:indexPath.section]) return NO;               // row got recycled/reloaded from under the search
    CGRect rowRect = [tableView rectForRowAtIndexPath:indexPath];

    // Match rect inside the row; falls back to the whole row while the text
    // node still has no calculated layout (frameForTextRange comes back empty).
    CGRect matchRect = rowRect;
    BOOL usedRowFallback = YES;
    CGRect textRect = [node frameForTextRange:session.matchRange];
    if (!CGRectIsEmpty(textRect)) {
        CGRect inCell = [node convertRect:textRect toNode:cellNode];
        if (!CGRectIsEmpty(inCell) && !isnan(inCell.origin.y)) {
            matchRect = CGRectOffset(inCell, rowRect.origin.x, rowRect.origin.y);
            usedRowFallback = NO;
        }
    }

    // Visible content rect the way the native check builds it: the table's
    // bounds (origin == contentOffset) inset by adjustedContentInset (nav
    // overlay + keyboard + tab bar).
    CGRect visible = UIEdgeInsetsInsetRect(tableView.bounds, tableView.adjustedContentInset);

    // The docked find bar (ApolloSearchToolbar, reparented off the scroll view
    // while active) floats over the table WITHOUT contributing to the insets,
    // so "visible" would otherwise extend behind its translucent glass. Trim
    // the bottom to the bar's top edge so corrections keep the match clear of it.
    UIView *barAncestor = [FICObjectIvar(vc, "searchTextField") superview];
    while (barAncestor && !strstr(object_getClassName(barAncestor), "SearchToolbar")) {
        barAncestor = barAncestor.superview;
    }
    if (barAncestor && barAncestor.window && barAncestor.superview &&
        ![barAncestor.superview isKindOfClass:[UIScrollView class]]) {
        CGRect barInTable = [barAncestor.superview convertRect:barAncestor.frame toView:tableView];
        if (CGRectGetMinY(barInTable) < CGRectGetMaxY(visible)) {
            visible.size.height = MAX(0, CGRectGetMinY(barInTable) - CGRectGetMinY(visible));
        }
    }
    if (CGRectGetHeight(visible) <= 0) return NO;

    BOOL inView = CGRectGetMinY(matchRect) >= CGRectGetMinY(visible) - kFICContainSlack &&
                  CGRectGetMaxY(matchRect) <= CGRectGetMaxY(visible) + kFICContainSlack;
    if (inView && !usedRowFallback) {
        ApolloLog(@"[FindInComments] verify: match row %ld in view (y=%.0f..%.0f vis=%.0f..%.0f)",
                  (long)indexPath.row, CGRectGetMinY(matchRect), CGRectGetMaxY(matchRect),
                  CGRectGetMinY(visible), CGRectGetMaxY(visible));
        return NO;
    }
    if (inView) return YES;                  // row visible but text not measured yet — check again

    // Minimal corrective scroll with a small margin, clamped like the native one.
    CGFloat deltaY = 0;
    if (CGRectGetHeight(matchRect) >= CGRectGetHeight(visible) - 2 * kFICEdgePadding) {
        deltaY = CGRectGetMinY(matchRect) - (CGRectGetMinY(visible) + kFICEdgePadding);
    } else if (CGRectGetMaxY(matchRect) > CGRectGetMaxY(visible) - kFICEdgePadding) {
        deltaY = CGRectGetMaxY(matchRect) - (CGRectGetMaxY(visible) - kFICEdgePadding);
    } else if (CGRectGetMinY(matchRect) < CGRectGetMinY(visible) + kFICEdgePadding) {
        deltaY = CGRectGetMinY(matchRect) - (CGRectGetMinY(visible) + kFICEdgePadding);
    }

    UIEdgeInsets adj = tableView.adjustedContentInset;
    CGFloat minOffsetY = -adj.top;
    CGFloat maxOffsetY = MAX(minOffsetY, tableView.contentSize.height - tableView.bounds.size.height + adj.bottom);
    CGFloat targetY = MIN(MAX(tableView.contentOffset.y + deltaY, minOffsetY), maxOffsetY);

    if (fabs(targetY - tableView.contentOffset.y) < kFICMinCorrection) return usedRowFallback;

    ApolloLog(@"[FindInComments] verify: match row %ld OUT of view (match y=%.0f..%.0f vis=%.0f..%.0f%@) — correcting offset %.0f -> %.0f",
              (long)indexPath.row, CGRectGetMinY(matchRect), CGRectGetMaxY(matchRect),
              CGRectGetMinY(visible), CGRectGetMaxY(visible),
              usedRowFallback ? @", row fallback" : @"",
              tableView.contentOffset.y, targetY);
    [tableView setContentOffset:CGPointMake(tableView.contentOffset.x, targetY) animated:!UIAccessibilityIsReduceMotionEnabled()];
    return YES;
}

static void FICScheduleVerifyPass(ApolloCommentsFindSession *session, NSUInteger gen, int passesLeft, NSTimeInterval delay) {
    if (passesLeft <= 0) return;
    __weak ApolloCommentsFindSession *weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloCommentsFindSession *session = weakSession;
        if (!session || gen != session.generation) return;
        if (FICVerifyOnce(session, gen)) {
            FICScheduleVerifyPass(session, gen, passesLeft - 1, kFICVerifyDelay2);
        }
    });
}

// Arms capture + verification around one native selection call. The selector
// runs synchronously: the match list is (re)built if needed and the current
// match's frameForTextRange: fires inside, giving us the node + range.
static void FICRunSelection(UIViewController *controller, dispatch_block_t orig) {
    ApolloCommentsFindSession *session = FICSession(controller);
    NSUInteger gen = ++session.generation;
    session.matchNode = nil;
    session.matchRange = NSMakeRange(NSNotFound, 0);
    ApolloCommentsFindSession *previous = sFICCaptureSession;
    sFICCaptureSession = session;
    @try {
        orig();
    } @finally {
        sFICCaptureSession = previous;
    }
    if (session.matchNode && session.matchRange.location != NSNotFound) {
        FICScheduleVerifyPass(session, gen, kFICMaxPasses, kFICVerifyDelay1);
    }
}

// MARK: - hooks: capture the current match

// Apollo's selection routine asks the current match's text node for the match
// rect via frameForTextRange: (the visibility check). Inside our window, on the
// main thread, the LAST such call is exactly that check — highlight redraw
// blocks run on display queues and the synchronous pre-display pass happens
// earlier in the routine, so last-write-wins records the right node + range.
%hook ASTextNode
- (CGRect)frameForTextRange:(NSRange)range {
    if ([NSThread isMainThread] && sFICCaptureSession) {
        sFICCaptureSession.matchNode = (ASTextNode *)self;
        sFICCaptureSession.matchRange = range;
    }
    return %orig;
}
%end

%hook ASTextNode2
- (CGRect)frameForTextRange:(NSRange)range {
    if ([NSThread isMainThread] && sFICCaptureSession) {
        sFICCaptureSession.matchNode = (ASTextNode *)self;
        sFICCaptureSession.matchRange = range;
    }
    return %orig;
}
%end

// MARK: - hooks: multi-term matching

// Only answers the exact rangeOfString: call the native match rebuild makes
// (armed flag + main thread + the needle is the active comma query), so the
// hot path everywhere else is a single static-BOOL test.
%hook NSString
- (NSRange)rangeOfString:(NSString *)needle options:(NSStringCompareOptions)options range:(NSRange)searchRange {
    if (sFICMultiActive && needle && [NSThread isMainThread] &&
        [needle compare:sFICMultiQuery options:NSCaseInsensitiveSearch] == NSOrderedSame) {
        // Earliest match of ANY term; on a tied start the longer term wins so
        // "cat, cats" highlights the whole word. The native loop advances past
        // whatever we return and asks again — all terms, in document order.
        NSRange best = NSMakeRange(NSNotFound, 0);
        for (NSString *term in sFICMultiTerms) {
            NSRange r = %orig(term, options, searchRange);
            if (r.location == NSNotFound) continue;
            if (best.location == NSNotFound || r.location < best.location ||
                (r.location == best.location && r.length > best.length)) {
                best = r;
            }
        }
        return best;
    }
    return %orig;
}
%end

// UIKit owns one find panel; Apollo still owns matching and decoration.
// The hidden native field is only the input adapter, never a second responder.
API_AVAILABLE(ios(16.0))
@interface ApolloPaneFindAdapter : UIFindSession <UIFindInteractionDelegate>
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, strong) UIFindInteraction *interaction;
@property (nonatomic) BOOL previousSearching;
@property (nonatomic) BOOL previousToolbarHidden;
@end

static char kPaneFindAdapter;
static char kPaneFindToolbarBand;

API_AVAILABLE(ios(16.0))
@implementation ApolloPaneFindAdapter
- (UITextField *)nativeField { return FICObjectIvar(self.controller, "searchTextField"); }
- (NSArray<NSNumber *> *)nativeCounts {
    UILabel *label = FICObjectIvar(self.controller, "searchIndexInfoLabel");
    NSArray *parts = [label.text componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet];
    NSMutableArray *counts = [NSMutableArray array];
    for (NSString *part in parts) if (part.length) [counts addObject:@(part.integerValue)];
    return counts;
}
- (NSInteger)resultCount {
    NSArray *counts = self.nativeCounts;
    return counts.count == 2 ? [counts[1] integerValue] : 0;
}
- (NSInteger)highlightedResultIndex {
    NSArray *counts = self.nativeCounts;
    return counts.count == 2 && [counts[0] integerValue] > 0 ? [counts[0] integerValue] - 1 : NSNotFound;
}
- (BOOL)supportsReplacement { return NO; }
- (void)performSearchWithQuery:(NSString *)query options:(UITextSearchOptions *)options {
    (void)options; // unsupported match modes are omitted from the options menu.
    UITextField *field = self.nativeField;
    if (!field || !self.controller) return;
    field.text = query;
    ((void (*)(id, SEL, id))objc_msgSend)(self.controller,
        NSSelectorFromString(@"textFieldEditingChangedWithSender:"), field);
    [self.interaction updateResultCount];
}
- (void)highlightNextResultInDirection:(UITextStorageDirection)direction {
    SEL selector = NSSelectorFromString(direction == UITextStorageDirectionForward
        ? @"nextResultButtonTappedWithSender:" : @"previousResultButtonTappedWithSender:");
    if ([self.controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.controller, selector, self.nativeField);
        [self.interaction updateResultCount];
    }
}
- (UIFindSession *)findInteraction:(UIFindInteraction *)interaction sessionForView:(UIView *)view {
    return self.nativeField ? self : nil;
}
- (void)findInteraction:(UIFindInteraction *)interaction didBeginFindSession:(UIFindSession *)session {
    ptrdiff_t offset = FICIvarOffset(self.controller, "isSearching");
    if (offset >= 0) {
        uint8_t *flag = (uint8_t *)(__bridge void *)self.controller + offset;
        self.previousSearching = *flag != 0;
        *flag = 1;
    }
    UIView *toolbar = FICObjectIvar(self.controller, "upperToolbar");
    self.previousToolbarHidden = toolbar.hidden;
    toolbar.hidden = YES;
}
- (void)findInteraction:(UIFindInteraction *)interaction didEndFindSession:(UIFindSession *)session {
    [self performSearchWithQuery:@"" options:nil];
    FICCancel(self.controller);
    ptrdiff_t offset = FICIvarOffset(self.controller, "isSearching");
    if (offset >= 0) *((uint8_t *)(__bridge void *)self.controller + offset) = self.previousSearching;
    UIView *toolbar = FICObjectIvar(self.controller, "upperToolbar");
    toolbar.hidden = self.previousToolbarHidden;
}
@end

extern "C" BOOL ApolloPanePrepareCommentsFind(UIViewController *controller) {
    if (!ApolloPaneSplitControllerFor(controller) || !FICIsCommentsSearchVC(controller)) return NO;
    if (@available(iOS 16.0, *)) {
        if (!FICObjectIvar(controller, "searchTextField")) return NO;
        ApolloPaneFindAdapter *adapter = objc_getAssociatedObject(controller, &kPaneFindAdapter);
        if (!adapter) {
            adapter = [ApolloPaneFindAdapter new];
            adapter.controller = controller;
            adapter.interaction = [[UIFindInteraction alloc] initWithSessionDelegate:adapter];
            adapter.interaction.optionsMenuProvider = ^UIMenu *(NSArray<UIMenuElement *> *options) {
                return [UIMenu menuWithTitle:@"" children:@[]];
            };
            [controller.view addInteraction:adapter.interaction];
            objc_setAssociatedObject(controller, &kPaneFindAdapter, adapter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *toolbar = FICObjectIvar(controller, "upperToolbar");
        ASTableNode *node = FICObjectIvar(controller, "tableNode");
        UITableView *table = node.isNodeLoaded ? node.view : nil;
        if (!objc_getAssociatedObject(table, &kPaneFindToolbarBand)) {
            CGFloat band = CGRectGetHeight(toolbar.bounds);
            if (band > 0.0 && band < 120.0) {
                objc_setAssociatedObject(table, &kPaneFindToolbarBand, @(band), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIEdgeInsets inset = table.contentInset;
                if (fabs(inset.top - band) <= 1.0) { inset.top = 0; table.contentInset = inset; }
            }
        }
        toolbar.hidden = YES;
        return YES;
    }
    return NO;
}

extern "C" BOOL ApolloPanePresentCommentsFind(UIViewController *controller) {
    if (!ApolloPanePrepareCommentsFind(controller)) return NO;
    if (@available(iOS 16.0, *)) {
        ApolloPaneFindAdapter *adapter = objc_getAssociatedObject(controller, &kPaneFindAdapter);
        [adapter.interaction presentFindNavigatorShowingReplace:NO];
        return YES;
    }
    return NO;
}

#if APOLLO_SIM_BUILD
extern "C" NSDictionary *ApolloPaneSimFind(UIViewController *controller, NSString *operation) {
    if (!ApolloPanePrepareCommentsFind(controller)) return @{@"supported": @NO};
    if (@available(iOS 16.0, *)) {
        ApolloPaneFindAdapter *adapter = objc_getAssociatedObject(controller, &kPaneFindAdapter);
        if ([operation isEqualToString:@"open"]) ApolloPanePresentCommentsFind(controller);
        if ([operation hasPrefix:@"query "]) [adapter performSearchWithQuery:[operation substringFromIndex:6] options:nil];
        if ([operation isEqualToString:@"next"]) [adapter highlightNextResultInDirection:UITextStorageDirectionForward];
        if ([operation isEqualToString:@"previous"]) [adapter highlightNextResultInDirection:UITextStorageDirectionBackward];
        if ([operation isEqualToString:@"dismiss"]) [adapter.interaction dismissFindNavigator];
        return @{@"supported": @YES, @"count": @(adapter.resultCount), @"highlightedIndex": @(adapter.highlightedResultIndex),
            @"hasQuery": @(adapter.nativeField.text.length > 0)};
    }
    return @{@"supported": @NO};
}
#endif

%hook ASTableView
- (void)setContentInset:(UIEdgeInsets)inset {
    NSNumber *band = objc_getAssociatedObject(self, &kPaneFindToolbarBand);
    if (band && fabs(inset.top - band.doubleValue) <= 1.0) inset.top = 0;
    %orig(inset);
}
%end

// MARK: - hooks: selection entry points
//
// Every path that (re)selects a match is one of these three ObjC methods
// (verified in Hopper: the Swift search rebuild is reached only through the
// text-change vtable slot, and sub_10070cf14's other callers are the two
// chevron handlers).

%hook _TtC6Apollo22CommentsViewController

- (void)nextResultButtonTappedWithSender:(id)sender {
    FICRunSelection((UIViewController *)self, ^{ %orig; });
}

- (void)previousResultButtonTappedWithSender:(id)sender {
    FICRunSelection((UIViewController *)self, ^{ %orig; });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    FICCancel((UIViewController *)self);
    if (@available(iOS 16.0, *)) {
        ApolloPaneFindAdapter *adapter = objc_getAssociatedObject(self, &kPaneFindAdapter);
        [adapter.interaction dismissFindNavigator];
    }
}

%end

%hook _TtC6Apollo21ASTableViewController

- (void)textFieldDidBeginEditing:(UITextField *)field {
    if (FICIsCommentsSearchVC(self) && ApolloPaneSplitControllerFor((UIViewController *)self)) {
        [field resignFirstResponder];
        if (ApolloPanePresentCommentsFind((UIViewController *)self)) return;
    }
    %orig;
}

- (void)textFieldEditingChangedWithSender:(id)sender {
    if (!FICIsCommentsSearchVC(self)) {   // feed search bar shares this class — leave it alone
        %orig;
        return;
    }

    NSString *query = nil;
    if ([sender respondsToSelector:@selector(text)]) query = [sender text];
    NSArray<NSString *> *terms = FICParseMultiTerms(query);
    BOOL previousActive = sFICMultiActive;
    NSArray<NSString *> *previousTerms = sFICMultiTerms;
    NSString *previousQuery = sFICMultiQuery;
    sFICMultiTerms = terms;
    sFICMultiQuery = query;
    sFICMultiActive = terms != nil;
    @try {
        FICRunSelection((UIViewController *)self, ^{ %orig; });
    } @finally {
        sFICMultiActive = previousActive;
        sFICMultiTerms = previousTerms;
        sFICMultiQuery = previousQuery;
    }
}

- (void)dismissSearchBarButtonTappedWithSender:(id)sender {
    if (FICIsCommentsSearchVC(self)) {
        FICCancel((UIViewController *)self);
    }
    %orig;
}

%end

%ctor {
    %init;
    ApolloLog(@"[FindInComments] hooks installed (scroll watchdog + comma multi-term search)");
}
