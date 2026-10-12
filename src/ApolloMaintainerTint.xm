#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <atomic>
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloTextureDecls.h"

// Extend Apollo's iamthatis tint to maintainers without changing model authors.

@interface ASButtonNode : ASDisplayNode
- (NSAttributedString *)attributedTitleForState:(UIControlState)state;
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state;
- (ASTextNode *)titleNode;
@end

@interface ApolloMaintainerByline : NSObject
@property (weak) id owner;
@property const char *modelIvar; // Static ivar-name literal.
@end
@implementation ApolloMaintainerByline
@end

static const void *kMaintainerByline = &kMaintainerByline;
static NSHashTable<ASButtonNode *> *sMaintainerButtons;
static std::atomic<NSInteger> sMaintainerAppStyle { UIUserInterfaceStyleLight };
// Main thread only; overlays can temporarily become key during theme changes.
static __weak UIWindow *sMaintainerAppWindow;
static BOOL sMaintainerRefreshScheduled;

static BOOL ApolloIsMaintainerUsername(NSString *username) {
    if (![username isKindOfClass:NSString.class]) return NO;
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *normalized = [NSMutableSet set];
        for (NSString *name in @[@"ClydeDroid", @"corderjones", @"DeltAndy",
                                @"iChopPryde", @"IllIIllIllIllII", @"musiquorum"]) {
            [normalized addObject:name.lowercaseString];
        }
        names = [normalized copy];
    });
    return [names containsObject:username.lowercaseString];
}

static NSString *ApolloMaintainerAuthor(id owner, const char *modelIvar) {
    id author = ApolloSendObject(ApolloObjectIvar(owner, modelIvar), @selector(author));
    return [author isKindOfClass:NSString.class] ? author : nil;
}

static void ApolloMaintainerCaptureStyle(void) {
    // Read on main: Texture nodes can retain stale traits after theme changes.
    UIWindow *window = sMaintainerAppWindow ?: ApolloKeyWindow() ?: ApolloAllWindows().firstObject;
    if (window) sMaintainerAppStyle.store(window.traitCollection.userInterfaceStyle);
}

static UIColor *ApolloMaintainerColor(void) {
    static UIColor *light, *dark;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep read posts at full strength.
        light = ApolloColorFromHexString(@"4E28BE");
        dark = ApolloColorFromHexString(@"8C76D5");
    });
    return sMaintainerAppStyle.load() == UIUserInterfaceStyleDark ? dark : light;
}

static NSAttributedString *ApolloMaintainerTitle(id node, NSAttributedString *title) {
    ApolloMaintainerByline *byline = objc_getAssociatedObject(node, kMaintainerByline);
    id owner = byline.owner;
    if (!owner || ![title isKindOfClass:NSAttributedString.class] || !title.length) return title;
    NSString *author = ApolloMaintainerAuthor(owner, byline.modelIvar);
    if (!ApolloIsMaintainerUsername(author)) return title;

    // Match a full username; leave badges and censored placeholders untouched.
    NSRange range = [title.string rangeOfString:author options:NSCaseInsensitiveSearch];
    if (range.location == NSNotFound) return title;
    static NSCharacterSet *usernameCharacters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        usernameCharacters = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    });
    if ((range.location && [usernameCharacters characterIsMember:[title.string characterAtIndex:range.location - 1]]) ||
        (NSMaxRange(range) < title.length && [usernameCharacters characterIsMember:[title.string characterAtIndex:NSMaxRange(range)]])) return title;

    // Match Apollo's "by" tint across avatars, whitespace and optional "u/".
    NSUInteger prefixEnd = range.location;
    BOOL separated = NO;
    for (NSUInteger pass = 0; pass < 2; pass++) {
        NSUInteger start = prefixEnd;
        while (prefixEnd > 0) {
            NSUInteger index = prefixEnd - 1;
            if (![NSCharacterSet.whitespaceCharacterSet characterIsMember:[title.string characterAtIndex:index]] &&
                ![title attribute:NSAttachmentAttributeName atIndex:index effectiveRange:NULL]) break;
            prefixEnd--;
        }
        separated = prefixEnd < start;
        if (pass == 0 && prefixEnd >= 2 &&
            [[title.string substringWithRange:NSMakeRange(prefixEnd - 2, 2)] caseInsensitiveCompare:@"u/"] == NSOrderedSame) {
            prefixEnd -= 2;
        } else break;
    }
    NSRange ranges[2] = { range, NSMakeRange(NSNotFound, 0) };
    if (separated && prefixEnd >= 2 &&
        [[title.string substringWithRange:NSMakeRange(prefixEnd - 2, 2)] caseInsensitiveCompare:@"by"] == NSOrderedSame &&
        (prefixEnd == 2 || ![usernameCharacters characterIsMember:[title.string characterAtIndex:prefixEnd - 3]])) {
        ranges[1] = NSMakeRange(prefixEnd - 2, 2);
    }

    UIColor *color = ApolloMaintainerColor();
    __block NSMutableAttributedString *updated = nil;
    for (NSRange tintRange : ranges) {
        if (tintRange.location == NSNotFound) continue;
        [title enumerateAttribute:NSForegroundColorAttributeName inRange:tintRange options:0
                      usingBlock:^(id value, NSRange run, BOOL *stop) {
            if (![value isEqual:color]) {
                if (!updated) updated = [title mutableCopy];
                [updated addAttribute:NSForegroundColorAttributeName value:color range:run];
            }
        }];
    }
    return updated ?: title;
}

static void ApolloMaintainerRefreshButton(ASButtonNode *button) {
    ApolloMaintainerByline *byline = objc_getAssociatedObject(button, kMaintainerByline);
    ASTextNode *textNode = button.titleNode;
    objc_setAssociatedObject(textNode, kMaintainerByline, byline, OBJC_ASSOCIATION_RETAIN);
    // Save rendered text first: updating stored titles can discard
    // avatars written directly to titleNode.
    NSAttributedString *renderedText = textNode.attributedText;
    for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                              @(UIControlStateSelected), @(UIControlStateDisabled)]) {
        NSAttributedString *title = [button attributedTitleForState:state.unsignedIntegerValue];
        NSAttributedString *updated = ApolloMaintainerTitle(button, title);
        if (updated != title) [button setAttributedTitle:updated forState:state.unsignedIntegerValue];
    }
    NSAttributedString *updated = ApolloMaintainerTitle(textNode, renderedText);
    if (updated.length && ![updated isEqualToAttributedString:textNode.attributedText]) textNode.attributedText = updated;
}

static void ApolloMaintainerBind(id owner, const char *modelIvar, const char *buttonIvar) {
    if (!ApolloIsMaintainerUsername(ApolloMaintainerAuthor(owner, modelIvar))) return;
    ASButtonNode *button = ApolloObjectIvar(owner, buttonIvar);
    if (![button respondsToSelector:@selector(attributedTitleForState:)] ||
        ![button respondsToSelector:@selector(titleNode)]) return;
    if (NSThread.isMainThread) ApolloMaintainerCaptureStyle();

    ApolloMaintainerByline *byline = objc_getAssociatedObject(button, kMaintainerByline);
    if (byline.owner != owner || byline.modelIvar != modelIvar) {
        byline = [ApolloMaintainerByline new];
        byline.owner = owner;
        byline.modelIvar = modelIvar;
        objc_setAssociatedObject(button, kMaintainerByline, byline, OBJC_ASSOCIATION_RETAIN);
        @synchronized (sMaintainerButtons) { [sMaintainerButtons addObject:button]; }
    }
    ApolloMaintainerRefreshButton(button);
}

static void ApolloMaintainerRefresh(void) {
    ApolloMaintainerCaptureStyle();
    NSArray<ASButtonNode *> *buttons;
    @synchronized (sMaintainerButtons) { buttons = sMaintainerButtons.allObjects; }
    for (ASButtonNode *button in buttons) ApolloMaintainerRefreshButton(button);
}

static void ApolloMaintainerScheduleRefresh(void) {
    if (sMaintainerRefreshScheduled) return;
    sMaintainerRefreshScheduled = YES;
    // Defer until native title rewrites finish; read the latest window traits.
    dispatch_async(dispatch_get_main_queue(), ^{
        sMaintainerRefreshScheduled = NO;
        ApolloMaintainerRefresh();
    });
}

static void ApolloMaintainerWindowAppearanceChanged(UIWindow *window) {
    sMaintainerAppWindow = window;
    NSInteger previous = sMaintainerAppStyle.load();
    ApolloMaintainerCaptureStyle();
    if (previous != sMaintainerAppStyle.load()) {
        ApolloLog(@"MaintainerTint: window appearance changed to %@; refreshing bylines",
                  sMaintainerAppStyle.load() == UIUserInterfaceStyleDark ? @"dark" : @"light");
    }
    ApolloMaintainerScheduleRefresh();
}

// Window traits cover appearance changes that theme notifications miss.
// Hooking the inherited override setter would bypass FloatingTabs' later
// UIWindow hook with the internal Logos generator.
%hook _TtC6Apollo15ThemeableWindow
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (previousTraitCollection.userInterfaceStyle != ((UIWindow *)self).traitCollection.userInterfaceStyle) {
        ApolloMaintainerWindowAppearanceChanged((UIWindow *)self);
    }
}
%end

%hook ASButtonNode
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    %orig(ApolloMaintainerTitle(self, title), state);
}
%end

%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    %orig(ApolloMaintainerTitle(self, text));
}
%end

%hook ASTextNode2
- (void)setAttributedText:(NSAttributedString *)text {
    %orig(ApolloMaintainerTitle(self, text));
}
%end

// Bind before measurement: Swift creates titles before the supernode chain.
// Keep this pass color-only to avoid layout loops.
%hook _TtC6Apollo12PostInfoNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)size {
    ApolloMaintainerBind(self, "link", "authorButtonNode");
    return %orig;
}
- (void)readCommentsUpdatedWithNotification:(id)notification {
    %orig;
    // Keep the tint after Apollo's read-state repaint.
    ApolloMaintainerBind(self, "link", "authorButtonNode");
}
%end

%hook _TtC6Apollo15CommentCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)size {
    ApolloMaintainerBind(self, "comment", "authorNode");
    return %orig;
}
%end

%hook _TtC6Apollo13InboxCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)size {
    ApolloMaintainerBind(self, "message", "authorButtonNode");
    return %orig;
}
%end

%ctor {
    sMaintainerButtons = [NSHashTable weakObjectsHashTable];
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification,
                                     UIApplicationDidBecomeActiveNotification,
                                     @"com.christianselig.ApolloSpecificThemeChanged",
                                     @"com.christianselig.CommentsColorThemeChanged"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *notification) {
            ApolloMaintainerScheduleRefresh();
        }];
    }
    %init;
    ApolloLog(@"MaintainerTint: hooks installed for six maintainer bylines");
}
