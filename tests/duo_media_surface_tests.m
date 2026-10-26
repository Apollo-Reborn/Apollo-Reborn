#import <AppKit/AppKit.h>

// The shipping code is written against UIKit. NSView has the same anchors,
// superview.constraints, window and settable nextResponder, and
// NSLayoutConstraint is the real Auto Layout engine, so the constraint
// handling below runs unmodified.
#define UIView NSView
@interface UIViewController : NSResponder
@property(nonatomic, strong) NSView *viewIfLoaded;
@end
@implementation UIViewController @end
@interface UINavigationController : UIViewController @end
@implementation UINavigationController @end
@interface ApolloDuoSplitState : NSObject
@property(nonatomic, weak) UINavigationController *outer;
@property(nonatomic, strong) NSObject *split;
@property(nonatomic, strong) UINavigationController *primary, *secondary, *feed;
@end
@implementation ApolloDuoSplitState @end

static ApolloDuoSplitState *gState;
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, BOOL create) {
    (void)nav; (void)create;
    return gState;
}
#define ApolloLog(...) do {} while (0)

static NSUInteger checks, failures;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}

// INCLUDE_PRODUCTION_MEDIA_SURFACE

static UINavigationController *Navigation(void) {
    UINavigationController *nav = [UINavigationController new];
    nav.viewIfLoaded = [NSView new];
    return nav;
}

static NSWindow *Window(void) {
    return [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                       styleMask:0 backing:NSBackingStoreBuffered defer:YES];
}

// One window holding the split (outer navigation view with a 400pt feed column)
// and Apollo's loading view, edged to the feed column as Apollo does it.
@interface Scene : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) UINavigationController *outer, *feed;
@property(nonatomic, strong) NSView *outerView, *column, *loading;
@end
@implementation Scene
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _window = Window();
    NSView *root = _window.contentView;
    _outer = Navigation();
    _outerView = _outer.viewIfLoaded;
    _outerView.frame = root.bounds;
    [root addSubview:_outerView];
    _outerView.nextResponder = _outer;
    _feed = Navigation();
    _column = _feed.viewIfLoaded;
    _column.frame = NSMakeRect(0, 0, 400, 600);
    [_outerView addSubview:_column];
    _column.nextResponder = _feed;
    gState = [ApolloDuoSplitState new];
    gState.outer = _outer;
    gState.split = [NSObject new];
    gState.feed = _feed;
    _loading = [NSView new];
    _loading.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_loading];
    return self;
}
- (NSArray<NSLayoutConstraint *> *)edgesTo:(NSView *)view {
    [self.window.contentView layoutSubtreeIfNeeded];
    NSMutableArray *edges = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in self.loading.superview.constraints)
        if (constraint.active && constraint.firstItem == self.loading && constraint.secondItem == view)
            [edges addObject:constraint];
    return edges;
}
- (void)pinTo:(NSView *)view sides:(NSUInteger)sides {
    NSArray *all = @[
        [self.loading.topAnchor constraintEqualToAnchor:view.topAnchor],
        [self.loading.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.loading.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.loading.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:[all subarrayWithRange:NSMakeRange(0, sides)]];
}
- (void)layout { [self.window.contentView layoutSubtreeIfNeeded]; }
@end

int main(void) { @autoreleasepool {
    // The surface decision.
    UINavigationController *outer = Navigation();
    ApolloDuoSplitState *state = [ApolloDuoSplitState new];
    state.outer = outer;
    state.split = [NSObject new];
    state.primary = Navigation();
    state.secondary = Navigation();
    state.feed = Navigation();
    NSView *split = outer.viewIfLoaded;
    Check(ApolloDuoSplitMediaSurface(state, state.feed) == split, @"a video from the feed column covers the whole split");
    Check(ApolloDuoSplitMediaSurface(state, state.secondary) == split, @"a video from the thread column covers the whole split");
    Check(ApolloDuoSplitMediaSurface(state, state.primary) == split, @"a video from the sidebar covers the whole split");
    Check(!ApolloDuoSplitMediaSurface(state, outer), @"the whole split is already the right surface");
    Check(!ApolloDuoSplitMediaSurface(state, Navigation()), @"a navigation controller outside the split is unchanged");
    Check(!ApolloDuoSplitMediaSurface(nil, state.feed), @"a navigation controller without split state is unchanged");
    state.split = nil;
    Check(!ApolloDuoSplitMediaSurface(state, state.feed), @"without the split the opener's own view is the screen");
    state.split = [NSObject new];
    outer.viewIfLoaded = nil;
    Check(!ApolloDuoSplitMediaSurface(state, state.feed), @"an unloaded tab view is never pinned to");

    // The re-pin, on real Auto Layout.
    @autoreleasepool {
        Scene *scene = [Scene new];
        [scene pinTo:scene.column sides:4];
        [scene layout];
        Check(NSEqualRects(scene.loading.frame, scene.column.frame), @"before the re-pin the loading view fills only the column");
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:scene.column].count == 0, @"the column edges are gone");
        Check([scene edgesTo:scene.outerView].count == 4, @"four edges now name the whole split");
        Check(NSEqualRects(scene.loading.frame, scene.outerView.frame), @"the loading view fills the whole split");
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:scene.outerView].count == 4 && [scene edgesTo:scene.column].count == 0,
              @"a second pass keeps exactly the four split edges");
        Check(NSEqualRects(scene.loading.frame, scene.outerView.frame), @"the frame is unchanged after a second pass");
    }
    @autoreleasepool {
        Scene *scene = [Scene new];
        [scene pinTo:scene.column sides:4];
        gState.split = nil;
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:scene.column].count == 4, @"folded: the loading view stays on the opener's view");
    }
    @autoreleasepool {
        Scene *scene = [Scene new];
        [scene pinTo:scene.column sides:3];
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:scene.column].count == 3 && [scene edgesTo:scene.outerView].count == 0,
              @"three edges are not Apollo's layout and are left alone");
    }
    @autoreleasepool {
        Scene *scene = [Scene new];
        [scene pinTo:scene.column sides:2];
        [scene pinTo:scene.outerView sides:2];
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:scene.column].count == 2 && [scene edgesTo:scene.outerView].count == 2,
              @"edges to two different views are left alone");
    }
    @autoreleasepool {
        Scene *scene = [Scene new];
        [scene pinTo:scene.column sides:4];
        NSWindow *other = Window();
        NSView *elsewhere = [[NSView alloc] initWithFrame:other.contentView.bounds];
        [other.contentView addSubview:elsewhere];
        scene.outer.viewIfLoaded = elsewhere;
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:scene.column].count == 4, @"a split in another window is never pinned to");
    }
    @autoreleasepool {
        Scene *scene = [Scene new];
        UINavigationController *stranger = Navigation();
        stranger.viewIfLoaded.frame = NSMakeRect(0, 0, 300, 600);
        [scene.outerView addSubview:stranger.viewIfLoaded];
        stranger.viewIfLoaded.nextResponder = stranger;
        [scene pinTo:stranger.viewIfLoaded sides:4];
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:stranger.viewIfLoaded].count == 4 && [scene edgesTo:scene.outerView].count == 0,
              @"an opener outside the split is unchanged");
    }
    @autoreleasepool {
        Scene *scene = [Scene new];
        NSView *plain = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 600)];
        [scene.outerView addSubview:plain];
        [scene pinTo:plain sides:4];
        ApolloDuoSplitCoverYouTubeLoading(scene.loading);
        Check([scene edgesTo:plain].count == 4, @"edges to a view that is not a navigation controller's are unchanged");
    }

    printf("Duo media surface: %lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
