#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

@interface UIView : NSObject
@property (nonatomic) CGRect bounds;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic, copy) NSArray<UIView *> *subviews;
- (BOOL)pointInside:(CGPoint)point withEvent:(id)event;
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) _userInteractionEnabled = YES; return self; }
- (BOOL)pointInside:(CGPoint)point withEvent:(__unused id)event { return CGRectContainsPoint(self.bounds, point); }
@end

@interface UIColor : NSObject
+ (instancetype)clearColor;
@end
@implementation UIColor
+ (instancetype)clearColor { static UIColor *color; if (!color) color = [self new]; return color; }
@end
@interface UITableView : UIView
@property (nonatomic, strong) UIColor *sectionIndexColor;
@property (nonatomic, strong) UIColor *sectionIndexBackgroundColor;
@property (nonatomic, strong) UIColor *sectionIndexTrackingBackgroundColor;
@end
@implementation UITableView
@end
@interface UITableViewIndex : UIView
@end
@implementation UITableViewIndex
@end
static void ApolloSubredditIndexCaptureTableNativeState(__unused UITableView *table) {}
// INCLUDE_PRODUCTION_NATIVE_INDEX_POLICY
// INCLUDE_PRODUCTION_HIDE_NATIVE_INDEX

static BOOL duo;
static BOOL ApolloDeviceIsDuo(void) { return duo; }
// INCLUDE_PRODUCTION_GESTURE_WIDTH
@interface ApolloSubredditIndexOverlayView : UIView
@property (nonatomic, copy) NSArray<NSString *> *titles;
- (NSInteger)indexForPoint:(CGPoint)point;
@end
@implementation ApolloSubredditIndexOverlayView
// INCLUDE_PRODUCTION_POINT_INSIDE
// INCLUDE_PRODUCTION_INDEX_FOR_POINT
@end

static unsigned checks;
static void Check(BOOL condition, const char *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        ApolloSubredditIndexOverlayView *index = [ApolloSubredditIndexOverlayView new];
        index.bounds = CGRectMake(0, 0, 56, 442);
        duo = YES;
        // Measured on the 466pt Duo front display: index origin x=331,
        // visible favorite icon x=339..359, index glyph center x=377.
        for (CGFloat windowX = 339; windowX < 359; windowX++) {
            Check(![index pointInside:CGPointMake(windowX - 331, 170) withEvent:nil],
                  "visible favorite icon must not be covered by letter-index hit testing");
        }
        for (CGFloat windowX = 353; windowX <= 365; windowX += 4) {
            Check(![index pointInside:CGPointMake(windowX - 331, 170) withEvent:nil],
                  "scrolling beside the letters must reach the table rather than start an index scrub");
        }
        Check([index pointInside:CGPointMake(46, 10) withEvent:nil], "top index glyph remains tappable");
        Check([index pointInside:CGPointMake(46, 220) withEvent:nil], "middle index glyph remains tappable");
        Check([index pointInside:CGPointMake(46, 430) withEvent:nil], "bottom index glyph remains tappable");
        Check(![index pointInside:CGPointMake(46, -1) withEvent:nil], "above-index touches pass through");
        Check(![index pointInside:CGPointMake(46, 443) withEvent:nil], "below-index touches pass through");
        Check(![index pointInside:CGPointMake(-1, 220) withEvent:nil], "left-of-overlay touches pass through");
        Check(![index pointInside:CGPointMake(57, 220) withEvent:nil], "right-of-overlay touches pass through");
        index.titles = @[@"A", @"B", @"C"];
        Check([index indexForPoint:CGPointMake(46, 220)] == 1, "scrubbing can start on the middle letter");
        Check([index indexForPoint:CGPointMake(-60, 430)] == 2, "a scrub that leaves the column to the left can continue downward");
        Check([index indexForPoint:CGPointMake(-60, 10)] == 0, "a scrub outside the column can reverse upward");
        Check([index indexForPoint:CGPointMake(-60, 220)] == 1, "a scrub outside the column can reverse downward again");
        duo = NO;
        Check([index pointInside:CGPointMake(22, 170) withEvent:nil], "ordinary phones retain their existing wide index starting area");
        Check([index pointInside:CGPointMake(46, 170) withEvent:nil], "ordinary-phone letter centers remain active");
        Check(![index pointInside:CGPointMake(21, 170) withEvent:nil], "ordinary phones retain the original left boundary");
        duo = YES;
        Check(![index pointInside:CGPointMake(22, 170) withEvent:nil], "only Duo narrows the initial hit band near its rail");
        UITableView *table = [UITableView new];
        UITableViewIndex *nativeIndex = [UITableViewIndex new];
        UIView *row = [UIView new]; table.subviews = @[row, nativeIndex];
        ApolloSubredditIndexHideNativeIndex(table);
        Check(!nativeIndex.userInteractionEnabled, "the visually replaced native index must stop intercepting star taps and list drags");
        Check(row.userInteractionEnabled, "disabling native-index touches must preserve ordinary row interaction");
        ApolloSubredditIndexHideNativeIndex(table);
        Check([objc_getAssociatedObject(nativeIndex, &kApolloSubredditNativeIndexInteractionKey) boolValue],
              "repeated layout must retain the index's original interactive state");
        nativeIndex.userInteractionEnabled = YES;
        ApolloSubredditIndexHideNativeIndex(table);
        Check(!nativeIndex.userInteractionEnabled, "UIKit re-enabling a replaced native index is reconciled on layout");
        ApolloSubredditIndexSetNativeIndexReplaced(table, NO);
        Check(nativeIndex.userInteractionEnabled, "classic mode restores the original native-index touch behavior");
        Check(!objc_getAssociatedObject(nativeIndex, &kApolloSubredditNativeIndexInteractionKey), "restoration releases the interaction override");
        nativeIndex.userInteractionEnabled = NO;
        ApolloSubredditIndexHideNativeIndex(table);
        ApolloSubredditIndexSetNativeIndexReplaced(table, NO);
        Check(!nativeIndex.userInteractionEnabled, "an originally disabled index stays disabled after restoration");
        UITableViewIndex *replacement = [UITableViewIndex new];
        table.subviews = @[row, replacement];
        ApolloSubredditIndexHideNativeIndex(table);
        Check(!replacement.userInteractionEnabled, "a newly created UIKit index also yields to the custom index");
        ApolloSubredditIndexSetNativeIndexReplaced(table, NO);
        Check(replacement.userInteractionEnabled, "a replacement index regains its own original behavior in classic mode");
        ApolloSubredditIndexSetNativeIndexReplaced(table, NO);
        Check(replacement.userInteractionEnabled && row.userInteractionEnabled, "repeated restoration preserves native and row controls");
        printf("PASS: %u subreddit index hit checks\n", checks);
    }
}
