// Host-side checks for keeping videos playing through a Duo fold/unfold
// (ApolloDuoResumeVideosAfterMove in src/ApolloDuoSplitView.xm). Covers both of
// Apollo's player paths: shareable v.redd.it video, whose ASVideoNode.player is
// nil while the playing player lives at playerLayer.player, and the direct path
// (GIF/Giphy/Streamable) that plays through the node's own player.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static unsigned sChecks, sFailures;
static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) { sFailures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}

static void ApolloLog(NSString *format, ...) { (void)format; }

@interface FixturePlayerItem : NSObject
@end
@implementation FixturePlayerItem
@end

@interface FixturePlayer : NSObject
@property(nonatomic) float rate;
@property(nonatomic, strong) FixturePlayerItem *currentItem;
@property(nonatomic) NSUInteger playCalls;
- (void)play;
@end
@implementation FixturePlayer
- (void)play { self.playCalls++; self.rate = 1; }
@end

@interface FixtureLayer : NSObject
@end
@implementation FixtureLayer
@end

@interface FixturePlayerLayer : FixtureLayer
@property(nonatomic, strong) FixturePlayer *player;
@end
@implementation FixturePlayerLayer
@end

@interface FixtureView : NSObject
@property(nonatomic, strong) NSMutableArray<FixtureView *> *subviews;
@property(nonatomic, strong) id window;
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic) double alpha;
@property(nonatomic, weak) id node;
- (id)asyncdisplaykit_node;
@end
@implementation FixtureView
- (instancetype)init {
    if ((self = [super init])) { _subviews = [NSMutableArray array]; _alpha = 1; }
    return self;
}
- (id)asyncdisplaykit_node { return self.node; }
@end

@interface FixtureController : NSObject
@property(nonatomic, strong) FixtureView *viewIfLoaded;
@end
@implementation FixtureController
@end

// The class the production code looks up by name.
@interface ASVideoNode : NSObject
@property(nonatomic, strong) FixtureView *view;
@property(nonatomic, strong) FixturePlayerLayer *playerLayer;
@property(nonatomic, strong) FixturePlayer *player;
@property(nonatomic) NSUInteger nodePlayCalls;
- (void)play;
@end
@implementation ASVideoNode
- (void)play { self.nodePlayCalls++; [self.player play]; }
@end

static dispatch_block_t sScheduled;
static void FixtureDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when; (void)queue;
    sScheduled = block;
}

#define AVPlayer FixturePlayer
#define AVPlayerItem FixturePlayerItem
#define AVPlayerLayer FixturePlayerLayer
#define CALayer FixtureLayer
#define UIView FixtureView
#define UIViewController FixtureController
#define dispatch_after FixtureDispatchAfter
// INCLUDE_PRODUCTION_FOLD_PLAYBACK
#undef AVPlayer
#undef AVPlayerItem
#undef AVPlayerLayer
#undef CALayer
#undef UIView
#undef UIViewController
#undef dispatch_after

typedef NS_ENUM(NSInteger, Path) { PathShared, PathDirect };

// A thread page with one playing video on `path`, hosted in a window.
static ASVideoNode *PlayingNode(Path path, FixtureController **outController) {
    FixturePlayer *player = [FixturePlayer new];
    player.currentItem = [FixturePlayerItem new];
    player.rate = 1;
    ASVideoNode *node = [ASVideoNode new];
    node.playerLayer = [FixturePlayerLayer new];
    if (path == PathShared) node.playerLayer.player = player;
    else node.player = player;
    FixtureView *root = [FixtureView new];
    FixtureView *videoView = [FixtureView new];
    root.window = videoView.window = @"window";
    videoView.node = node;
    node.view = videoView;
    [root.subviews addObject:videoView];
    FixtureController *controller = [FixtureController new];
    controller.viewIfLoaded = root;
    *outController = controller;
    return node;
}

static FixturePlayer *PlayerOf(ASVideoNode *node) { return node.playerLayer.player ?: node.player; }

// Fold: capture, the rebuild pauses the player, then the delayed resume runs.
static BOOL FoldAndResume(FixtureController *controller, ASVideoNode *node, void (^afterPause)(void)) {
    sScheduled = nil;
    ApolloDuoResumeVideosAfterMove(@[ (id)controller ]);
    PlayerOf(node).rate = 0;   // Apollo pauses it as the page "disappears"
    if (afterPause) afterPause();
    if (!sScheduled) return NO;
    sScheduled();
    return YES;
}

int main(void) {
    @autoreleasepool {
        for (Path path = PathShared; path <= PathDirect; path++) {
            NSString *name = path == PathShared ? @"shareable (playerLayer.player)" : @"direct (node.player)";
            FixtureController *controller = nil;
            ASVideoNode *node = PlayingNode(path, &controller);
            FixturePlayer *player = PlayerOf(node);
            Check(FoldAndResume(controller, node, nil),
                  [NSString stringWithFormat:@"%@: a playing video is captured and its resume scheduled", name]);
            Check(player.rate > 0, [NSString stringWithFormat:@"%@: the captured player plays again", name]);
            if (path == PathShared) {
                Check(player.playCalls == 1 && node.nodePlayCalls == 0,
                      @"shareable: resumes the layer's player directly (the node has no player of its own)");
            } else {
                Check(node.nodePlayCalls == 1, @"direct: resumes through the node, keeping ASVideoNode's state in step");
            }

            node = PlayingNode(path, &controller);
            Check(FoldAndResume(controller, node, ^{ PlayerOf(node).currentItem = [FixturePlayerItem new]; })
                  && PlayerOf(node).rate == 0,
                  [NSString stringWithFormat:@"%@: a player that moved on to other content is left alone", name]);

            node = PlayingNode(path, &controller);
            FixturePlayer *original = PlayerOf(node);
            Check(FoldAndResume(controller, node, ^{
                      FixturePlayer *other = [FixturePlayer new];
                      other.currentItem = [FixturePlayerItem new];
                      if (path == PathShared) node.playerLayer.player = other; else node.player = other;
                  }) && original.rate == 0 && original.playCalls == 0 && PlayerOf(node).playCalls == 0,
                  [NSString stringWithFormat:@"%@: a node that now holds another player is left alone", name]);

            node = PlayingNode(path, &controller);
            Check(FoldAndResume(controller, node, ^{ node.view.window = nil; }) && PlayerOf(node).rate == 0,
                  [NSString stringWithFormat:@"%@: a video no longer on screen is left alone", name]);

            node = PlayingNode(path, &controller);
            Check(FoldAndResume(controller, node, ^{ node.view.hidden = YES; }) && PlayerOf(node).rate == 0,
                  [NSString stringWithFormat:@"%@: a hidden video is left alone", name]);

            node = PlayingNode(path, &controller);
            player = PlayerOf(node);
            Check(FoldAndResume(controller, node, ^{ player.rate = 1; }) && player.playCalls == 0,
                  [NSString stringWithFormat:@"%@: a video already playing again is not re-sent play", name]);

            node = PlayingNode(path, &controller);
            PlayerOf(node).rate = 0;
            sScheduled = nil;
            ApolloDuoResumeVideosAfterMove(@[ (id)controller ]);
            Check(sScheduled == nil, [NSString stringWithFormat:@"%@: a paused video schedules nothing", name]);
        }

        FixtureController *offscreen = nil;
        ASVideoNode *node = PlayingNode(PathShared, &offscreen);
        offscreen.viewIfLoaded.window = nil;
        sScheduled = nil;
        ApolloDuoResumeVideosAfterMove(@[ (id)offscreen ]);
        Check(sScheduled == nil && node, @"a page that is not in a window is not scanned");
    }
    if (sFailures) { fprintf(stderr, "%u of %u checks failed\n", sFailures, sChecks); return 1; }
    printf("OK: %u fold playback checks\n", sChecks);
    return 0;
}
