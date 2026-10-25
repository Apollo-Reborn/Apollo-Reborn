#import <Foundation/Foundation.h>

// Host-side doubles for the UIKit pieces the closed-Duo More wrapper touches.
// ApolloActionsArmFoldedRows itself is extracted verbatim by the runner.
typedef NS_OPTIONS(NSUInteger, UIControlEvents) { UIControlEventTouchUpInside = 1 << 6 };

@interface UIImage : NSObject
@end
@implementation UIImage
@end
@interface UIMenuElement : NSObject
@end
@implementation UIMenuElement
@end
@interface UIAction : UIMenuElement
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
typedef NS_OPTIONS(NSUInteger, UIMenuOptions) { UIMenuOptionsDisplayInline = 1 << 0 };
@interface UIMenu : UIMenuElement
@property (nonatomic, copy) NSArray *children;
@property (nonatomic, copy) NSString *identifier;
+ (UIMenu *)menuWithTitle:(NSString *)title image:(UIImage *)image identifier:(NSString *)identifier options:(UIMenuOptions)options children:(NSArray *)children;
- (UIMenu *)menuByReplacingChildren:(NSArray *)children;
@end
@implementation UIMenu
+ (UIMenu *)menuWithTitle:(__unused NSString *)title image:(__unused UIImage *)image identifier:(NSString *)identifier options:(__unused UIMenuOptions)options children:(NSArray *)children {
    UIMenu *menu = [UIMenu new];
    menu.identifier = identifier;
    menu.children = children;
    return menu;
}
- (UIMenu *)menuByReplacingChildren:(NSArray *)children {
    UIMenu *menu = [UIMenu new];
    menu.children = children;
    return menu;
}
@end
@interface UIDeferredMenuElement : UIMenuElement
@property (nonatomic, copy) void (^provider)(void (^)(NSArray *));
+ (instancetype)elementWithUncachedProvider:(void (^)(void (^)(NSArray *)))provider;
@end
@implementation UIDeferredMenuElement
+ (instancetype)elementWithUncachedProvider:(void (^)(void (^)(NSArray *)))provider {
    UIDeferredMenuElement *element = [self new];
    element.provider = provider;
    return element;
}
@end
@interface UINavigationItem : NSObject
@end
@implementation UINavigationItem
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

@interface ApolloActionsDuoFoldedRow : NSObject
@property (nonatomic, weak) UIButton *button;
@end
@implementation ApolloActionsDuoFoldedRow
@end

static NSString *const kActionsDuoFoldedSectionIdentifier = @"ApolloReborn.duo-rail.folded";
static NSArray<ApolloActionsDuoFoldedRow *> *sDuoFoldedRows;
static __weak UIBarButtonItem *sDuoFoldedAnchor;
static CFAbsoluteTime sDuoFoldedArmedAt;
static NSUInteger sFoldedSends;
static __weak UIButton *sLastFoldedSend;
static __weak UINavigationItem *sLastRowsNavItem;

// One row per folded button, as production builds them (titles aside).
static NSArray<ApolloActionsDuoFoldedRow *> *ApolloActionsDuoFoldedRows(NSArray<UIButton *> *folded, UINavigationItem *navItem) {
    sLastRowsNavItem = navItem;
    NSMutableArray *rows = [NSMutableArray array];
    for (UIButton *button in folded) {
        ApolloActionsDuoFoldedRow *row = [ApolloActionsDuoFoldedRow new];
        row.button = button;
        [rows addObject:row];
    }
    return rows;
}
static UIMenuElement *ApolloActionsDuoFoldedRowElement(ApolloActionsDuoFoldedRow *row, void (^open)(UIButton *)) {
    __weak UIButton *weakButton = row.button;
    return (UIMenuElement *)[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__unused UIAction *action) {
        open(weakButton);
    }];
}
static void ApolloActionsSendFoldedButton(UIButton *button, __unused UIBarButtonItem *anchor) {
    sFoldedSends++;
    sLastFoldedSend = button;
}

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
        UIButton *sort = [UIButton new];
        UIButton *moreButton = [UIButton new];
        UINavigationItem *navItem = [UINavigationItem new];
        NSArray<UIButton *> *folded = @[ moderator, sort ];

        // Building the item alone (no tap) must not keep a popped page alive:
        // page → More item → primaryAction → page was the cycle.
        __weak QAPage *weakPage;
        __weak UIBarButtonItem *weakMore;
        @autoreleasepool {
            QAPage *page = Page();
            weakPage = page;
            weakMore = page.more;
            ApolloActionsArmFoldedRows(page.more, moreButton, folded, navItem);
            Check(page.more.primaryAction != nil, @"wrapper installs a primaryAction");
            page = nil;
        }
        Check(weakPage == nil, @"discarding the page releases it");
        Check(weakMore == nil, @"discarding the page releases its More item");

        // The wrapper holds the folded buttons weakly: a popped strip's
        // buttons are released even while its More item survives.
        @autoreleasepool {
            QAPage *page = Page();
            __weak UIButton *weakFolded;
            @autoreleasepool {
                UIButton *transient = [UIButton new];
                weakFolded = transient;
                ApolloActionsArmFoldedRows(page.more, moreButton, @[ transient ], navItem);
            }
            Check(weakFolded == nil, @"wrapper doesn't retain folded buttons");
            page.more.primaryAction.handler(page.more.primaryAction);
            Check(sDuoFoldedRows.count == 0, @"released buttons arm no rows");
        }

        // Normal forwarding: arms one row per folded button, in order, and
        // sends the native More action from the visible item.
        @autoreleasepool {
            QAPage *page = Page();
            ApolloActionsArmFoldedRows(page.more, moreButton, folded, navItem);
            UIAction *wrapper = page.more.primaryAction;
            wrapper.handler(wrapper);
            Check(page.moreTaps == 1, @"tap forwards to the original target/action");
            Check(page.lastSender == page.more, @"forwarded sender is the More item");
            Check(sDuoFoldedRows.count == 2, @"tap arms a row per folded button");
            Check(sDuoFoldedRows[0].button == moderator && sDuoFoldedRows[1].button == sort, @"rows keep the rail order");
            Check(sLastRowsNavItem == navItem, @"rows are built for this page's item (globe lookup)");
            Check(sDuoFoldedAnchor == page.more, @"tap arms the More anchor");
            Check(sDuoFoldedArmedAt > 0, @"tap records when it armed");
            Check(moreButton.taps == 0, @"target path doesn't also tap the button");
        }

        // A surviving action whose page went away does nothing rather than
        // falling through to the button or a nil-target responder send.
        @autoreleasepool {
            UIAction *wrapper;
            NSUInteger sends = UIApplication.sharedApplication.sends;
            @autoreleasepool {
                QAPage *page = Page();
                ApolloActionsArmFoldedRows(page.more, moreButton, folded, navItem);
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
            ApolloActionsArmFoldedRows(more, moreButton, folded, navItem);
            more.primaryAction.handler(more.primaryAction);
            Check(moreButton.taps == 1, @"targetless More taps its button");
        }

        // A UIMenu-backed More is led by a deferred section of rows instead of
        // a wrapper, built each time the menu opens.
        @autoreleasepool {
            UIBarButtonItem *more = [UIBarButtonItem new];
            more.menu = [UIMenu new];
            more.menu.children = @[ [UIAction new] ];
            ApolloActionsArmFoldedRows(more, moreButton, folded, navItem);
            Check(more.menu.children.count == 2 && more.primaryAction == nil, @"menu-backed More gains one leading element");
            UIDeferredMenuElement *deferred = more.menu.children.firstObject;
            Check([deferred isKindOfClass:UIDeferredMenuElement.class], @"leading element is deferred");
            __block NSArray *provided;
            deferred.provider(^(NSArray *elements) { provided = elements; });
            UIMenu *section = provided.firstObject;
            Check(provided.count == 1 && [section.identifier isEqualToString:kActionsDuoFoldedSectionIdentifier],
                  @"deferred element provides the folded section");
            Check(section.children.count == 2, @"section has a row per folded button");
            UIAction *row = section.children.lastObject;
            row.handler(row);
            Check(sFoldedSends == 1 && sLastFoldedSend == sort, @"a row sends its own button");
        }
    }
    printf("duo folded rows lifecycle tests passed (%lu checks)\n", (unsigned long)checks);
    return 0;
}
