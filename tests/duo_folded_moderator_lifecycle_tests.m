#import <Foundation/Foundation.h>

// Host-side doubles for the UIKit pieces the closed-Duo More wrapper touches.
// ApolloActionsArmFoldedModerator itself is extracted verbatim by the runner.
typedef NS_OPTIONS(NSUInteger, UIControlEvents) { UIControlEventTouchUpInside = 1 << 6 };

@interface UIImage : NSObject
@end
@implementation UIImage
@end
@interface UIAction : NSObject
@property (nonatomic, copy) void (^handler)(UIAction *);
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(NSString *)identifier handler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(__unused NSString *)title image:(__unused UIImage *)image identifier:(__unused NSString *)identifier handler:(void (^)(UIAction *))handler {
    UIAction *action = [self new];
    action.handler = handler;
    return action;
}
@end
@interface UIMenu : NSObject
@property (nonatomic, copy) NSArray *children;
- (UIMenu *)menuByReplacingChildren:(NSArray *)children;
@end
@implementation UIMenu
- (UIMenu *)menuByReplacingChildren:(NSArray *)children {
    UIMenu *menu = [UIMenu new];
    menu.children = children;
    return menu;
}
@end
@interface UIButton : NSObject
@property (nonatomic) NSUInteger taps;
- (void)sendActionsForControlEvents:(UIControlEvents)events;
@end
@implementation UIButton
- (void)sendActionsForControlEvents:(__unused UIControlEvents)events { self.taps++; }
@end
@interface UIBarButtonItem : NSObject
@property (nonatomic, weak) id target; // UIKit's target is weak too
@property (nonatomic) SEL action;
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic, strong) UIAction *primaryAction;
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic, strong) UIImage *image;
@end
@implementation UIBarButtonItem
@end

@interface QAPage : NSObject
@property (nonatomic, strong) UIBarButtonItem *more;
@property (nonatomic) NSUInteger moreTaps;
@property (nonatomic, weak) id lastSender;
- (void)moreTapped:(id)sender;
@end
@implementation QAPage
- (void)moreTapped:(id)sender {
    self.moreTaps++;
    self.lastSender = sender;
}
@end

@interface UIApplication : NSObject
@property (class, nonatomic, readonly) UIApplication *sharedApplication;
@property (nonatomic) NSUInteger sends;
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(id)event;
@end
@implementation UIApplication
+ (UIApplication *)sharedApplication {
    static UIApplication *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [UIApplication new]; });
    return shared;
}
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(__unused id)event {
    self.sends++;
    ((void (*)(id, SEL, id))[target methodForSelector:action])(target, action, sender);
    return YES;
}
@end

static __weak UIButton *sDuoFoldedModerator;
static __weak UIBarButtonItem *sDuoFoldedModeratorAnchor;
static CFAbsoluteTime sDuoFoldedModeratorArmedAt;
static NSUInteger sModeratorOpens;
static UIImage *ApolloActionsFoldedModeratorIcon(void) { return nil; }
static void ApolloActionsOpenFoldedModerator(__unused UIButton *moderator, __unused UIBarButtonItem *anchor) { sModeratorOpens++; }

// INCLUDE_PRODUCTION_ARM

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static QAPage *Page(void) NS_RETURNS_RETAINED;
static QAPage *Page(void) {
    QAPage *page = [QAPage new];
    page.more = [UIBarButtonItem new];
    page.more.target = page;
    page.more.action = @selector(moreTapped:);
    return page;
}

int main(void) {
    @autoreleasepool {
        UIButton *moderator = [UIButton new];
        UIButton *moreButton = [UIButton new];

        // Building the item alone (no tap) must not keep a popped page alive:
        // page → More item → primaryAction → page was the cycle.
        __weak QAPage *weakPage;
        __weak UIBarButtonItem *weakMore;
        @autoreleasepool {
            QAPage *page = Page();
            weakPage = page;
            weakMore = page.more;
            ApolloActionsArmFoldedModerator(page.more, moreButton, moderator);
            Check(page.more.primaryAction != nil, @"wrapper installs a primaryAction");
            page = nil;
        }
        Check(weakPage == nil, @"discarding the page releases it");
        Check(weakMore == nil, @"discarding the page releases its More item");

        // Normal forwarding: arms the fold and sends the native More action
        // from the visible item.
        @autoreleasepool {
            QAPage *page = Page();
            ApolloActionsArmFoldedModerator(page.more, moreButton, moderator);
            UIAction *wrapper = page.more.primaryAction;
            wrapper.handler(wrapper);
            Check(page.moreTaps == 1, @"tap forwards to the original target/action");
            Check(page.lastSender == page.more, @"forwarded sender is the More item");
            Check(sDuoFoldedModerator == moderator, @"tap arms the folded Moderator");
            Check(sDuoFoldedModeratorAnchor == page.more, @"tap arms the More anchor");
            Check(sDuoFoldedModeratorArmedAt > 0, @"tap records when it armed");
            Check(moreButton.taps == 0, @"target path doesn't also tap the button");
        }

        // A surviving action whose page went away does nothing rather than
        // falling through to the button or a nil-target responder send.
        @autoreleasepool {
            UIAction *wrapper;
            NSUInteger sends = UIApplication.sharedApplication.sends;
            @autoreleasepool {
                QAPage *page = Page();
                ApolloActionsArmFoldedModerator(page.more, moreButton, moderator);
                wrapper = page.more.primaryAction;
                page = nil;
            }
            wrapper.handler(wrapper);
            Check(UIApplication.sharedApplication.sends == sends, @"released target isn't sent to");
            Check(moreButton.taps == 0, @"released target doesn't fall back to the button");
        }

        // An item with no target/action still forwards through its button.
        @autoreleasepool {
            UIBarButtonItem *more = [UIBarButtonItem new];
            ApolloActionsArmFoldedModerator(more, moreButton, moderator);
            more.primaryAction.handler(more.primaryAction);
            Check(moreButton.taps == 1, @"targetless More taps its button");
        }

        // A UIMenu-backed More gets the row appended instead of a wrapper.
        @autoreleasepool {
            UIBarButtonItem *more = [UIBarButtonItem new];
            more.menu = [UIMenu new];
            more.menu.children = @[ [UIAction new] ];
            ApolloActionsArmFoldedModerator(more, moreButton, moderator);
            Check(more.menu.children.count == 2 && more.primaryAction == nil, @"menu-backed More appends Moderator");
            UIAction *row = more.menu.children.lastObject;
            row.handler(row);
            Check(sModeratorOpens == 1, @"appended row opens Moderator");
        }
    }
    printf("duo folded moderator lifecycle tests passed (%lu checks)\n", (unsigned long)checks);
    return 0;
}
