// ApolloInboxCommentScroll.xm
//
// Tapping a reply/comment in the Inbox opens an *isolated single-comment-thread*
// (Reddit permalink + ?context=N) inside CommentsViewController: the post header, a
// "Load parent comments…" button, the parent chain, the linked comment you tapped
// (CommentCellNode.isLinkedToComment == YES, drawn highlighted), and a green
// "View All Comments" footer (the VC's `viewFullPostNode`). The view should open on that
// linked comment.
//
// How Apollo lands there natively (Ghidra, FUN_100706b5c): when the comment tree's first
// batch update completes, it looks the linked comment up in the ListAdapter, reads
// `[tableNode rectForRowAtIndexPath:]` and calls
// `[tableNode setContentOffset:(0, rowY - view.safeAreaInsets.top) animated:YES]`.
// That runs against the thread's very first layout, which goes wrong two ways:
//   1. The layout isn't final yet. Rows keep changing height after it (a reply's inline
//      media resolving, link previews, a giant post body measuring late), so the target is
//      stale. UIKit also clamps it to the content's current end, so the glide stops short.
//   2. It's animated from the top of the post, often while the push is still running: you
//      see the post, a jump, then a long glide with rows blanking while UITableView re-tiles
//      for the far-away target.
// The first version of this module (#457) then pinned the comment to the top with instant
// re-pins whenever the layout changed, which stacked one or two snaps on top of that glide
// (the "jumps up and down" in the inbox → comment transition).
//
// Fix: the tweak owns the landing for isolated threads and makes it one instant placement
// that doesn't move afterwards.
//   - Land: the first table layout that has the linked row puts it at the top of the visible
//     area (clamped to the content). This runs in ASTableView's layoutSubviews, after UIKit
//     tiled the rows and before the frame paints, so the thread appears already on your
//     comment: no frame of the post's top, no glide.
//   - Apollo's own animated landing scroll (the first animated setContentOffset it sends that
//     table) is swallowed: by the time it fires we're already there.
//   - Anchor: until the layout settles, every later layout keeps the linked comment at the
//     same spot on screen. Rows above that grow or shrink (post body, a parent's media) are
//     absorbed before paint; rows below that grow (a reply's image) fill in underneath; the
//     "Find in Comments" bar collapsing at the end of the push no longer drags the list up
//     with it. If the thread was short at landing and the comment sat lower on screen, it
//     stays there instead of sliding up when a reply's media arrives later.
//   - A poll loop is the backstop: it lands when no layout pass comes, detects the settle,
//     and enforces the deadlines.
// It never fights the user. A touch, drag or deceleration, a status-bar tap, reselecting the
// thread's tab, the comment-jump button, a Find in Comments search, any other animated scroll
// Apollo sends the table, or leaving the thread ends it for good. It arms only on the thread's
// first appearance, so coming back from a pushed profile or a cancelled swipe-back leaves your
// scroll position alone.
//
// Scope guard: only isolated threads (viewFullPostNode set or continuingThread). A normal
// full-comments view is detected within a short grace window and left completely alone.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"

@interface _TtC6Apollo21ASTableViewController : UIViewController
@end

@interface _TtC6Apollo22CommentsViewController : _TtC6Apollo21ASTableViewController
@end

@interface ASTableView : UITableView
- (void)requeryNodeHeights;
@end

@interface ASTableNode : NSObject
@end

@interface _TtC6Apollo13SceneDelegate : NSObject
@end

// MARK: - tunables

static const NSTimeInterval kICSInterval = 0.10;           // poll cadence (backstop + settle detection)
static const NSTimeInterval kICSIsolatedGrace = 2.5;       // not isolated by then -> normal comments view, stop
static const NSTimeInterval kICSUnresolvedDeadline = 6.0;  // linked comment never found -> bottom fallback
static const NSTimeInterval kICSQuietToFinish = 1.5;       // landed and nothing moved for this long -> done
static const NSTimeInterval kICSDeadline = 8.0;            // stop anchoring for good after this
static const CGFloat kICSDriftThreshold = 0.5;             // offsets within this of the target are on target
static const NSInteger kICSMaxCorrections = 40;            // something else keeps moving the list -> give up

// MARK: - per-thread state

@interface ApolloICSState : NSObject
@property (nonatomic) long gen;
@property (nonatomic) CFTimeInterval armedAt;
@property (nonatomic) CFTimeInterval lastActivity;        // landing, a correction, or a content size change
@property (nonatomic) CGFloat lastContentHeight;
@property (nonatomic) CGFloat anchorY;                    // linked row's y in the visible area, fixed at landing
@property (nonatomic) NSInteger corrections;
@property (nonatomic) BOOL isolated;                      // confirmed isolated thread
@property (nonatomic) BOOL landed;
@property (nonatomic) BOOL nativeSwallowed;               // Apollo's one animated landing scroll consumed
@property (nonatomic) BOOL ended;
@property (nonatomic, strong) NSIndexPath *linked;        // cached linked row, re-validated on each use
@end

@implementation ApolloICSState
@end

static const void *kICSStateKey = &kICSStateKey;
static long gICSGen = 0;

// The thread currently landing (the latest one to appear wins) and its table view. The raw
// table pointer only gates ASTableView's layoutSubviews hook with a pointer compare, so every
// other table pays nothing; it is never dereferenced.
static __weak UIViewController *sICSVC = nil;
static void *sICSTable = NULL;

// MARK: - runtime helpers

static UITableView *ICSFindTable(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *s in v.subviews) {
        UITableView *t = ICSFindTable(s);
        if (t) return t;
    }
    return nil;
}

static UITableView *ICSTableView(UIViewController *vc, id tableNode) {
    if (tableNode) {
        SEL viewSel = @selector(view);
        if ([tableNode respondsToSelector:viewSel]) {
            UIView *tv = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSel);
            if ([tv isKindOfClass:[UITableView class]]) return (UITableView *)tv;
        }
    }
    return ICSFindTable(vc.viewIfLoaded);
}

// Isolated single-comment-thread: has the "View All Comments" footer node, or is a
// continued-thread view. Either way it has a linked comment to land on.
static BOOL ICSIsIsolatedThread(UIViewController *vc) {
    return ApolloObjectIvar(vc, "viewFullPostNode") != nil ||
           ApolloReadBoolIvar(vc, "continuingThread", NO);
}

static ApolloICSState *ICSStateFor(UIViewController *vc) {
    return vc ? objc_getAssociatedObject(vc, kICSStateKey) : nil;
}

// Find the linked comment's index path. AsyncDisplayKit holds a node object for every row —
// even ones far below the fold — so this resolves the linked comment without scrolling first.
// The last hit is cached and re-validated, so layout passes don't rescan the whole thread.
static NSIndexPath *ICSLinkedIndexPath(ApolloICSState *st, id tableNode, UITableView *tableView) {
    SEL nodeSel = @selector(nodeForRowAtIndexPath:);
    if (![tableNode respondsToSelector:nodeSel]) return nil;
    NSIndexPath *cached = st.linked;
    if (cached && cached.section < [tableView numberOfSections] &&
        cached.row < [tableView numberOfRowsInSection:cached.section]) {
        id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, cached);
        if (node && ApolloReadBoolIvar(node, "isLinkedToComment", NO)) return cached;
    }
    for (NSInteger s = [tableView numberOfSections] - 1; s >= 0; s--) {
        for (NSInteger r = [tableView numberOfRowsInSection:s] - 1; r >= 0; r--) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
            if (node && ApolloReadBoolIvar(node, "isLinkedToComment", NO)) {
                st.linked = ip;
                return ip;
            }
        }
    }
    st.linked = nil;
    return nil;
}

// The hold can leave the list scrolled past its end if a row below shrank and never grew back.
// When the landing ends on its own (settled, deadline), ease that back in rather than leaving it
// for UIKit to snap on the next layout or drag. A user who is already touching the list gets
// UIKit's own rubber-band instead.
static void ICSEaseOutOverscroll(UIViewController *vc) {
    UITableView *tv = ICSTableView(vc, ApolloObjectIvar(vc, "tableNode"));
    if (!tv || tv.isTracking || tv.isDragging || tv.isDecelerating) return;
    UIEdgeInsets inset = tv.adjustedContentInset;
    CGFloat minOff = -inset.top;
    CGFloat maxOff = MAX(minOff, tv.contentSize.height - tv.bounds.size.height + inset.bottom);
    CGFloat cur = tv.contentOffset.y;
    if (cur <= maxOff + kICSDriftThreshold) return;
    [tv setContentOffset:CGPointMake(tv.contentOffset.x, maxOff) animated:YES];
    ApolloLog(@"[InboxScroll] eased the leftover overscroll back in: off %.0f -> %.0f", cur, maxOff);
}

static void ICSEnd(UIViewController *vc, NSString *reason, BOOL easeOverscroll) {
    ApolloICSState *st = ICSStateFor(vc);
    if (!st || st.ended) return;
    st.ended = YES;
    if (sICSVC == vc) {
        sICSVC = nil;
        sICSTable = NULL;
    }
    if (easeOverscroll && st.landed) ICSEaseOutOverscroll(vc);
    // Normal (non-isolated) threads end quietly; only the landing's own story is worth a line.
    if (st.isolated) {
        ApolloLog(@"[InboxScroll] done: %@ (landed=%d, corrections=%ld, %.0fms after arming, gen=%ld)",
                  reason, st.landed, (long)st.corrections, (CACurrentMediaTime() - st.armedAt) * 1000.0, st.gen);
    }
}

// Land on (first call with the linked row available) or hold (every later call) the linked
// comment. Instant offset writes only. Returns -1 not ready / ended, 0 moved, 1 already in place.
// Safe to call from ASTableView's layoutSubviews, viewDidLayoutSubviews and the poll.
static int ICSAnchor(UIViewController *vc, NSString *reason) {
    ApolloICSState *st = ICSStateFor(vc);
    if (!st || st.ended) return -1;
    if (!st.isolated) {
        if (!ICSIsIsolatedThread(vc)) return -1;
        st.isolated = YES;
        ApolloLog(@"[InboxScroll] isolated thread — taking over the landing (%@, gen=%ld)", reason, st.gen);
    }

    id tableNode = ApolloObjectIvar(vc, "tableNode");
    UITableView *tv = ICSTableView(vc, tableNode);
    if (!tv) return -1;
    if (tv.isTracking || tv.isDragging || tv.isDecelerating) {
        ICSEnd(vc, @"user touched the list", NO);
        return -1;
    }

    NSIndexPath *linked = ICSLinkedIndexPath(st, tableNode, tv);
    if (!linked) return -1;

    CFTimeInterval now = CACurrentMediaTime();
    CGFloat h = tv.contentSize.height;
    if (fabs(h - st.lastContentHeight) > 0.5) {
        st.lastContentHeight = h;
        st.lastActivity = now;
    }

    CGRect rr = [tv rectForRowAtIndexPath:linked];
    UIEdgeInsets inset = tv.adjustedContentInset;
    CGFloat minOff = -inset.top;
    CGFloat maxOff = MAX(minOff, h - tv.bounds.size.height + inset.bottom);
    CGFloat rowTop = rr.origin.y - inset.top;   // offset that puts the row flush under the top edge
    CGFloat cur = tv.contentOffset.y;

    if (!st.landed) {
        CGFloat desired = MIN(MAX(rowTop, minOff), maxOff);
        st.landed = YES;
        st.anchorY = rr.origin.y - desired;
        st.lastActivity = now;
        if (fabs(cur - desired) > kICSDriftThreshold) {
            [tv setContentOffset:CGPointMake(tv.contentOffset.x, desired) animated:NO];
        }
        ApolloLog(@"[InboxScroll] landed on linked %@ off %.0f -> %.0f (row at %.0f, content %.0f, top inset %.0f, via %@, %.0fms after arming, gen=%ld)",
                  linked, cur, desired, st.anchorY, h, inset.top, reason, (now - st.armedAt) * 1000.0, st.gen);
        return 0;
    }

    // Hold the comment where it landed on screen. Two UIKit adjustments would otherwise move it,
    // and both are undone here in the same run-loop pass, before the frame commits:
    //   - the "Find in Comments" bar collapsing at the end of the push shifts the offset by the
    //     bar's height (_UIScrollViewAdjustForOverlayInsetsChangeIfNecessary);
    //   - a row below shrinking while we sit at the content's end (a reply's link card swapping
    //     to its media placeholder) clamps the offset to the new end.
    // So there is deliberately no max clamp while holding: a shrink below briefly leaves space
    // under the last row instead of dragging the comment down, and the media that replaces it
    // normally fills that space back in. ICSEnd eases any overscroll left at the end back in.
    CGFloat desired = MAX(rr.origin.y - st.anchorY, minOff);
    if (fabs(cur - desired) <= kICSDriftThreshold) return 1;

    st.corrections += 1;
    st.lastActivity = now;
    if (st.corrections > kICSMaxCorrections) {
        ICSEnd(vc, @"gave up — something else keeps moving the list", YES);
        return -1;
    }
    [tv setContentOffset:CGPointMake(tv.contentOffset.x, desired) animated:NO];
    if (st.corrections <= 12) {
        ApolloLog(@"[InboxScroll] held linked in place off %.0f -> %.0f (content %.0f, top inset %.0f, via %@)",
                  cur, desired, h, inset.top, reason);
    }
    return 0;
}

// MARK: - poll loop (backstop + settle detection)

static void ICSScheduleTick(__weak UIViewController *weakVC, long gen);

static void ICSTick(__weak UIViewController *weakVC, long gen) {
    UIViewController *vc = weakVC;
    if (!vc) return;
    ApolloICSState *st = ICSStateFor(vc);
    if (!st || st.ended || st.gen != gen) return;
    if (sICSVC != vc) {                                      // a newer thread took over
        ICSEnd(vc, @"another thread appeared", NO);
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    NSTimeInterval elapsed = now - st.armedAt;
    if (elapsed > kICSDeadline) {
        ICSEnd(vc, @"deadline", YES);
        return;
    }

    ICSAnchor(vc, @"poll");
    if (st.ended) return;

    if (!st.isolated) {
        if (elapsed > kICSIsolatedGrace) {
            ICSEnd(vc, @"normal comments view", NO);         // left completely alone
            return;
        }
    } else if (!st.landed) {
        if (elapsed > kICSUnresolvedDeadline) {
            // Linked comment never resolved. Best effort: if still stuck near the top of a
            // scrollable thread, fall back to the bottom (the linked comment sits just above
            // the footer in an isolated thread).
            UITableView *tv = ICSTableView(vc, ApolloObjectIvar(vc, "tableNode"));
            if (tv) {
                CGFloat insetTop = tv.adjustedContentInset.top;
                CGFloat insetBottom = tv.adjustedContentInset.bottom;
                CGFloat viewportH = tv.bounds.size.height;
                CGFloat h = tv.contentSize.height;
                BOOL scrollable = (h + insetTop + insetBottom) > viewportH + 1.0;
                if (scrollable && tv.contentOffset.y <= (-insetTop + 60.0)) {
                    CGFloat bottom = MAX(-insetTop, h - viewportH + insetBottom);
                    [tv setContentOffset:CGPointMake(tv.contentOffset.x, bottom) animated:YES];
                    ApolloLog(@"[InboxScroll] deadline fallback: scrolled to bottom off=%.0f (linked unresolved)", bottom);
                }
            }
            ICSEnd(vc, @"linked comment never resolved", NO);
            return;
        }
    } else if (now - st.lastActivity > kICSQuietToFinish) {
        ICSEnd(vc, @"settled", YES);
        return;
    }

    ICSScheduleTick(weakVC, gen);
}

static void ICSScheduleTick(__weak UIViewController *weakVC, long gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kICSInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ICSTick(weakVC, gen);
    });
}

// Arm on the thread's first appearance only. viewWillAppear rather than viewDidAppear: the
// comments often load while the push is still running, and the landing has to be in place
// before that first content frame paints.
static void ICSArm(UIViewController *vc) {
    if (ICSStateFor(vc)) return;
    ApolloICSState *st = [ApolloICSState new];
    st.gen = ++gICSGen;
    st.armedAt = CACurrentMediaTime();
    st.lastActivity = st.armedAt;
    objc_setAssociatedObject(vc, kICSStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIViewController *previous = sICSVC;
    if (previous && previous != vc) ICSEnd(previous, @"another thread appeared", NO);
    sICSVC = vc;
    sICSTable = (__bridge void *)ICSTableView(vc, ApolloObjectIvar(vc, "tableNode"));

    ICSAnchor(vc, @"arm");                                   // content may already be there
    ICSScheduleTick(vc, st.gen);
}

// MARK: - hooks

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ICSArm((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    // A safety net for layout passes that change the insets without re-laying out the table.
    if (sICSVC == (UIViewController *)self) ICSAnchor((UIViewController *)self, @"viewDidLayoutSubviews");
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    ICSEnd((UIViewController *)self, @"left the thread", NO);
}

- (void)scrollViewWillBeginDragging:(id)scrollView {
    %orig;
    ICSEnd((UIViewController *)self, @"user drag", NO);
}

// The comment-jump button scrolls the list itself: end first so the hold never fights it.
- (void)commentJumpButtonTappedWithSender:(id)sender {
    ICSEnd((UIViewController *)self, @"comment-jump button", NO);
    %orig;
}

- (void)commentJumpButtonLongPressedWithSender:(id)sender {
    ICSEnd((UIViewController *)self, @"comment-jump button", NO);
    %orig;
}

%end

%hook _TtC6Apollo21ASTableViewController

// Same for a status-bar / title tap (UIKit's scroll-to-top or the tweak's scroll-return jump)
// and for starting a Find in Comments search, whose results scroll the list.
// ApolloScrollToTop.xm hooks this selector too and returns NO without %orig when it starts its
// own jump, so this module links after it (see the note above ApolloReborn_FILES in the Makefile)
// to make this hook the outer one.
- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView {
    if ((UIViewController *)self == sICSVC) ICSEnd((UIViewController *)self, @"status-bar tap", NO);
    return %orig;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if ((UIViewController *)self == sICSVC) ICSEnd((UIViewController *)self, @"Find in Comments", NO);
    %orig;
}

%end

// Reselecting the tab the thread is on: ApolloScrollToTop.xm runs its display-link jump to the
// top there (or pops) and returns NO without %orig, and that jump writes contentOffset frame by
// frame, which the hold can't tell from UIKit moving the list. End first; the link order above
// keeps this hook outside ScrollToTop's.
%hook _TtC6Apollo13SceneDelegate

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)viewController {
    UIViewController *vc = sICSVC;
    if (vc && viewController == tabBarController.selectedViewController && vc.tabBarController == tabBarController) {
        ICSEnd(vc, @"tab reselected", NO);
    }
    return %orig;
}

%end

%hook ASTableView

// Land / hold inside the table's own layout pass: after UIKit tiled the rows for this frame
// (including any row-height change), before it paints.
- (void)layoutSubviews {
    %orig;
    if ((__bridge void *)self != sICSTable) return;
    UIViewController *vc = sICSVC;
    if (vc) ICSAnchor(vc, @"layout");
}

// Texture re-measured a row (a long post body, a parent's media) and commits the new height with
// a plain beginUpdates/endUpdates, which UIKit animates: every row below slides over ~0.3 s. The
// hold moves the offset at once, so for a row above the comment that read as a jump up and a slide
// back down. While the landing holds, commit the height instantly instead and re-anchor in the same
// pass, so the comment doesn't move at all.
- (void)requeryNodeHeights {
    UIViewController *vc = ((__bridge void *)self == sICSTable) ? sICSVC : nil;
    ApolloICSState *st = ICSStateFor(vc);
    if (!st || !st.landed || st.ended) {
        %orig;
        return;
    }
    [UIView performWithoutAnimation:^{
        %orig;
    }];
    ICSAnchor(vc, @"row heights");
}

%end

%hook ASTableNode

// Apollo's native landing (FUN_100706b5c) is the first animated setContentOffset on the thread's
// table: swallow it once we've placed the comment ourselves. Any later animated scroll there is
// someone else's (status-bar tap, comment-jump button), so it ends the landing instead.
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    UIViewController *vc = animated ? sICSVC : nil;
    if (!vc || ApolloObjectIvar(vc, "tableNode") != (id)self) {
        %orig;
        return;
    }
    ApolloICSState *st = ICSStateFor(vc);
    if (!st || st.ended) {
        %orig;
        return;
    }
    if (st.nativeSwallowed) {
        ICSEnd(vc, @"programmatic animated scroll", NO);
        %orig;
        return;
    }
    st.nativeSwallowed = YES;
    if (ICSAnchor(vc, @"Apollo's landing scroll") >= 0) {
        ApolloLog(@"[InboxScroll] swallowed Apollo's animated landing scroll to %.0f (gen=%ld)", offset.y, st.gen);
        return;
    }
    if (st.isolated && !st.ended) {
        // Couldn't resolve the linked row ourselves yet: let Apollo place it, minus the glide.
        ApolloLog(@"[InboxScroll] linked row not resolved yet — Apollo's landing scroll to %.0f made instant (gen=%ld)", offset.y, st.gen);
        %orig(offset, NO);
        return;
    }
    %orig;
}

%end

%ctor {
    %init;
    ApolloLog(@"[InboxScroll] hook installed (inbox → linked comment: instant landing + hold)");
}
