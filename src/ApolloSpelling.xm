// British spelling: rewrites American words in UI chrome text as it is set.
//
// Only setters that carry interface text are hooked (labels, buttons, navigation/tab/bar items,
// alerts, menus, segmented controls, list content configurations). Reddit content is drawn by
// Texture text nodes, which are left alone, so posts and comments keep their author's spelling.
// Tweak labels that show Reddit content in UIKit (subreddit and profile headers, Community
// Highlights cards, link previews) opt out via ApolloSpellingSetExcluded, and so do the places
// Apollo shows subreddit names (feed titles, the title quick-switcher, the subreddit list). Words attached to "/",
// "@", "#" or "." (r/colors, u/FavoriteUser, colors.com) are skipped, and American mode returns
// before doing any work.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloSpelling.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"

static ApolloSpellingStyle sSpellingStyle = ApolloSpellingStyleAmerican;

// American -> British, lowercase. Only words whose British form is unambiguous in UI text.
static NSDictionary<NSString *, NSString *> *SpellingMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"favorite": @"favourite", @"favorites": @"favourites", @"favorited": @"favourited",
            @"favoriting": @"favouriting", @"unfavorite": @"unfavourite", @"unfavorited": @"unfavourited",
            @"favor": @"favour", @"favors": @"favours", @"favorable": @"favourable",
            @"color": @"colour", @"colors": @"colours", @"colored": @"coloured", @"coloring": @"colouring",
            @"colorful": @"colourful", @"colorize": @"colourise", @"colorized": @"colourised",
            @"colorblind": @"colourblind",
            @"behavior": @"behaviour", @"behaviors": @"behaviours",
            @"center": @"centre", @"centers": @"centres", @"centered": @"centred", @"centering": @"centring",
            @"gray": @"grey", @"grays": @"greys", @"grayscale": @"greyscale",
            @"customize": @"customise", @"customized": @"customised", @"customizes": @"customises",
            @"customizing": @"customising", @"customization": @"customisation",
            @"customizations": @"customisations",
            @"organize": @"organise", @"organized": @"organised", @"reorganize": @"reorganise",
            @"recognize": @"recognise", @"recognized": @"recognised",
            @"personalize": @"personalise", @"personalized": @"personalised",
            @"personalization": @"personalisation",
            @"prioritize": @"prioritise", @"prioritized": @"prioritised",
            @"minimize": @"minimise", @"minimized": @"minimised",
            @"maximize": @"maximise", @"maximized": @"maximised",
            @"optimize": @"optimise", @"optimized": @"optimised", @"optimization": @"optimisation",
            @"summarize": @"summarise", @"summarized": @"summarised", @"summarizes": @"summarises",
            @"summarizing": @"summarising", @"summarization": @"summarisation",
            @"categorize": @"categorise", @"categorized": @"categorised",
            @"analyze": @"analyse", @"analyzed": @"analysed", @"analyzing": @"analysing",
            @"canceled": @"cancelled", @"canceling": @"cancelling",
            @"labeled": @"labelled", @"labeling": @"labelling",
            @"honor": @"honour", @"honors": @"honours", @"honored": @"honoured",
            @"catalog": @"catalogue", @"catalogs": @"catalogues",
            @"theater": @"theatre",
        };
    });
    return map;
}

// British -> American, for ApolloSpellingCanonical.
static NSDictionary<NSString *, NSString *> *CanonicalMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *inverse = [NSMutableDictionary dictionary];
        [SpellingMap() enumerateKeysAndObjectsUsingBlock:^(NSString *american, NSString *british, BOOL *stop) {
            inverse[british] = american;
        }];
        map = [inverse copy];
    });
    return map;
}

static NSRegularExpression *WordRegex(NSArray<NSString *> *keys) {
    // Longest first so alternation never stops at a shorter prefix.
    NSArray *words = [keys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length > b.length ? NSOrderedAscending : a.length < b.length ? NSOrderedDescending : NSOrderedSame;
    }];
    NSString *pattern = [NSString stringWithFormat:@"(?<![\\w/@#.])(?:%@)(?![\\w/]|\\.\\w)",
                         [words componentsJoinedByString:@"|"]];
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                     options:NSRegularExpressionCaseInsensitive
                                                       error:NULL];
}

static NSRegularExpression *CanonicalRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = WordRegex(CanonicalMap().allKeys); });
    return regex;
}

static NSRegularExpression *SpellingRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = WordRegex(SpellingMap().allKeys); });
    return regex;
}

// Carries the matched word's case over: COLORS -> COLOURS, Colors -> Colours, colors -> colours.
static NSString *MatchCase(NSString *british, NSString *original) {
    if (original.length > 1 && [original isEqualToString:original.uppercaseString]) return british.uppercaseString;
    unichar first = [original characterAtIndex:0];
    if ([NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:first]) {
        return [[british substringToIndex:1].uppercaseString stringByAppendingString:[british substringFromIndex:1]];
    }
    return british;
}

// Long strings are body text, not chrome.
static const NSUInteger kSpellingMaxLength = 600;

static NSArray<NSTextCheckingResult *> *SpellingMatches(NSString *text) {
    if (sSpellingStyle != ApolloSpellingStyleBritish) return nil;
    if (![text isKindOfClass:NSString.class] || text.length < 3 || text.length > kSpellingMaxLength) return nil;
    NSArray *matches = [SpellingRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    return matches.count ? matches : nil;
}

static NSString *BritishFor(NSString *word) {
    NSString *british = SpellingMap()[word.lowercaseString];
    return british ? MatchCase(british, word) : word;
}

NSString *ApolloSpellingApply(NSString *text) {
    NSArray<NSTextCheckingResult *> *matches = SpellingMatches(text);
    if (!matches) return text;
    NSMutableString *result = [text mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        [result replaceCharactersInRange:match.range withString:BritishFor([text substringWithRange:match.range])];
    }
    return result;
}

NSString *ApolloSpellingCanonical(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length < 3 || text.length > kSpellingMaxLength) return text;
    NSArray<NSTextCheckingResult *> *matches = [CanonicalRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!matches.count) return text;
    NSMutableString *result = [text mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *word = [text substringWithRange:match.range];
        [result replaceCharactersInRange:match.range withString:MatchCase(CanonicalMap()[word.lowercaseString], word)];
    }
    return result;
}

static void CollectTables(UIView *view, UIView *except, Class textureTable, NSMutableArray<UITableView *> *out, int depth) {
    if (!view || view == except || depth > 12) return;
    if ([view isKindOfClass:UITableView.class] && !(textureTable && [view isKindOfClass:textureTable])) {
        [out addObject:(UITableView *)view];
        return;
    }
    for (UIView *sub in view.subviews) CollectTables(sub, except, textureTable, out, depth + 1);
}

static void CollectControllers(UIViewController *vc, NSMutableArray<UIViewController *> *out) {
    if (!vc || [out containsObject:vc]) return;
    [out addObject:vc];
    for (UIViewController *child in vc.childViewControllers) CollectControllers(child, out);
    // Tabs and navigation stacks that are off screen keep their loaded views out of the window.
    if ([vc isKindOfClass:UITabBarController.class]) {
        for (UIViewController *tab in ((UITabBarController *)vc).viewControllers) CollectControllers(tab, out);
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *pushed in ((UINavigationController *)vc).viewControllers) CollectControllers(pushed, out);
    }
    CollectControllers(vc.presentedViewController, out);
}

void ApolloSpellingReloadLoadedTables(UIView *except) {
    // Texture lists (feeds, comments) draw Reddit content and are never rewritten; reloading them
    // would only cost scroll position.
    Class textureTable = objc_getClass("ASTableView");
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) CollectControllers(window.rootViewController, controllers);
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    for (UIViewController *vc in controllers) {
        if (vc.isViewLoaded) CollectTables(vc.view, except, textureTable, tables, 0);
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (UITableView *table in tables) {
        if ([seen containsObject:table]) continue;
        [seen addObject:table];
        [table reloadData];
    }
    ApolloLog(@"[Spelling] reloaded %lu loaded table(s) for the new style", (unsigned long)seen.count);
}

static char kApolloSpellingExcludedKey;
// @[rewritten, original] for the last respelled set on a label or navigation item, so a later
// opt-out can put the original back.
static char kApolloSpellingRewriteKey;

static BOOL SpellingIsExcluded(id object) {
    return objc_getAssociatedObject(object, &kApolloSpellingExcludedKey) != nil;
}

// Puts the original back if the object still shows the respelled text from its last set.
static void SpellingRestoreOriginal(id object) {
    NSArray *rewrite = objc_getAssociatedObject(object, &kApolloSpellingRewriteKey);
    if (rewrite.count != 2) return;
    objc_setAssociatedObject(object, &kApolloSpellingRewriteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id rewritten = rewrite[0], original = rewrite[1];
    NSString *rewrittenText = [rewritten isKindOfClass:NSAttributedString.class] ? [rewritten string] : rewritten;
    if ([object isKindOfClass:UILabel.class]) {
        UILabel *label = object;
        if (![label.text isEqualToString:rewrittenText]) return;
        if ([original isKindOfClass:NSAttributedString.class]) label.attributedText = original;
        else label.text = original;
    } else if ([object isKindOfClass:UINavigationItem.class]) {
        UINavigationItem *item = object;
        if ([item.title isEqualToString:rewrittenText]) item.title = original;
    } else {
        return;
    }
    ApolloLog(@"[Spelling] restored original text on %@", NSStringFromClass([object class]));
}

void ApolloSpellingSetExcluded(id object, BOOL excluded) {
    if (!object) return;
    objc_setAssociatedObject(object, &kApolloSpellingExcludedKey, excluded ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A button passes its title on to its own label, so that label has to opt out too.
    if ([object isKindOfClass:UIButton.class]) ApolloSpellingSetExcluded(((UIButton *)object).titleLabel, excluded);
    if (excluded) SpellingRestoreOriginal(object);
}

// The style check comes first so American mode never reaches the associated-object lookup.
static BOOL SpellingSkips(id owner) {
    return sSpellingStyle != ApolloSpellingStyleBritish || SpellingIsExcluded(owner);
}

// Replaces word by word so each keeps the attributes of the run it sits in.
static NSAttributedString *ApolloSpellingApplyAttributed(NSAttributedString *text) {
    if (![text isKindOfClass:NSAttributedString.class]) return text;
    NSArray<NSTextCheckingResult *> *matches = SpellingMatches(text.string);
    if (!matches) return text;
    NSMutableAttributedString *result = [text mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        [result replaceCharactersInRange:match.range withString:BritishFor([text.string substringWithRange:match.range])];
    }
    return result;
}

// Text for an owner's setter: as given when excluded, otherwise in the current style. A respelled
// set is remembered so ApolloSpellingSetExcluded can undo it.
// (Logos can't parse a ternary inside %orig, hence these wrappers.)
static NSString *SpellingTextForOwner(id owner, NSString *text) {
    if (SpellingSkips(owner)) return text;
    NSString *result = ApolloSpellingApply(text);
    if (result != text) {
        objc_setAssociatedObject(owner, &kApolloSpellingRewriteKey, @[result, text], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return result;
}

static NSAttributedString *SpellingAttributedTextForOwner(id owner, NSAttributedString *text) {
    if (SpellingSkips(owner)) return text;
    NSAttributedString *result = ApolloSpellingApplyAttributed(text);
    if (result != text) {
        objc_setAssociatedObject(owner, &kApolloSpellingRewriteKey, @[result, text], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return result;
}

ApolloSpellingStyle ApolloSpellingCurrentStyle(void) {
    return sSpellingStyle;
}

void ApolloSpellingSetStyle(ApolloSpellingStyle style) {
    sSpellingStyle = style == ApolloSpellingStyleBritish ? ApolloSpellingStyleBritish : ApolloSpellingStyleAmerican;
    [NSUserDefaults.standardUserDefaults setInteger:sSpellingStyle forKey:UDKeySpellingStyle];
    ApolloLog(@"[Spelling] style -> %@", sSpellingStyle == ApolloSpellingStyleBritish ? @"British" : @"American");
}

%hook UILabel
- (void)setText:(NSString *)text { %orig(SpellingTextForOwner(self, text)); }
- (void)setAttributedText:(NSAttributedString *)text { %orig(SpellingAttributedTextForOwner(self, text)); }
%end

%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state { %orig(SpellingTextForOwner(self, title), state); }
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    %orig(SpellingAttributedTextForOwner(self, title), state);
}
%end

%hook UINavigationItem
- (void)setTitle:(NSString *)title { %orig(SpellingTextForOwner(self, title)); }
- (void)setBackButtonTitle:(NSString *)title { %orig(ApolloSpellingApply(title)); }
%end

%hook UIBarButtonItem
- (void)setTitle:(NSString *)title { %orig(ApolloSpellingApply(title)); }
%end

%hook UITabBarItem
- (void)setTitle:(NSString *)title { %orig(ApolloSpellingApply(title)); }
%end

%hook UIAlertController
- (void)setTitle:(NSString *)title { %orig(ApolloSpellingApply(title)); }
- (void)setMessage:(NSString *)message { %orig(ApolloSpellingApply(message)); }
%end

%hook UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(id)handler {
    return %orig(ApolloSpellingApply(title), style, handler);
}
%end

%hook UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(UIActionIdentifier)identifier handler:(id)handler {
    return %orig(ApolloSpellingApply(title), image, identifier, handler);
}
- (void)setTitle:(NSString *)title { %orig(ApolloSpellingApply(title)); }
%end

%hook UIMenu
+ (instancetype)menuWithTitle:(NSString *)title image:(UIImage *)image identifier:(UIMenuIdentifier)identifier options:(UIMenuOptions)options children:(NSArray *)children {
    return %orig(ApolloSpellingApply(title), image, identifier, options, children);
}
%end

%hook UISegmentedControl
- (void)setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment { %orig(ApolloSpellingApply(title), segment); }
- (void)insertSegmentWithTitle:(NSString *)title atIndex:(NSUInteger)segment animated:(BOOL)animated {
    %orig(ApolloSpellingApply(title), segment, animated);
}
%end

%hook UIListContentConfiguration
- (void)setText:(NSString *)text { %orig(ApolloSpellingApply(text)); }
- (void)setSecondaryText:(NSString *)text { %orig(ApolloSpellingApply(text)); }
%end

// Subreddit names are Reddit content too, and the feed title is also the slug Apollo and several
// modules (subreddit headers, Community Highlights, the switcher) read back to know which
// subreddit is open: respelling r/ColorBlind's title to "Colourblind" made them look up the
// wrong subreddit.
@interface ApolloSpellingPostsController : UIViewController @end
@interface ApolloSpellingJumpBar : UIView @end
@interface ApolloSpellingRedditListCell : UITableViewCell @end

static void SpellingExcludeLabels(UIView *view, int depth) {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UILabel.class]) {
            if (!SpellingIsExcluded(sub)) ApolloSpellingSetExcluded(sub, YES);
        } else {
            SpellingExcludeLabels(sub, depth + 1);
        }
    }
}

%group SpellingFeedTitle
%hook ApolloSpellingPostsController
// Every title write goes through the navigation item, so tagging it on access covers Apollo's own
// sets; a title respelled before the first access is put back.
- (UINavigationItem *)navigationItem {
    UINavigationItem *item = %orig;
    if (sSpellingStyle == ApolloSpellingStyleBritish && item && !SpellingIsExcluded(item)) {
        ApolloSpellingSetExcluded(item, YES);
    }
    return item;
}
%end
%end

%group SpellingJumpBar
%hook ApolloSpellingJumpBar
// The title quick-switcher: the subreddit name, its search field and name suggestions.
- (void)didMoveToWindow {
    %orig;
    UIView *jumpBar = (UIView *)self;
    if (jumpBar.window) SpellingExcludeLabels(jumpBar, 0);
}
%end
%end

%group SpellingRedditList
%hook ApolloSpellingRedditListCell
// Subreddit, multireddit and feed names in Apollo's subreddit list. The subtitle stays rewritable:
// it also carries Apollo's own text (multireddit descriptions opt out per set).
- (void)didMoveToWindow {
    %orig;
    UIView *cell = (UIView *)self;
    if (!cell.window) return;
    UILabel *title = ApolloObjectIvar(cell, "redditTitleLabel");
    if ([title isKindOfClass:UILabel.class] && !SpellingIsExcluded(title)) ApolloSpellingSetExcluded(title, YES);
}
%end
%end

%ctor {
    sSpellingStyle = [NSUserDefaults.standardUserDefaults integerForKey:UDKeySpellingStyle] == ApolloSpellingStyleBritish
        ? ApolloSpellingStyleBritish : ApolloSpellingStyleAmerican;
    %init;
    if (ApolloClassPostsViewController) %init(SpellingFeedTitle, ApolloSpellingPostsController = ApolloClassPostsViewController);
    if (ApolloClassJumpBar) %init(SpellingJumpBar, ApolloSpellingJumpBar = ApolloClassJumpBar);
    if (ApolloClassRedditListTableViewCell) %init(SpellingRedditList, ApolloSpellingRedditListCell = ApolloClassRedditListTableViewCell);
    ApolloLog(@"[Spelling] feed-name hooks: posts=%d jumpBar=%d redditList=%d", ApolloClassPostsViewController != Nil,
              ApolloClassJumpBar != Nil, ApolloClassRedditListTableViewCell != Nil);
    ApolloLog(@"[Spelling] hooks installed (style %@)", sSpellingStyle == ApolloSpellingStyleBritish ? @"British" : @"American");
}
