// Comment sort on URL-scheme post opens
//
// Report: "Subreddit default post sort not being respected" — a post whose subreddit sets its
// suggested sort to New opens on New from the subreddit feed but on the user's Default Sort
// from a Community Highlights card. (r/ApolloReborn, 1wd7fhf.)
//
// WHAT BREAKS (RE'd from the binary)
// Apollo builds CommentsViewController two ways. A feed tap uses init(link:), which computes
// the initial comment sort from the RDKLink it is handed:
//     link.suggestedSort   (unless Settings > General > Comments > Ignore Suggested Sort)
//       -> Remember Subreddit Sort's per-subreddit memory
//       -> Default Sort
// Every apollo:// open uses init(linkID:commentID:subreddit:context:...) instead — that is how
// the Highlights carousel, Recently Read, Floating Tabs, AI-summary links, inbox/notification
// taps and deep links from other apps all open posts. There is no RDKLink yet, so that init can
// only choose the per-subreddit memory (when the URL carried a subreddit) or Default Sort, and
// nothing revisits the choice once the post arrives: in the whole binary `suggestedSort` is
// read by init(link:) and the sort menu only, never by loadComments() or its completion.
// "Remember Post Sort" (ApolloPerPostCommentSort.xm) has the matching gap — its viewDidLoad
// write needs `link` to look the post up — so it never applied to URL opens either.
//
// THE FIX
// The first comments fetch of a link-less CommentsViewController is
// -[RDKClient linkAndCommentsForLinkWithIdentifier:commentSort:pagination:completion:] with
// the bare post id, issued synchronously from viewDidLoad. We wrap that completion. When the
// response's link asks for a different sort than the one Apollo fetched with — evaluated with
// the same chain init(link:) uses, per-post memory on top — we write currentSort, re-issue the
// identical fetch with the corrected sort, and hand THAT response to Apollo's completion.
// Apollo renders once, already on the right sort; the second round-trip only happens when the
// two sorts differ. viewDidLoad already drew the nav-bar sort icon from the pre-fetch sort, so
// we redraw it the way Apollo's own updater does (option-sort-<name> asset + "Sort by <name>"
// accessibility label). If the corrected fetch fails, the first response is delivered as-is
// and the sort is put back so the icon never disagrees with the list.
//
// Out of scope on purpose: comment-permalink opens (a specific comment with context) go
// through -linkAndContext:forCommentWithIdentifier:linkIdentifier:commentSort:... and keep
// Apollo's behavior — that screen is about one comment, not the thread's ordering.
//
// RE notes (Apollo 1.15.11):
// - init(link:) = sub_100725044, init(linkID:...) = sub_100722458, loadComments = sub_100722d24
//   (its "No sort set, setting to top" fallback runs BEFORE the fetch, so currentSort is always
//   set by the time the RDKClient call is made), sort-icon updater = sub_1006feeb4.
// - The RDKClient method wraps the caller's completion in a 2-argument block and calls it on
//   the main queue: completion(@{ @"link": RDKLink, ... }, nil) on success, completion(nil,
//   error) on failure (sub_100039680 / sub_100039788).
// - RDKCommentSortingMethod raws: 1 Top, 2 Best, 3 New, 4 Q&A, 5 Controversial, 6 Old,
//   7 Random, 8 Live Update; 9 is RDKLink.suggestedSort's "none". Live goes to the network
//   as New, exactly as loadComments sends it.
// - DefaultCommentsSort is a string ("top"/"best"/"new"/"qa"/"controversial"/"old"/"random",
//   anything else = Top); RedditCommentsSortMapping is { lowercased subreddit: raw }.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloPerPostCommentSort.h"
#import "ApolloState.h"
#import "ApolloSwiftRuntime.h"
#import "UserDefaultConstants.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

@interface RDKClient : NSObject
- (id)linkAndCommentsForLinkWithIdentifier:(id)identifier commentSort:(long long)sort pagination:(id)pagination completion:(id)completion;
@end

// Apollo's own Settings > General > Comments keys. Read here, never written.
static NSString *const kUCSKeyIgnoreSuggestedSort = @"IgnoreSuggestedSort";
static NSString *const kUCSKeyDefaultCommentsSort = @"DefaultCommentsSort";
static NSString *const kUCSKeySubredditSortMapping = @"RedditCommentsSortMapping";

enum : int64_t {
    UCSSortTop = 1, UCSSortBest = 2, UCSSortNew = 3, UCSSortQA = 4, UCSSortControversial = 5,
    UCSSortOld = 6, UCSSortRandom = 7, UCSSortLive = 8, UCSSortNone = 9,
};

static BOOL UCSIsRealSort(int64_t raw) { return raw >= UCSSortTop && raw <= UCSSortLive; }

// MARK: - Apollo's sort chain, evaluated from the fetched link

// Default Sort, the same way sub_100441058 reads it: a lowercase string, unknown/missing = Top.
static int64_t UCSDefaultSortRaw(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kUCSKeyDefaultCommentsSort];
    NSString *name = [value isKindOfClass:[NSString class]] ? value : nil;
    if ([name isEqualToString:@"best"]) return UCSSortBest;
    if ([name isEqualToString:@"new"]) return UCSSortNew;
    if ([name isEqualToString:@"qa"]) return UCSSortQA;
    if ([name isEqualToString:@"controversial"]) return UCSSortControversial;
    if ([name isEqualToString:@"old"]) return UCSSortOld;
    if ([name isEqualToString:@"random"]) return UCSSortRandom;
    return UCSSortTop;
}

// Remember Subreddit Sort's memory for a subreddit (sub_10044395c): 0 when nothing is stored.
static int64_t UCSRememberedSubredditSort(NSString *subreddit) {
    if (subreddit.length == 0) return 0;
    NSDictionary *map = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUCSKeySubredditSortMapping];
    NSNumber *raw = [map isKindOfClass:[NSDictionary class]] ? map[subreddit.lowercaseString] : nil;
    return [raw isKindOfClass:[NSNumber class]] ? raw.longLongValue : 0;
}

static NSString *UCSStringProperty(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// The sort init(link:) would have picked for this link, with "Remember Post Sort" on top the
// way its pre-viewDidLoad write beats the chain on feed opens. `reason` names the winning rule.
static int64_t UCSDesiredSort(id link, NSString *postID, NSString **reason) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (sPerPostCommentSort) {
        int64_t saved = ApolloPerPostCommentSortSavedSort(postID);
        if (saved >= UCSSortTop && saved <= UCSSortRandom) {   // Live is never stored
            *reason = @"Remember Post Sort";
            return saved;
        }
    }
    if ([link respondsToSelector:@selector(suggestedSort)]) {
        int64_t suggested = ((int64_t (*)(id, SEL))objc_msgSend)(link, @selector(suggestedSort));
        if (UCSIsRealSort(suggested) && ![defaults boolForKey:kUCSKeyIgnoreSuggestedSort]) {
            *reason = @"suggested sort";
            return suggested;
        }
    }
    if ([defaults boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        int64_t remembered = UCSRememberedSubredditSort(UCSStringProperty(link, @selector(subreddit)));
        if (UCSIsRealSort(remembered)) {
            *reason = @"Remember Subreddit Sort";
            return remembered;
        }
    }
    *reason = @"Default Sort";
    return UCSDefaultSortRaw();
}

// MARK: - nav-bar sort icon (mirrors sub_1006feeb4)

static NSString *UCSSortAssetName(int64_t raw) {
    switch (raw) {
        case UCSSortTop: return @"option-sort-top";
        case UCSSortBest: return @"option-sort-best";
        case UCSSortNew: return @"option-sort-new";
        case UCSSortQA: return @"option-sort-qa";
        case UCSSortControversial: return @"option-sort-controversial";
        case UCSSortOld: return @"option-sort-old";
        case UCSSortRandom: return @"option-sort-random";
        case UCSSortLive: return @"option-sort-live";
        default: return nil;
    }
}

static NSString *UCSSortAccessibilityLabel(int64_t raw) {
    switch (raw) {
        case UCSSortTop: return @"Sort by top";
        case UCSSortBest: return @"Sort by best";
        case UCSSortNew: return @"Sort by new";
        case UCSSortQA: return @"Sort by Q and A";
        case UCSSortControversial: return @"Sort by controversial";
        case UCSSortOld: return @"Sort by old";
        case UCSSortRandom: return @"Sort by random";
        case UCSSortLive: return @"Sort by live update";
        default: return @"Sort by none";
    }
}

// Apollo's updater sets the image + accessibility label and resets the alpha/transform/
// animations its Live pulse leaves behind. We never start the pulse (a Live suggested sort is
// as rare as it gets and the live timer only runs from the menu anyway), so a plain reset is
// the whole job. Goes through UIButton's setter so the Liquid Glass item strip's re-templating
// hook sees the change like it sees Apollo's own.
static void UCSRedrawSortButton(id vc, int64_t raw) {
    Ivar ivar = class_getInstanceVariable(object_getClass(vc), "sortBarButtonItem");
    UIButton *button = ivar ? object_getIvar(vc, ivar) : nil;
    if (![button isKindOfClass:[UIButton class]]) return;
    NSString *asset = UCSSortAssetName(raw);
    UIImage *image = asset ? [UIImage imageNamed:asset] : nil;
    if (asset && !image) {
        ApolloLog(@"[URLOpenSort] sort icon asset %@ missing; leaving the icon alone", asset);
        return;
    }
    [button setImage:image forState:UIControlStateNormal];
    button.accessibilityLabel = UCSSortAccessibilityLabel(raw);
    button.alpha = 1.0;
    button.transform = CGAffineTransformIdentity;
    [button.layer removeAllAnimations];
}

// MARK: - completion plumbing

// The RDKClient completion is a Swift closure bridged to an ObjC block. Read its signature
// off the block descriptor so a shape we did not RE (a future 3-argument completion) makes us
// step aside instead of calling it with too few arguments.
struct UCSBlockDescriptor { unsigned long reserved; unsigned long size; void *rest[]; };
struct UCSBlockLiteral { void *isa; int flags; int reserved; void *invoke; struct UCSBlockDescriptor *descriptor; };
enum { UCSBlockHasCopyDispose = 1 << 25, UCSBlockHasSignature = 1 << 30 };

static NSString *UCSBlockSignature(id block) {
    struct UCSBlockLiteral *literal = (__bridge struct UCSBlockLiteral *)block;
    if (!literal || !(literal->flags & UCSBlockHasSignature) || !literal->descriptor) return nil;
    const char *types = (const char *)literal->descriptor->rest[(literal->flags & UCSBlockHasCopyDispose) ? 2 : 0];
    return types ? @(types) : nil;
}

// YES for `void (^)(id, id)`. A block without a signature cannot be checked; the RE'd shape
// is trusted then (both clang and Swift normally emit one).
static BOOL UCSCompletionIsTwoObjectBlock(id block) {
    NSString *signature = UCSBlockSignature(block);
    if (!signature) return YES;
    @try {
        NSMethodSignature *ms = [NSMethodSignature signatureWithObjCTypes:signature.UTF8String];
        return ms.numberOfArguments == 3
            && [ms getArgumentTypeAtIndex:1][0] == '@'
            && [ms getArgumentTypeAtIndex:2][0] == '@';
    } @catch (NSException *exception) {
        return NO;
    }
}

// The RDKLink out of a success result (@{ @"link": ..., ... }); nil for anything else.
static id UCSLinkFromResult(id result) {
    if (![result isKindOfClass:[NSDictionary class]]) return nil;
    id link = ((NSDictionary *)result)[@"link"];
    return [link respondsToSelector:@selector(suggestedSort)] ? link : nil;
}

// MARK: - hooks
//
// The arm: the link-less CommentsViewController whose first comments fetch we want to see,
// keyed by its post id (the `linkID` Swift String ivar — the very identifier loadComments
// hands RDKClient). viewDidLoad arms it; the RDKClient hook consumes it on the first
// main-thread fetch for that id. Normally that fetch is issued synchronously inside
// viewDidLoad. With "Remember Subreddit Sort" on and a URL that named no subreddit, Apollo
// first resolves the post (linkWithFullName:) to learn its subreddit and only then fetches
// the comments, so the arm has to survive that gap — keyed by id, a fetch for any other
// post passes straight through. The arm is dropped when its VC disappears (popped before
// its load, cancelled interactive pop), replaced by the next link-less viewDidLoad, and
// touched on the main thread only. Two live CommentsViewControllers for the same post id,
// one of them still waiting on that deferred fetch, is the one case the id cannot tell
// apart; the VC we act on is always the armed one (weakly held), never the fetch's caller.

static __weak id sUCSArmedVC = nil;
static NSString *sUCSArmedPostID = nil;

static void UCSDisarm(void) {
    sUCSArmedVC = nil;
    sUCSArmedPostID = nil;
}

// Bare post id ("1abcde"): loadComments passes the linkID ivar through as-is, but be
// tolerant of a fullname in either place.
static NSString *UCSBarePostID(NSString *identifier) {
    return [identifier hasPrefix:@"t3_"] ? [identifier substringFromIndex:3] : identifier;
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    if (!ApolloCommentsVCLink(self)) {   // URL-scheme / inbox open: no RDKLink until the first fetch returns
        NSString *postID = UCSBarePostID(ApolloReadSwiftStringIvar(self, "linkID"));
        NSString *commentID = ApolloReadSwiftStringIvar(self, "commentID");
        if (commentID.length) {
            // Comment permalink (context) open: loads through linkAndContext:..., which we
            // leave alone — so no arm, nothing to linger.
            ApolloLog(@"[URLOpenSort] %@: comment permalink open; leaving it to Apollo", postID ?: @"?");
        } else if (postID.length) {
            if (sUCSArmedPostID) ApolloLog(@"[URLOpenSort] replacing the arm for %@ (it never fetched)", sUCSArmedPostID);
            sUCSArmedVC = self;
            sUCSArmedPostID = [postID copy];
        } else {
            ApolloLog(@"[URLOpenSort] link-less open without a post id; leaving it to Apollo");
        }
    }
    %orig;
    if (sUCSArmedVC == self) ApolloLog(@"[URLOpenSort] %@: fetch deferred past viewDidLoad; arm kept", sUCSArmedPostID);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (sUCSArmedVC == self || !sUCSArmedVC) UCSDisarm();
}

%end

%hook RDKClient

- (id)linkAndCommentsForLinkWithIdentifier:(id)identifier commentSort:(long long)commentSort pagination:(id)pagination completion:(id)completion {
    // Arm state lives on the main thread (viewDidLoad and the fetches loadComments issues);
    // a fetch from any other thread can never be the one we are waiting for.
    if (![NSThread isMainThread] || !sUCSArmedPostID) return %orig;
    if (![identifier isKindOfClass:[NSString class]] ||
        ![sUCSArmedPostID isEqualToString:UCSBarePostID(identifier)]) return %orig;   // another post's fetch; arm kept
    id vc = sUCSArmedVC;
    UCSDisarm();   // one shot
    if (!vc || !completion) return %orig;
    if (!UCSCompletionIsTwoObjectBlock(completion)) {
        ApolloLog(@"[URLOpenSort] unexpected completion signature %@; leaving the fetch alone", UCSBlockSignature(completion));
        return %orig;
    }

    int64_t preRaw = 0;
    if (!ApolloCommentsVCReadCurrentSort(vc, &preRaw)) preRaw = commentSort;
    NSString *postID = [identifier copy];
    __weak id weakVC = vc;
    RDKClient *client = self;
    void (^original)(id, id) = [completion copy];
    ApolloLog(@"[URLOpenSort] link-less open of %@ fetching on %@ (net %lld, block %@)",
              postID, ApolloCommentSortName(preRaw), commentSort, UCSBlockSignature(completion) ?: @"unsigned");

    void (^wrapped)(id, id) = ^(id result, id error) {
        id strongVC = weakVC;
        id link = UCSLinkFromResult(result);
        if (error || !link || !strongVC) {
            original(result, error);
            return;
        }
        int64_t nowRaw = 0;
        if (!ApolloCommentsVCReadCurrentSort(strongVC, &nowRaw) || nowRaw != preRaw) {
            // The user picked a sort while the load was in flight; Apollo already re-fetched.
            ApolloLog(@"[URLOpenSort] %@: sort changed to %@ while loading; not touching it", postID, ApolloCommentSortName(nowRaw));
            original(result, error);
            return;
        }
        NSString *reason = nil;
        int64_t desired = UCSDesiredSort(link, postID, &reason);
        if (desired == preRaw) {
            ApolloLog(@"[URLOpenSort] %@: %@ already matches %@", postID, ApolloCommentSortName(preRaw), reason);
            original(result, error);
            return;
        }
        if (!ApolloCommentsVCWriteCurrentSort(strongVC, desired)) {
            ApolloLog(@"[URLOpenSort] %@: could not write currentSort; leaving %@", postID, ApolloCommentSortName(preRaw));
            original(result, error);
            return;
        }
        UCSRedrawSortButton(strongVC, desired);
        long long netSort = desired == UCSSortLive ? UCSSortNew : desired;
        ApolloLog(@"[URLOpenSort] %@: %@ -> %@ (%@), refetching", postID,
                  ApolloCommentSortName(preRaw), ApolloCommentSortName(desired), reason);
        [client linkAndCommentsForLinkWithIdentifier:postID commentSort:netSort pagination:pagination completion:^(id result2, id error2) {
            if (error2 || !UCSLinkFromResult(result2)) {
                // Corrected fetch failed: show the first response, and put the sort back so the
                // icon and menu describe the comments that are actually on screen.
                id vc2 = weakVC;
                if (vc2 && ApolloCommentsVCWriteCurrentSort(vc2, preRaw)) UCSRedrawSortButton(vc2, preRaw);
                ApolloLog(@"[URLOpenSort] %@: refetch on %@ failed (%@); showing the %@ response",
                          postID, ApolloCommentSortName(desired), [error2 isKindOfClass:[NSError class]] ? ((NSError *)error2).localizedDescription : @"no link",
                          ApolloCommentSortName(preRaw));
                original(result, error);
                return;
            }
            ApolloLog(@"[URLOpenSort] %@: delivered %@ comments", postID, ApolloCommentSortName(desired));
            original(result2, error2);
        }];
    };
    return %orig(identifier, commentSort, pagination, (id)wrapped);
}

%end

%ctor {
    %init;
    ApolloLog(@"[URLOpenSort] ctor: hooks installed (CommentsViewController.viewDidLoad, RDKClient.linkAndCommentsForLinkWithIdentifier:commentSort:pagination:completion:)");
}
