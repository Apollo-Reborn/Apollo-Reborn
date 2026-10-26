// Runs the shipping ApolloCommentHeaderAlignCollapsedRow (src/ApolloCommentHeaderShift.m)
// against small Texture stand-ins that lay out the way Texture does for a
// comment header: a horizontal stack centres its items on the tallest and
// grows its flexible spacer only up to its minimum width, a vertical stack
// stretches a child whose alignSelf is stretch to its own width, and an inset
// passes its constraints on minus the insets.

#import <Foundation/Foundation.h>
#import <assert.h>
#import <math.h>

#import "ApolloCommentHeaderShift.h"
#import "ApolloTextureDecls.h"

Class ApolloClassASLayoutSpec;
Class ApolloClassASStackLayoutSpec;
Class ApolloClassASInsetLayoutSpec;

static unsigned sChecks = 0;
#define CHECK(condition) do { sChecks++; assert(condition); } while (0)

enum { kVertical = 0, kHorizontal = 1 };
enum { kAlignStart = 0, kAlignCenter = 2 };
enum { kSelfAuto = 0, kSelfStretch = 4 };

@interface TestStyle : NSObject
@property (nonatomic) NSUInteger alignSelf;
@property (nonatomic) CGFloat flexGrow;
@property (nonatomic) CGFloat flexShrink;
@property (nonatomic) CGFloat spacingBefore;
@property (nonatomic) CGFloat spacingAfter;
@end
@implementation TestStyle
@end

@interface TestLayout : NSObject
@property (nonatomic, strong) id layoutElement;
@property (nonatomic) CGSize size;
@property (nonatomic) CGPoint position;
@property (nonatomic, copy) NSArray<TestLayout *> *sublayouts;
@end
@implementation TestLayout
@end

static TestLayout *Layout(id element, CGSize size, NSArray<TestLayout *> *sublayouts) {
    TestLayout *layout = [TestLayout new];
    layout.layoutElement = element;
    layout.size = size;
    layout.sublayouts = sublayouts ?: @[];
    return layout;
}

@protocol TestElement <NSObject>
- (TestStyle *)style;
- (TestLayout *)layoutThatFits:(struct ApolloTextureSizeRange)range;
@end

static TestLayout *LayoutIn(id element, CGFloat minWidth, CGFloat maxWidth) {
    struct ApolloTextureSizeRange range = {CGSizeMake(minWidth, 0), CGSizeMake(maxWidth, CGFLOAT_MAX)};
    return [(id<TestElement>)element layoutThatFits:range];
}

static TestStyle *StyleOf(id element) {
    return [(id<TestElement>)element style];
}

// A node of a fixed size, or one whose text wraps to `wrappedHeight` when it
// is given less than `wrapBelow` points of width.
@interface TestNode : NSObject
@property (nonatomic, readonly) TestStyle *style;
@property (nonatomic) CGSize size;
@property (nonatomic) CGFloat wrapBelow;
@property (nonatomic) CGFloat wrappedHeight;
- (TestLayout *)layoutThatFits:(struct ApolloTextureSizeRange)range;
@end

@implementation TestNode
- (instancetype)init {
    if ((self = [super init])) _style = [TestStyle new];
    return self;
}
- (TestLayout *)layoutThatFits:(struct ApolloTextureSizeRange)range {
    CGSize size = self.size;
    if (self.wrapBelow > 0 && range.max.width < self.wrapBelow) size.height = self.wrappedHeight;
    size.width = MAX(range.min.width, MIN(size.width, range.max.width));
    return Layout(self, size, nil);
}
@end

static TestNode *Node(CGFloat width, CGFloat height) {
    TestNode *node = [TestNode new];
    node.size = CGSizeMake(width, height);
    return node;
}

@interface TestLayoutSpec : NSObject
@property (nonatomic, copy) NSArray *children;
@property (nonatomic, readonly) TestStyle *style;
@end

@implementation TestLayoutSpec
- (instancetype)init {
    if ((self = [super init])) _style = [TestStyle new];
    return self;
}
@end

@interface TestStack : TestLayoutSpec
@property (nonatomic) unsigned char direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) unsigned char justifyContent;
@property (nonatomic) unsigned char alignItems;
@end

@implementation TestStack
+ (instancetype)stackLayoutSpecWithDirection:(unsigned char)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(unsigned char)justifyContent
                                  alignItems:(unsigned char)alignItems
                                    children:(NSArray *)children {
    TestStack *stack = [self new];
    stack.direction = direction;
    stack.spacing = spacing;
    stack.justifyContent = justifyContent;
    stack.alignItems = alignItems;
    stack.children = children;
    return stack;
}

- (TestLayout *)layoutThatFits:(struct ApolloTextureSizeRange)range {
    NSMutableArray<TestLayout *> *subs = [NSMutableArray array];
    if (self.direction == kHorizontal) {
        CGFloat total = 0, height = 0, grow = 0;
        for (NSUInteger i = 0; i < self.children.count; i++) {
            id child = self.children[i];
            TestLayout *sub = LayoutIn(child, 0, range.max.width);
            [subs addObject:sub];
            TestStyle *style = StyleOf(child);
            total += sub.size.width + style.spacingBefore + style.spacingAfter + (i ? self.spacing : 0);
            height = MAX(height, sub.size.height);
            grow += style.flexGrow;
        }
        // Flexible items share what is left of the minimum width only.
        CGFloat free = MAX(0, range.min.width - total);
        CGFloat x = 0;
        for (NSUInteger i = 0; i < subs.count; i++) {
            TestStyle *style = StyleOf(self.children[i]);
            CGSize size = subs[i].size;
            if (grow > 0 && style.flexGrow > 0) size.width += free * style.flexGrow / grow;
            subs[i].size = size;
            x += (i ? self.spacing : 0) + style.spacingBefore;
            CGFloat y = self.alignItems == kAlignCenter ? (height - size.height) / 2.0 : 0;
            subs[i].position = CGPointMake(x, y);
            x += size.width + style.spacingAfter;
        }
        return Layout(self, CGSizeMake(MAX(x, range.min.width), height), subs);
    }
    CGFloat y = 0, width = range.min.width;
    for (NSUInteger i = 0; i < self.children.count; i++) {
        id child = self.children[i];
        TestStyle *style = StyleOf(child);
        BOOL stretch = style.alignSelf == kSelfStretch;
        TestLayout *sub = LayoutIn(child, stretch ? range.max.width : 0, range.max.width);
        y += (i ? self.spacing : 0) + style.spacingBefore;
        sub.position = CGPointMake(0, y);
        y += sub.size.height + style.spacingAfter;
        width = MAX(width, sub.size.width);
        [subs addObject:sub];
    }
    return Layout(self, CGSizeMake(width, y), subs);
}
@end

@interface TestInset : TestLayoutSpec
@property (nonatomic) UIEdgeInsets insets;
@property (nonatomic, readonly) id child;
@end

@implementation TestInset
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child {
    TestInset *inset = [self new];
    inset.insets = insets;
    inset.children = @[child];
    return inset;
}

- (id)child {
    return self.children.firstObject;
}

- (TestLayout *)layoutThatFits:(struct ApolloTextureSizeRange)range {
    UIEdgeInsets i = self.insets;
    CGFloat horizontal = i.left + i.right;
    TestLayout *sub = LayoutIn(self.child, MAX(0, range.min.width - horizontal), range.max.width - horizontal);
    sub.position = CGPointMake(i.left, i.top);
    return Layout(self, CGSizeMake(sub.size.width + horizontal, sub.size.height + i.top + i.bottom), @[sub]);
}
@end

// Where `element` lands in `layout`, in its coordinates; NAN x if absent.
static CGRect FrameOf(TestLayout *layout, id element, CGPoint origin) {
    if (layout.layoutElement == element) {
        return (CGRect){origin, layout.size};
    }
    for (TestLayout *sub in layout.sublayouts) {
        CGRect frame = FrameOf(sub, element, CGPointMake(origin.x + sub.position.x, origin.y + sub.position.y));
        if (!isnan(frame.origin.x)) return frame;
    }
    return CGRectMake(NAN, NAN, 0, 0);
}

static BOOL Near(CGFloat a, CGFloat b) {
    return fabs(a - b) < 0.001;
}

// The pieces of a comment cell, as CommentCellNode lays them out: a header
// row (author, score, a flexible spacer, then the reply count and the
// disclosure arrow when collapsed, or the options button when expanded),
// stretched across a vertical stack inside 10/15 insets, with the body under
// it.
typedef struct Cell {
    __unsafe_unretained TestNode *author, *score, *spacer, *count, *disclosure, *options, *body;
} Cell;

static NSMutableArray *sKeep;

static Cell MakeCell(CGFloat authorHeight, CGFloat countHeight, CGFloat optionsHeight) {
    Cell cell;
    TestNode *author = Node(80, authorHeight), *score = Node(40, 15), *spacer = Node(0, 0);
    spacer.style.flexGrow = 1;
    TestNode *count = Node(30, countHeight), *disclosure = Node(12, 12), *options = Node(22, optionsHeight);
    TestNode *body = Node(300, 40);
    [sKeep addObjectsFromArray:@[author, score, spacer, count, disclosure, options, body]];
    cell.author = author; cell.score = score; cell.spacer = spacer; cell.count = count;
    cell.disclosure = disclosure; cell.options = options; cell.body = body;
    return cell;
}

static TestStack *CollapsedRow(Cell cell) {
    TestStack *row = [TestStack stackLayoutSpecWithDirection:kHorizontal spacing:10 justifyContent:0
                                                  alignItems:kAlignCenter
                                                    children:@[cell.author, cell.score, cell.spacer, cell.count, cell.disclosure]];
    row.style.alignSelf = kSelfStretch;
    row.style.spacingAfter = 4;
    return row;
}

static TestInset *CellSpec(TestStack *row, Cell cell) {
    TestStack *column = [TestStack stackLayoutSpecWithDirection:kVertical spacing:0 justifyContent:0
                                                     alignItems:kAlignStart children:@[row, cell.body]];
    return [TestInset insetLayoutSpecWithInsets:UIEdgeInsetsMake(10, 15, 10, 15) child:column];
}

static const CGFloat kCellWidth = 402;

static void test_moves_collapsed_line_up_onto_expanded(void) {
    // The reply count (24) is taller than the options button (20): Texture
    // centres the author 2 pt lower in the collapsed row than in the expanded
    // one.
    Cell cell = MakeCell(17, 24, 20);
    TestStack *row = CollapsedRow(cell);
    TestInset *spec = CellSpec(row, cell);
    TestLayout *before = LayoutIn(spec, kCellWidth, kCellWidth);
    CGRect countBefore = FrameOf(before, cell.count, CGPointZero);
    CGRect authorBefore = FrameOf(before, cell.author, CGPointZero);
    CHECK(Near(authorBefore.origin.y, 10 + 3.5));
    // The row spans the cell: the count sits against the arrow at the right.
    CHECK(Near(CGRectGetMaxX(FrameOf(before, cell.disclosure, CGPointZero)), kCellWidth - 15));

    id result = ApolloCommentHeaderAlignCollapsedRow(spec, row, cell.count, cell.disclosure, cell.options, kCellWidth - 30);
    CHECK(result == spec);
    TestStack *column = spec.child;
    TestInset *wrapper = column.children.firstObject;
    CHECK([wrapper isKindOfClass:TestInset.class] && wrapper.child == row);
    // Moved up by the difference read from the two layouts; the row gets
    // that much shorter.
    CHECK(Near(wrapper.insets.top, -2) && Near(wrapper.insets.bottom, 0));
    CHECK(Near(wrapper.insets.left, 0) && Near(wrapper.insets.right, 0));
    // The wrapper stands in for the row in the column: same stretch, flex and
    // spacing (a wrapper without them leaves the row at its own width and
    // packs the count against the score).
    CHECK(wrapper.style.alignSelf == kSelfStretch && Near(wrapper.style.spacingAfter, 4));

    TestLayout *after = LayoutIn(spec, kCellWidth, kCellWidth);
    CHECK(Near(FrameOf(after, cell.author, CGPointZero).origin.y, 10 + 1.5));   // the expanded row's place
    CGRect countAfter = FrameOf(after, cell.count, CGPointZero);
    CHECK(Near(countAfter.origin.x, countBefore.origin.x));                       // horizontal layout kept
    CHECK(Near(countAfter.origin.y, countBefore.origin.y - 2));
    CHECK(Near(FrameOf(after, cell.author, CGPointZero).origin.x, authorBefore.origin.x));
    CHECK(Near(after.size.height, before.size.height - 2));                       // the body moves up too
}

static void test_moves_down_without_growing(void) {
    // The options button (28) is taller than the reply count (22): the
    // collapsed author line moves down 3 pt, and the row keeps its height.
    Cell cell = MakeCell(17, 22, 28);
    TestStack *row = CollapsedRow(cell);
    TestInset *spec = CellSpec(row, cell);
    TestLayout *before = LayoutIn(spec, kCellWidth, kCellWidth);
    ApolloCommentHeaderAlignCollapsedRow(spec, row, cell.count, cell.disclosure, cell.options, kCellWidth - 30);
    TestInset *wrapper = ((TestStack *)spec.child).children.firstObject;
    CHECK([wrapper isKindOfClass:TestInset.class]);
    CHECK(Near(wrapper.insets.top, 3) && Near(wrapper.insets.bottom, -3));
    TestLayout *after = LayoutIn(spec, kCellWidth, kCellWidth);
    CHECK(Near(after.size.height, before.size.height));
    CHECK(Near(FrameOf(after, cell.author, CGPointZero).origin.y, FrameOf(before, cell.author, CGPointZero).origin.y + 3));
    CHECK(Near(FrameOf(after, cell.count, CGPointZero).origin.x, FrameOf(before, cell.count, CGPointZero).origin.x));
}

static void test_measures_at_the_row_width(void) {
    // A long flair wraps to two lines (34 pt) in a narrow cell, taller than
    // either the count or the options button: both rows centre on it, and
    // nothing moves. Measured without the width it would be one line, and the
    // collapsed line would be moved by mistake.
    Cell cell = MakeCell(17, 24, 20);
    TestNode *flair = Node(200, 17);
    flair.wrapBelow = 300;
    flair.wrappedHeight = 34;
    [sKeep addObject:flair];
    TestStack *row = [TestStack stackLayoutSpecWithDirection:kHorizontal spacing:10 justifyContent:0 alignItems:kAlignCenter
                                                    children:@[cell.author, flair, cell.spacer, cell.count, cell.disclosure]];
    row.style.alignSelf = kSelfStretch;
    TestInset *spec = CellSpec(row, cell);
    CHECK(ApolloCommentHeaderAlignCollapsedRow(spec, row, cell.count, cell.disclosure, cell.options, 260) == spec);
    CHECK(((TestStack *)spec.child).children.firstObject == row);
    // At a width where the flair fits on one line, the count is the tallest
    // again and the line moves.
    ApolloCommentHeaderAlignCollapsedRow(spec, row, cell.count, cell.disclosure, cell.options, 360);
    TestInset *wrapper = ((TestStack *)spec.child).children.firstObject;
    CHECK([wrapper isKindOfClass:TestInset.class] && Near(wrapper.insets.top, -2));
}

static void test_header_row_as_root(void) {
    Cell cell = MakeCell(17, 24, 20);
    TestStack *row = CollapsedRow(cell);
    row.style.flexGrow = 1;
    row.style.flexShrink = 1;
    row.style.spacingBefore = 2;
    TestInset *wrapper = ApolloCommentHeaderAlignCollapsedRow(row, row, cell.count, cell.disclosure, cell.options, 372);
    CHECK([wrapper isKindOfClass:TestInset.class] && wrapper.child == row);
    CHECK(Near(wrapper.insets.top, -2));
    CHECK(wrapper.style.alignSelf == kSelfStretch && Near(wrapper.style.flexGrow, 1) && Near(wrapper.style.flexShrink, 1));
    CHECK(Near(wrapper.style.spacingBefore, 2) && Near(wrapper.style.spacingAfter, 4));
}

static void test_left_alone(void) {
    Cell cell = MakeCell(17, 24, 20);
    TestStack *row = CollapsedRow(cell);
    TestInset *spec = CellSpec(row, cell);
    TestStack *column = spec.child;
    NSArray *children = column.children;
    // No header row, no reply count (an expanded comment), a count outside
    // the row, a row outside the spec, or a row that is not a stack.
    CHECK(ApolloCommentHeaderAlignCollapsedRow(spec, nil, cell.count, cell.disclosure, cell.options, 372) == spec);
    CHECK(ApolloCommentHeaderAlignCollapsedRow(spec, row, nil, cell.disclosure, cell.options, 372) == spec);
    CHECK(ApolloCommentHeaderAlignCollapsedRow(spec, row, cell.body, cell.disclosure, cell.options, 372) == spec);
    TestStack *stray = CollapsedRow(MakeCell(17, 24, 20));
    CHECK(ApolloCommentHeaderAlignCollapsedRow(spec, stray, stray.children[3], nil, nil, 372) == spec);
    TestInset *notStack = [TestInset insetLayoutSpecWithInsets:UIEdgeInsetsMake(0, 0, 0, 0) child:cell.count];
    CHECK(ApolloCommentHeaderAlignCollapsedRow(notStack, notStack, cell.count, nil, nil, 372) == notStack);
    CHECK([column.children isEqualToArray:children] && column.children.firstObject == row);
    // Rows that already line up (count and options as tall) are not wrapped.
    Cell even = MakeCell(17, 22, 22);
    TestStack *evenRow = CollapsedRow(even);
    TestInset *evenSpec = CellSpec(evenRow, even);
    CHECK(ApolloCommentHeaderAlignCollapsedRow(evenSpec, evenRow, even.count, even.disclosure, even.options, 372) == evenSpec);
    CHECK(((TestStack *)evenSpec.child).children.firstObject == evenRow);
    // Classes not found (another Texture): nothing changes.
    Class stack = ApolloClassASStackLayoutSpec;
    ApolloClassASStackLayoutSpec = Nil;
    CHECK(ApolloCommentHeaderAlignCollapsedRow(spec, row, cell.count, cell.disclosure, cell.options, 372) == spec);
    CHECK(column.children.firstObject == row);
    ApolloClassASStackLayoutSpec = stack;
}

int main(void) {
    @autoreleasepool {
        sKeep = [NSMutableArray array];
        ApolloClassASLayoutSpec = TestLayoutSpec.class;
        ApolloClassASStackLayoutSpec = TestStack.class;
        ApolloClassASInsetLayoutSpec = TestInset.class;
        test_moves_collapsed_line_up_onto_expanded();
        test_moves_down_without_growing();
        test_measures_at_the_row_width();
        test_header_row_as_root();
        test_left_alone();
        printf("comment_header_shift_tests passed (%u checks)\n", sChecks);
    }
    return 0;
}
