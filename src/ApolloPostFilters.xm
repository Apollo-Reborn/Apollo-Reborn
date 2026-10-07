// ApolloPostFilters
//
// Reborn "Post Filters" — device-wide content filters that beef out Apollo's
// native Filters & Blocks screen. Three filter kinds (all configured on the
// native screen via ApolloFiltersBlocksInject.xm):
//
//   1. Per-subreddit KEYWORDS — hide posts in r/<sub> whose title/link contains
//      any configured word.
//   2. Per-subreddit FLAIRS — hide posts in r/<sub> whose flair label matches.
//   3. Subreddit-NAME substrings — hide any post whose subreddit name contains a
//      configured word (e.g. "circlejerk" hides r/carscirclejerk). The same names
//      are also filtered out of the search screen's subreddit suggestions (see the
//      _TtC6Apollo20SearchViewController hook below).
//
// Matching keys on the POST's own `link.subreddit`, so per-sub rules apply
// wherever that sub's posts appear (Home / All / the sub itself), mirroring how
// Apollo's native subreddit filters behave.
//
// Enforcement reuses the Community Highlights hide mechanism: hook the post cell
// nodes' -layoutSpecThatFits: and return a zero-size ASStackLayoutSpec to collapse
// the row to 0pt (keeps Apollo's `links` array + pagination intact — no IGListKit
// desync), and collapse the trailing ThickSeparatorCellNode so hidden posts don't
// leave stacked 8pt breaker gaps.
//
// Threading: the matcher reads the immutable ApolloState snapshots
// (sPostFilterSubreddits / sPostFilterNameSubstrings) off-main during Texture
// layout. Writes always swap in a fresh [copy] (see ApolloPostFilterStore), so a
// reader either sees the old or the new immutable container — never a mutating one.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloPostFilterStore.h"
#import "ApolloSwiftRuntime.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"
#import "ApolloClasses.h"

// RDKLink fields not declared on the shared interface in Tweak.h.
@interface RDKLink (ApolloPostFilters)
@property (copy, nonatomic) NSString *linkFlairText;
@property (retain, nonatomic) RDKLink *crosspostParent;
@end

// ASSizeRange ABI: { CGSize min; CGSize max; } — matches the arg of
// -layoutSpecThatFits: / -calculateLayoutThatFits:.
struct ApolloPFSizeRange { CGSize min; CGSize max; };

// Dummy interface so the ASStackLayoutSpec factory selector is known to the
// compiler (the real class is resolved at runtime via objc_getClass).
@interface ApolloPFStackSpec : NSObject
+ (instancetype)stackLayoutSpecWithDirection:(NSInteger)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(NSUInteger)justifyContent
                                  alignItems:(NSUInteger)alignItems
                                    children:(NSArray *)children;
@end

#pragma mark - Matcher

static BOOL ApolloPFContainsAnyTerm(NSString *haystackLower, NSArray<NSString *> *needlesLower) {
    if (haystackLower.length == 0 || needlesLower.count == 0) return NO;
    for (NSString *n in needlesLower) {
        if (n.length == 0) continue;
        if ([haystackLower rangeOfString:n].location != NSNotFound) return YES;
    }
    return NO;
}

// YES if a subreddit name contains any configured name-substring (the same test
// used for feed posts and search suggestions). Case-insensitive.
static BOOL ApolloPFSubredditNameBlocked(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return NO;
    NSArray<NSString *> *names = sPostFilterNameSubstrings;
    if (names.count == 0) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *frag in names) {
        if (frag.length > 0 && [lower rangeOfString:frag].location != NSNotFound) return YES;
    }
    return NO;
}

// The post's visible flair label, normalized via the SAME transform the store
// applies to typed flair filters (ApolloPostFilterStore normalizeFlair: — strips
// ":emoji:" snoomoji tokens, collapses whitespace, trims, lowercases) so an exact
// match lines up. Reddit post flairs frequently embed emoji tokens in the raw
// linkFlairText (e.g. r/soccer's ":n_media: Media"); only the trailing words
// render as the visible label. Falls back to linkFlairRichText text segments when
// linkFlairText is empty.
static NSString *ApolloPFNormalizedFlairLabel(id linkObj) {
    NSString *flair = nil;
    @try { flair = ((RDKLink *)linkObj).linkFlairText; } @catch (__unused id e) {}
    if (![flair isKindOfClass:[NSString class]] || flair.length == 0) {
        @try {
            id rich = [(NSObject *)linkObj valueForKey:@"linkFlairRichText"];
            if ([rich isKindOfClass:[NSArray class]]) {
                NSMutableString *acc = [NSMutableString string];
                for (id seg in (NSArray *)rich) {
                    if ([seg isKindOfClass:[NSDictionary class]]) {
                        id t = ((NSDictionary *)seg)[@"t"];
                        if ([t isKindOfClass:[NSString class]]) [acc appendString:(NSString *)t];
                    }
                }
                flair = acc;
            }
        } @catch (__unused id e) {}
    }
    return [ApolloPostFilterStore normalizeFlair:flair];
}

// Tests a single link object (top-level post or a crosspost parent) against the
// configured rules. Returns YES if it should be hidden.
static BOOL ApolloPFLinkMatchesRules(id linkObj) {
    Class linkCls = ApolloClassRDKLink;
    if (!linkCls || ![linkObj isMemberOfClass:linkCls]) return NO;
    RDKLink *link = (RDKLink *)linkObj;

    NSString *sub = nil;
    @try { sub = link.subreddit; } @catch (__unused id e) {}
    if (![sub isKindOfClass:[NSString class]] || sub.length == 0) return NO;
    NSString *subKey = sub.lowercaseString;

    // 1) Subreddit-name substring match (applies to any subreddit).
    if (ApolloPFSubredditNameBlocked(subKey)) return YES;

    // 2) Per-subreddit keyword / flair rules.
    NSDictionary *rules = sPostFilterSubreddits[subKey];
    if (![rules isKindOfClass:[NSDictionary class]]) return NO;

    NSArray<NSString *> *keywords = rules[@"keywords"];
    if ([keywords isKindOfClass:[NSArray class]] && keywords.count > 0) {
        NSString *title = nil; @try { title = link.title; } @catch (__unused id e) {}
        NSString *titleLower = [title isKindOfClass:[NSString class]] ? title.lowercaseString : @"";
        if (ApolloPFContainsAnyTerm(titleLower, keywords)) return YES;
        // Also test the link URL, mirroring Apollo's native "title, link, or flair".
        NSString *urlLower = @"";
        @try {
            NSURL *u = link.URL;
            if ([u isKindOfClass:[NSURL class]]) urlLower = u.absoluteString.lowercaseString ?: @"";
        } @catch (__unused id e) {}
        if (ApolloPFContainsAnyTerm(urlLower, keywords)) return YES;
    }

    NSArray<NSString *> *flairs = rules[@"flairs"];
    if ([flairs isKindOfClass:[NSArray class]] && flairs.count > 0) {
        NSString *flairLower = ApolloPFNormalizedFlairLabel(link);
        if (flairLower.length > 0) {
            for (NSString *f in flairs) {
                if (f.length > 0 && [f isEqualToString:flairLower]) return YES; // exact (visible) label match
            }
        }
    }
    return NO;
}

static BOOL ApolloPFFiltersConfigured(void) {
    return sPostFilterSubreddits.count > 0 || sPostFilterNameSubstrings.count > 0;
}

static BOOL ApolloPFShouldHideLink(id link) {
    if (!link) return NO;
    if (ApolloPFLinkMatchesRules(link)) return YES;
    // Crosspost: also test the original post so a crosspost FROM a filtered sub
    // (or carrying the parent's title/flair) is filtered too.
    @try {
        RDKLink *parent = ((RDKLink *)link).crosspostParent;
        if (parent && ApolloPFLinkMatchesRules(parent)) return YES;
    } @catch (__unused id e) {}
    return NO;
}

#pragma mark - Cell / node helpers

static BOOL ApolloPFCellShouldHide(id cell) {
    // Fast out: nothing configured (the common case).
    if (!ApolloPFFiltersConfigured()) return NO;
    return ApolloPFShouldHideLink(ApolloObjectIvar(cell, "link"));
}

// Zero-size layout spec used to collapse a hidden cell.
static id ApolloPFEmptySpec(void) {
    Class stackClass = ApolloClassASStackLayoutSpec;
    if (!stackClass) return nil;
    return [stackClass stackLayoutSpecWithDirection:0 spacing:0 justifyContent:0 alignItems:0 children:@[]];
}

// ThickSeparator bakes an 8pt fixed height into its style. Preserve all three
// dimensions before collapsing so Texture can reuse the node after filters
// change without leaving a permanently zero-height separator behind.
typedef struct { NSInteger unit; CGFloat value; } ApolloPFDim;
typedef struct {
    ApolloPFDim height;
    ApolloPFDim minHeight;
    ApolloPFDim maxHeight;
    uint8_t available;
} ApolloPFHeightSnapshot;
static char kApolloPFHeightSnapshotKey;
static char kApolloPFCollapsedKey;

static BOOL ApolloPFReadDimension(id style, SEL selector, ApolloPFDim *value) {
    if (!style || !value || ![style respondsToSelector:selector]) return NO;
    *value = ((ApolloPFDim (*)(id, SEL))objc_msgSend)(style, selector);
    return YES;
}

static void ApolloPFWriteDimension(id style, SEL selector, ApolloPFDim value) {
    if (style && [style respondsToSelector:selector]) {
        ((void (*)(id, SEL, ApolloPFDim))objc_msgSend)(style, selector, value);
    }
}

static BOOL ApolloPFSetNodeCollapsedLocked(id node, BOOL collapsed) {
    id style = [node respondsToSelector:@selector(style)] ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(style)) : nil;
    if (!style) return NO;
    BOOL wasCollapsed = [objc_getAssociatedObject(node, &kApolloPFCollapsedKey) boolValue];
    if (wasCollapsed == collapsed) return NO;

    if (collapsed) {
        ApolloPFHeightSnapshot snapshot = {};
        if (ApolloPFReadDimension(style, @selector(height), &snapshot.height)) snapshot.available |= 1;
        if (ApolloPFReadDimension(style, @selector(minHeight), &snapshot.minHeight)) snapshot.available |= 2;
        if (ApolloPFReadDimension(style, @selector(maxHeight), &snapshot.maxHeight)) snapshot.available |= 4;
        objc_setAssociatedObject(node, &kApolloPFHeightSnapshotKey,
                                 [NSValue valueWithBytes:&snapshot objCType:@encode(ApolloPFHeightSnapshot)],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloPFDim zero = {1, 0.0}; // ASDimensionUnitPoints
        if (snapshot.available & 1) ApolloPFWriteDimension(style, @selector(setHeight:), zero);
        if (snapshot.available & 2) ApolloPFWriteDimension(style, @selector(setMinHeight:), zero);
        if (snapshot.available & 4) ApolloPFWriteDimension(style, @selector(setMaxHeight:), zero);
        objc_setAssociatedObject(node, &kApolloPFCollapsedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }

    NSValue *boxed = objc_getAssociatedObject(node, &kApolloPFHeightSnapshotKey);
    if (boxed) {
        ApolloPFHeightSnapshot snapshot = {};
        [boxed getValue:&snapshot size:sizeof(snapshot)];
        if (snapshot.available & 1) ApolloPFWriteDimension(style, @selector(setHeight:), snapshot.height);
        if (snapshot.available & 2) ApolloPFWriteDimension(style, @selector(setMinHeight:), snapshot.minHeight);
        if (snapshot.available & 4) ApolloPFWriteDimension(style, @selector(setMaxHeight:), snapshot.maxHeight);
    }
    objc_setAssociatedObject(node, &kApolloPFHeightSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloPFCollapsedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL ApolloPFSetNodeCollapsed(id node, BOOL collapsed) {
    if (!node || ![node respondsToSelector:@selector(lock)] ||
        ![node respondsToSelector:@selector(unlock)]) return NO;
    // Texture already holds this recursive lock while measuring a node. Use the
    // same lock for main-queue reconciliation so the two paths have one lock
    // order, and always release it when a style accessor raises or we return.
    ((void (*)(id, SEL))objc_msgSend)(node, @selector(lock));
    @try {
        return ApolloPFSetNodeCollapsedLocked(node, collapsed);
    } @finally {
        ((void (*)(id, SEL))objc_msgSend)(node, @selector(unlock));
    }
}

static BOOL ApolloPFNodeIsCollapsed(id node) {
    return [objc_getAssociatedObject(node, &kApolloPFCollapsedKey) boolValue];
}

static NSIndexPath *ApolloPFPostPathForSeparatorPath(NSIndexPath *separatorPath) {
    if (separatorPath.length < 2) return nil;
    NSUInteger section = [separatorPath indexAtPosition:0];
    NSUInteger row = [separatorPath indexAtPosition:1];
    if (row < 1) return nil;
    NSUInteger indexes[] = {section, row - 1};
    return [NSIndexPath indexPathWithIndexes:indexes length:2];
}

#pragma mark - Trailing-separator collapse
//
// Each post cell is followed by a ThickSeparatorCellNode. When we collapse a
// post to 0pt its separator stays (8pt), so a run of hidden posts would stack
// breaker gaps. We record each post's hide decision per owning table node (keyed
// by row), and the separator at row r collapses when the post at row r-1 is
// hidden. Records are updated both ways on every post layout so a row that stops
// being hidden (after a data reload) clears correctly.

static char kApolloPFHiddenRowsKey;

static void ApolloPFRefreshSeparatorNode(id separatorNode);

static id ApolloPFOwningTableNode(id cellNode) {
    return [cellNode respondsToSelector:@selector(owningNode)] ? ((id (*)(id, SEL))objc_msgSend)(cellNode, @selector(owningNode)) : nil;
}
static NSIndexPath *ApolloPFNodeIndexPath(id cellNode) {
    if (![cellNode respondsToSelector:@selector(indexPath)]) return nil;
    return ((NSIndexPath *(*)(id, SEL))objc_msgSend)(cellNode, @selector(indexPath));
}
// Caller holds @synchronized(owningTable). The set is associated with the stable
// owning table node and only mutated/emptied (never niled), so it can't be freed
// while an off-main layout reads it.
static NSMutableSet *ApolloPFHiddenRowsSet(id owningTable, BOOL create) {
    if (!owningTable) return nil;
    NSMutableSet *set = objc_getAssociatedObject(owningTable, &kApolloPFHiddenRowsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(owningTable, &kApolloPFHiddenRowsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}
static void ApolloPFUpdateHiddenRow(id postNode, BOOL hidden) {
    id owning = ApolloPFOwningTableNode(postNode);
    NSIndexPath *postPath = ApolloPFNodeIndexPath(postNode);
    NSInteger row = postPath ? postPath.row : -1;
    if (!owning || !postPath || row < 0) return;
    BOOL changed = NO;
    @synchronized(owning) {
        NSMutableSet *set = ApolloPFHiddenRowsSet(owning, YES);
        BOOL had = [set containsObject:postPath];
        if (hidden && !had) { [set addObject:[postPath copy]]; changed = YES; }
        else if (!hidden && had) { [set removeObject:postPath]; changed = YES; }
    }
    if (changed) {
        // Texture measures post and separator nodes concurrently. Reconcile the
        // one trailing separator on the main queue after this post decision is
        // published, rather than re-laying out every node in the feed.
        __weak id weakOwning = owning;
        NSIndexPath *separatorPath = [NSIndexPath indexPathForRow:row + 1 inSection:postPath.section];
        dispatch_async(dispatch_get_main_queue(), ^{
            id tableNode = weakOwning;
            SEL selector = @selector(nodeForRowAtIndexPath:);
            if (!tableNode || ![tableNode respondsToSelector:selector]) return;
            id separator = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, selector, separatorPath);
            if ([separator class] == ApolloClassThickSeparatorCellNode) {
                ApolloPFRefreshSeparatorNode(separator);
            }
        });
    }
}
static BOOL ApolloPFSeparatorShouldCollapse(id sepNode) {
    if (!ApolloPFFiltersConfigured()) return NO;
    NSIndexPath *separatorPath = ApolloPFNodeIndexPath(sepNode);
    NSIndexPath *postPath = ApolloPFPostPathForSeparatorPath(separatorPath);
    if (!postPath) return NO;
    id owning = ApolloPFOwningTableNode(sepNode);
    if (!owning) return NO;
    @synchronized(owning) {
        NSMutableSet *set = ApolloPFHiddenRowsSet(owning, NO);
        return [set containsObject:postPath];
    }
}

#pragma mark - Live refresh

// Re-measure visible feeds after a settings change so the new rules take effect
// without requiring a scroll. relayoutItems on the ASTableNode forces a fresh
// layoutSpecThatFits: pass; reloadData on the table view is a belt-and-suspenders
// fallback for any plain UITableView.
static void ApolloPFReloadTableNode(id tableNode); // defined below

static void ApolloPFRefreshVisibleFeeds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^__block walk)(UIView *) = nil;
        void (^localWalk)(UIView *) = ^(UIView *root) {
            if ([root isKindOfClass:[UITableView class]]) {
                UITableView *tv = (UITableView *)root;
                id node = nil;
                if ([tv respondsToSelector:@selector(tableNode)]) {
                    @try { node = ((id (*)(id, SEL))objc_msgSend)(tv, @selector(tableNode)); } @catch (__unused id e) {}
                }
                if (node) ApolloPFReloadTableNode(node);   // Texture feed: re-measure cells
                else @try { [tv reloadData]; } @catch (__unused id e) {} // plain UITableView fallback
            }
            for (UIView *sub in root.subviews) walk(sub);
        };
        walk = localWalk;
        // Union UIApplication.windows with the active scenes' windows — on iOS 26 a
        // scene app's visible window can be absent from UIApplication.windows, so the
        // immediate refresh would otherwise miss the currently-visible feed.
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        @try { for (UIWindow *w in [UIApplication sharedApplication].windows) if (w) [windows addObject:w]; } @catch (__unused id e) {}
        @try {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w && ![windows containsObject:w]) [windows addObject:w];
                }
            }
        } @catch (__unused id e) {}
        for (UIWindow *window in windows) walk(window);
        walk = nil;
    });
}

// Cross-tab live apply. A generation counter is bumped on every filter change.
// A feed that last laid out under an older generation re-measures on its next
// appearance — so adding a filter in Settings takes effect when you return to the
// feed tab, even though Texture caches layouts and a plain tab switch would
// otherwise keep stale cells. (The currently-visible feed is handled directly by
// ApolloPFRefreshVisibleFeeds above.)
static int sApolloPFGeneration = 0;
static const void *kApolloPFAppliedGenKey = &kApolloPFAppliedGenKey;

// Force a full re-measure of an ASTableNode's cells. reloadData re-runs every
// cell's layoutSpecThatFits: (where the matcher decides to collapse), which
// relayoutItems alone does not for already-measured/cached nodes. This is the
// reliable way to apply a filter change to an existing feed.
static void ApolloPFReloadTableNode(id tableNode) {
    if ([tableNode respondsToSelector:@selector(reloadData)]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData)); } @catch (__unused id e) {}
    }
}

static void ApolloPFReloadTableNodeOfVC(id vc) {
    ApolloPFReloadTableNode(ApolloObjectIvar(vc, "tableNode"));
}

#pragma mark - Cell hooks

%hook _TtC6Apollo17LargePostCellNode
- (id)layoutSpecThatFits:(struct ApolloPFSizeRange)constrainedSize {
    BOOL hide = ApolloPFCellShouldHide(self);
    ApolloPFUpdateHiddenRow(self, hide);
    if (hide) {
        id empty = ApolloPFEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloPFSizeRange)constrainedSize {
    BOOL hide = ApolloPFCellShouldHide(self);
    ApolloPFUpdateHiddenRow(self, hide);
    if (hide) {
        id empty = ApolloPFEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

// Collapse the separator trailing a hidden post. calculateLayoutThatFits: is
// where ThickSeparatorCellNode bakes its 8pt height, so it owns the decision
// for the pass; layoutSpecThatFits: only follows that recorded decision.
// (Composes with Community Highlights' hooks on the same class — both call
// %orig, and either wanting to collapse wins.)
%hook _TtC6Apollo22ThickSeparatorCellNode
- (id)calculateLayoutThatFits:(struct ApolloPFSizeRange)constrainedSize {
    BOOL collapse = ApolloPFSeparatorShouldCollapse(self);
    ApolloPFSetNodeCollapsed(self, collapse);
    if (!collapse) return %orig;
    id layout = %orig;
    if (layout) {
        CGSize s = ((CGSize (*)(id, SEL))objc_msgSend)(layout, @selector(size));
        if (s.height > 0.0) {
            Class ASLayoutCls = ApolloClassASLayout;
            if (ASLayoutCls) {
                id zero = ((id (*)(id, SEL, id, CGSize))objc_msgSend)(ASLayoutCls, @selector(layoutWithLayoutElement:size:), self, CGSizeMake(s.width, 0.0));
                if (zero) return zero;
            }
        }
    }
    return layout;
}
- (id)layoutSpecThatFits:(struct ApolloPFSizeRange)constrainedSize {
    // calculateLayoutThatFits: already decided this pass under the same node
    // lock. Re-checking the hidden rows here can disagree when the post
    // publishes in between, leaving the flag collapsed on an 8pt layout.
    if (ApolloPFNodeIsCollapsed(self)) {
        id empty = ApolloPFEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
- (void)didEnterPreloadState {
    %orig;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloPFRefreshSeparatorNode(weakSelf);
    });
}
- (void)didEnterDisplayState {
    %orig;
    ApolloPFRefreshSeparatorNode(self);
}
%end

// Main queue only. Ask the post node that sits above this separator right now
// instead of the row-keyed set: hiding a post deletes its two rows, which shifts
// every row below it while the set still holds the old row numbers.
static BOOL ApolloPFSeparatorShouldCollapseOnMain(id separatorNode) {
    if (!ApolloPFFiltersConfigured()) return NO;
    id owning = ApolloPFOwningTableNode(separatorNode);
    NSIndexPath *postPath = ApolloPFPostPathForSeparatorPath(ApolloPFNodeIndexPath(separatorNode));
    SEL nodeSelector = @selector(nodeForRowAtIndexPath:);
    if (!owning || !postPath || ![owning respondsToSelector:nodeSelector]) return NO;
    id postNode = ((id (*)(id, SEL, id))objc_msgSend)(owning, nodeSelector, postPath);
    Class postClass = [postNode class];
    BOOL hidden = (postClass == ApolloClassLargePostCellNode ||
                   postClass == ApolloClassCompactPostCellNode) &&
                  ApolloPFCellShouldHide(postNode);
    // Put this row back in step so the next off-main measurement agrees with
    // the current table geometry rather than a pre-deletion index path.
    @synchronized(owning) {
        NSMutableSet *set = ApolloPFHiddenRowsSet(owning, hidden);
        if (hidden) [set addObject:[postPath copy]];
        else [set removeObject:postPath];
    }
    return hidden;
}

static void ApolloPFRefreshSeparatorNode(id separatorNode) {
    if (!separatorNode) return;
    BOOL changed = ApolloPFSetNodeCollapsed(separatorNode,
                                            ApolloPFSeparatorShouldCollapseOnMain(separatorNode));
    if (!changed) return;
    if ([separatorNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(separatorNode, @selector(invalidateCalculatedLayout));
    }
    if ([separatorNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(separatorNode, @selector(setNeedsLayout));
    }
}

// Re-measure a feed on appearance if filters changed since it last laid out.
%hook _TtC6Apollo19PostsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!ApolloPFFiltersConfigured()) return;
    NSNumber *applied = objc_getAssociatedObject(self, kApolloPFAppliedGenKey);
    objc_setAssociatedObject(self, kApolloPFAppliedGenKey, @(sApolloPFGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // First appearance under the current generation already measured with the live
    // rules; only force a re-measure when the generation actually advanced.
    if (applied && applied.intValue != sApolloPFGeneration) {
        ApolloPFReloadTableNodeOfVC(self);
    }
}
%end

#pragma mark - Search filtering
//
// The name-substring filter should hide matching subreddits in search too. Two
// screens show subreddits:
//   • _TtC6Apollo20SearchViewController — the as-you-type suggestion list. Rows are
//     bare ApolloDefaultTableViewCell whose textLabel is the subreddit name (the
//     "Posts with …"/"Go to User …" action rows always contain spaces). Self-sizing
//     table, no heightForRow.
//   • _TtC6Apollo36SubredditSearchResultsViewController — the full "Subreddits with
//     X" results page. Rows are SubredditSearchResultTableViewCell backed by a Swift
//     [RDKSubreddit] array; it implements heightForRowAtIndexPath:.
//
// We must NOT change row COUNTS: this screen performs animated row insert/delete as
// you type, and a filtered numberOfRows desyncs UITableView's batch-update invariant
// (→ "invalid number of rows" exception). Instead we collapse a blocked row to 0pt
// height, leaving counts/indices identical to Apollo's. Gated on having name filters,
// so there is zero overhead otherwise.

// A fresh, invisible, 0-height cell used to collapse a blocked row in a self-sizing
// table without touching row counts.
static UITableViewCell *ApolloPFMakeCollapsedCell(void) {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.backgroundColor = [UIColor clearColor];
    c.contentView.backgroundColor = [UIColor clearColor];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.userInteractionEnabled = NO;
    c.separatorInset = UIEdgeInsetsMake(0, 100000, 0, 0); // push the separator off-screen
    NSLayoutConstraint *h = [c.contentView.heightAnchor constraintEqualToConstant:0.0];
    h.priority = UILayoutPriorityRequired - 1;
    h.active = YES;
    return c;
}

// The bare subreddit name shown by a search cell (subredditLabel for results cells,
// textLabel for suggestion cells), or nil if the row isn't a hide-able subreddit
// (e.g. a "Posts with …" action row — those contain whitespace; names never do).
static NSString *ApolloPFSubredditNameFromSearchCell(UITableViewCell *cell) {
    NSString *name = nil;
    SEL sel = @selector(subredditLabel);
    if ([cell respondsToSelector:sel]) {
        id l = ((id (*)(id, SEL))objc_msgSend)(cell, sel);
        if ([l isKindOfClass:[UILabel class]]) name = [(UILabel *)l text];
    }
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = cell.textLabel.text;
    if (![name isKindOfClass:[NSString class]]) return nil;
    NSString *t = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return nil;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return nil; // action row
    if ([t hasPrefix:@"r/"] || [t hasPrefix:@"R/"]) t = [t substringFromIndex:2];
    return t;
}

// Suggestion list: collapse a blocked suggestion's cell (self-sizing → 0pt). Counts
// untouched.
%hook _TtC6Apollo20SearchViewController
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = %orig;
    if (sPostFilterNameSubstrings.count == 0) return cell;
    NSString *name = ApolloPFSubredditNameFromSearchCell(cell);
    if (name && ApolloPFSubredditNameBlocked(name)) return ApolloPFMakeCollapsedCell();
    return cell;
}
%end

// Full "Subreddits with X" results page: data is a Swift [RDKSubreddit] (ObjC
// objects, safely readable) and the VC sets explicit row heights, so collapse via
// heightForRow (which runs before cellForRow) and hide the cell content too.
static BOOL ApolloPFResultsRowBlocked(id vc, NSIndexPath *ip) {
    if (!ip || ip.section != 0) return NO;
    @try {
        id arr = ApolloObjectIvar(vc, "subreddits");
        if (![arr isKindOfClass:[NSArray class]]) return NO;
        NSArray *subs = (NSArray *)arr;
        if (ip.row < 0 || ip.row >= (NSInteger)subs.count) return NO;
        id sub = subs[(NSUInteger)ip.row];
        Class subCls = ApolloClassRDKSubreddit;
        if (!subCls || ![sub isMemberOfClass:subCls] || ![sub respondsToSelector:@selector(name)]) return NO;
        NSString *name = ((NSString *(*)(id, SEL))objc_msgSend)(sub, @selector(name));
        return ApolloPFSubredditNameBlocked(name);
    } @catch (__unused id e) {
        return NO;
    }
}

%hook _TtC6Apollo36SubredditSearchResultsViewController
- (double)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (sPostFilterNameSubstrings.count > 0 && ApolloPFResultsRowBlocked(self, ip)) return 0.0;
    return %orig;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = %orig;
    if (sPostFilterNameSubstrings.count > 0) {
        BOOL blocked = ApolloPFResultsRowBlocked(self, ip);
        cell.hidden = blocked;          // explicit both ways so reused cells reset
        cell.contentView.hidden = blocked;
    }
    return cell;
}
%end

#pragma mark - Constructor

%ctor {
    %init(_TtC6Apollo17LargePostCellNode = objc_getClass("_TtC6Apollo17LargePostCellNode"),
          _TtC6Apollo19CompactPostCellNode = objc_getClass("_TtC6Apollo19CompactPostCellNode"),
          _TtC6Apollo22ThickSeparatorCellNode = objc_getClass("_TtC6Apollo22ThickSeparatorCellNode"),
          _TtC6Apollo19PostsViewController = objc_getClass("_TtC6Apollo19PostsViewController"),
          _TtC6Apollo20SearchViewController = objc_getClass("_TtC6Apollo20SearchViewController"),
          _TtC6Apollo36SubredditSearchResultsViewController = objc_getClass("_TtC6Apollo36SubredditSearchResultsViewController"));

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloPostFiltersChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        sApolloPFGeneration++;
        ApolloPFRefreshVisibleFeeds();
    }];
}
