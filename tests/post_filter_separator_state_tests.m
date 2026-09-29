#import <Foundation/Foundation.h>

@interface TestSeparatorStyle : NSObject
@property (nonatomic) ApolloPFDim height;
@property (nonatomic) ApolloPFDim minHeight;
@property (nonatomic) ApolloPFDim maxHeight;
@end
@implementation TestSeparatorStyle
@end

@interface TestSeparatorNode : NSObject
@property (nonatomic, strong) TestSeparatorStyle *style;
@property (nonatomic, strong) NSRecursiveLock *recursiveLock;
@property (nonatomic) NSUInteger lockCalls;
@property (nonatomic) NSUInteger unlockCalls;
@property (nonatomic) NSUInteger lockDepth;
@property (nonatomic) NSUInteger maximumLockDepth;
@end
@implementation TestSeparatorNode
- (instancetype)init {
    self = [super init];
    if (self) _recursiveLock = [NSRecursiveLock new];
    return self;
}
- (void)lock {
    [self.recursiveLock lock];
    self.lockCalls += 1;
    self.lockDepth += 1;
    self.maximumLockDepth = MAX(self.maximumLockDepth, self.lockDepth);
}
- (void)unlock {
    self.unlockCalls += 1;
    self.lockDepth -= 1;
    [self.recursiveLock unlock];
}
@end

@interface TestThrowingSeparatorNode : TestSeparatorNode
@end
@implementation TestThrowingSeparatorNode
- (TestSeparatorStyle *)style {
    @throw [NSException exceptionWithName:@"TestStyleFailure" reason:nil userInfo:nil];
}
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"PostFilterSeparatorTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

static BOOL DimensionEqual(ApolloPFDim lhs, ApolloPFDim rhs) {
    BOOL valuesEqual = (isinf(lhs.value) && isinf(rhs.value) && signbit(lhs.value) == signbit(rhs.value)) ||
        fabs(lhs.value - rhs.value) < 0.001;
    return lhs.unit == rhs.unit && valuesEqual;
}

int main(void) {
    @autoreleasepool {
        TestSeparatorStyle *style = [TestSeparatorStyle new];
        style.height = (ApolloPFDim){1, 8.0};
        style.minHeight = (ApolloPFDim){0, 0.0};
        style.maxHeight = (ApolloPFDim){0, INFINITY};
        TestSeparatorNode *node = [TestSeparatorNode new];
        node.style = style;

        [node lock];
        Require(ApolloPFSetNodeCollapsed(node, YES), @"first collapse changes state");
        [node unlock];
        Require(node.maximumLockDepth == 2,
                @"collapse re-enters Texture's recursive node lock during measurement");
        Require(ApolloPFNodeIsCollapsed(node),
                @"layout spec observes calculate-layout's existing collapse decision");
        Require(DimensionEqual(style.height, (ApolloPFDim){1, 0.0}), @"height collapses");
        Require(DimensionEqual(style.minHeight, (ApolloPFDim){1, 0.0}), @"minimum collapses");
        Require(DimensionEqual(style.maxHeight, (ApolloPFDim){1, 0.0}), @"maximum collapses");
        Require(!ApolloPFSetNodeCollapsed(node, YES), @"repeat collapse is idempotent");

        Require(ApolloPFSetNodeCollapsed(node, NO), @"restore changes state");
        Require(!ApolloPFNodeIsCollapsed(node),
                @"layout spec observes calculate-layout's existing restore decision");
        Require(DimensionEqual(style.height, (ApolloPFDim){1, 8.0}), @"height restores");
        Require(DimensionEqual(style.minHeight, (ApolloPFDim){0, 0.0}), @"minimum restores");
        Require(DimensionEqual(style.maxHeight, (ApolloPFDim){0, INFINITY}), @"maximum restores");
        Require(!ApolloPFSetNodeCollapsed(node, NO), @"repeat restore is idempotent");

        style.height = (ApolloPFDim){1, 12.0};
        Require(ApolloPFSetNodeCollapsed(node, YES), @"reused node collapses again");
        Require(ApolloPFSetNodeCollapsed(node, NO), @"reused node restores again");
        Require(DimensionEqual(style.height, (ApolloPFDim){1, 12.0}), @"reuse captures the new native height");

        dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(__unused size_t index) {
            ApolloPFSetNodeCollapsed(node, YES);
            ApolloPFSetNodeCollapsed(node, NO);
        });
        ApolloPFSetNodeCollapsed(node, NO);
        Require(DimensionEqual(style.height, (ApolloPFDim){1, 12.0}),
                @"concurrent layout and lifecycle transitions preserve native height");
        Require(node.lockDepth == 0 && node.lockCalls == node.unlockCalls,
                @"concurrent transitions balance every recursive node lock");

        TestThrowingSeparatorNode *throwingNode = [TestThrowingSeparatorNode new];
        @try {
            ApolloPFSetNodeCollapsed(throwingNode, YES);
            Require(NO, @"throwing style accessor propagates its exception");
        } @catch (NSException *exception) {
            Require([exception.name isEqualToString:@"TestStyleFailure"],
                    @"unexpected style accessor exception");
        }
        Require(throwingNode.lockDepth == 0 && throwingNode.lockCalls == throwingNode.unlockCalls,
                @"exceptional transitions still release the recursive node lock");

        NSUInteger separatorIndexes[] = {3, 5};
        NSIndexPath *separator = [NSIndexPath indexPathWithIndexes:separatorIndexes length:2];
        NSIndexPath *precedingPost = ApolloPFPostPathForSeparatorPath(separator);
        Require([precedingPost indexAtPosition:0] == 3 &&
                [precedingPost indexAtPosition:1] == 4,
                @"separator mapping retains section and selects only the preceding row");
        NSUInteger firstRowIndexes[] = {3, 0};
        Require(ApolloPFPostPathForSeparatorPath([
                    NSIndexPath indexPathWithIndexes:firstRowIndexes length:2]) == nil,
                @"the first row has no preceding post");

        puts("post_filter_separator_state_tests passed");
    }
    return 0;
}
