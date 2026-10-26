#import "ApolloCommentHeaderShift.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloClasses.h"
#import "ApolloListRowAnimationPolicy.h"
#import "ApolloTextureDecls.h"

static BOOL SpecContains(id element, id target) {
    if (element == target) return YES;
    if (!ApolloClassASLayoutSpec || ![element isKindOfClass:ApolloClassASLayoutSpec]) return NO;
    for (id child in [(ASLayoutSpec *)element children]) {
        if (SpecContains(child, target)) return YES;
    }
    return NO;
}

static BOOL SpecReplace(id element, id target, id replacement) {
    if (!ApolloClassASLayoutSpec || ![element isKindOfClass:ApolloClassASLayoutSpec]) return NO;
    NSArray *children = [(ASLayoutSpec *)element children];
    NSUInteger index = [children indexOfObjectIdenticalTo:target];
    if (index != NSNotFound) {
        NSMutableArray *replaced = [children mutableCopy];
        replaced[index] = replacement;
        ((ASLayoutSpec *)element).children = replaced;
        return YES;
    }
    for (id child in children) {
        if (SpecReplace(child, target, replacement)) return YES;
    }
    return NO;
}

// The layout of an element within `width` (any width when 0), including any
// size its style sets (a fixed-size badge reports none through
// calculateLayoutThatFits:).
static id LayoutOf(id element, CGFloat width) {
    SEL selector = NSSelectorFromString(@"layoutThatFits:");
    if (![element respondsToSelector:selector]) selector = NSSelectorFromString(@"calculateLayoutThatFits:");
    if (![element respondsToSelector:selector]) return nil;
    struct ApolloTextureSizeRange range = {.min = CGSizeZero,
                                           .max = CGSizeMake(width > 0 ? width : CGFLOAT_MAX, CGFLOAT_MAX)};
    return ((id (*)(id, SEL, struct ApolloTextureSizeRange))objc_msgSend)(element, selector, range);
}

static CGSize SizeOf(id layout) {
    SEL selector = NSSelectorFromString(@"size");
    if (!layout || ![layout respondsToSelector:selector]) return CGSizeZero;
    return ((CGSize (*)(id, SEL))objc_msgSend)(layout, selector);
}

// Where Texture places `item` vertically inside a row's layout; NAN if absent.
static CGFloat ItemTop(id rowLayout, id item) {
    SEL sublayouts = NSSelectorFromString(@"sublayouts");
    if (![rowLayout respondsToSelector:sublayouts]) return NAN;
    for (id sub in ((NSArray *(*)(id, SEL))objc_msgSend)(rowLayout, sublayouts)) {
        id element = ((id (*)(id, SEL))objc_msgSend)(sub, NSSelectorFromString(@"layoutElement"));
        if (element != item) continue;
        return ((CGPoint (*)(id, SEL))objc_msgSend)(sub, NSSelectorFromString(@"position")).y;
    }
    return NAN;
}

static void CopyUnsigned(id from, id to, NSString *name) {
    SEL getter = NSSelectorFromString(name);
    SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:", [[name substringToIndex:1] uppercaseString],
                                       [name substringFromIndex:1]]);
    if (![from respondsToSelector:getter] || ![to respondsToSelector:setter]) return;
    NSUInteger value = ((NSUInteger (*)(id, SEL))objc_msgSend)(from, getter);
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(to, setter, value);
}

static void CopyFloat(id from, id to, NSString *name) {
    SEL getter = NSSelectorFromString(name);
    SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:", [[name substringToIndex:1] uppercaseString],
                                       [name substringFromIndex:1]]);
    if (![from respondsToSelector:getter] || ![to respondsToSelector:setter]) return;
    CGFloat value = ((CGFloat (*)(id, SEL))objc_msgSend)(from, getter);
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(to, setter, value);
}

id ApolloCommentHeaderAlignCollapsedRow(id spec, id headerRow, id countNode,
                                        id disclosureNode, id optionsNode, CGFloat width) {
    if (!spec || !headerRow || !countNode || !ApolloClassASStackLayoutSpec || !ApolloClassASInsetLayoutSpec) return spec;
    if (![headerRow isKindOfClass:ApolloClassASStackLayoutSpec] || !SpecContains(headerRow, countNode)) return spec;
    if (spec != headerRow && !SpecContains(spec, headerRow)) return spec;
    ASStackLayoutSpec *row = headerRow;

    NSMutableArray *sharedItems = [NSMutableArray array];
    CGFloat shared = 0.0, collapsedOnly = 0.0;
    for (id child in row.children) {
        CGFloat height = SizeOf(LayoutOf(child, width)).height;
        BOOL collapsedItem = SpecContains(child, countNode) || (disclosureNode && SpecContains(child, disclosureNode));
        if (collapsedItem) {
            collapsedOnly = MAX(collapsedOnly, height);
        } else {
            shared = MAX(shared, height);
            [sharedItems addObject:child];
        }
    }
    if (shared <= 0.0 || sharedItems.count == 0) return spec;

    // Lay out the row as it is and the same row as the expanded header has it
    // (its shared items plus the options button), at the row's width, and read
    // where Texture puts the first shared item in each: exact to the pixel
    // rounding it applies. The height formula is the fallback when a layout
    // cannot be read.
    CGFloat shift = NAN;
    id reference = sharedItems.firstObject;
    NSMutableArray *expandedItems = [sharedItems mutableCopy];
    if (optionsNode) [expandedItems addObject:optionsNode];
    ASStackLayoutSpec *expandedRow = [ApolloClassASStackLayoutSpec stackLayoutSpecWithDirection:row.direction
                                                                                        spacing:row.spacing
                                                                                 justifyContent:row.justifyContent
                                                                                     alignItems:row.alignItems
                                                                                       children:expandedItems];
    id collapsedLayout = LayoutOf(row, width), expandedLayout = LayoutOf(expandedRow, width);
    if (collapsedLayout && expandedLayout) shift = ItemTop(expandedLayout, reference) - ItemTop(collapsedLayout, reference);
    if (isnan(shift)) {
        CGFloat expandedOnly = optionsNode ? SizeOf(LayoutOf(optionsNode, width)).height : 0.0;
        shift = ApolloCollapsedHeaderShift(shared, expandedOnly, collapsedOnly);
    }
    if (fabs(shift) < 0.01) return spec;

    // A move up shortens the row by the same amount; a move down keeps its
    // height.
    ASInsetLayoutSpec *moved = [ApolloClassASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(shift, 0, shift > 0 ? -shift : 0, 0)
                                                                                 child:headerRow];
    // The wrapper stands in for the row in its parent: same stretch, flex and
    // spacing, so the row keeps the full width its spacer needs.
    id rowStyle = row.style;
    id wrapperStyle = moved.style;
    CopyUnsigned(rowStyle, wrapperStyle, @"alignSelf");
    CopyFloat(rowStyle, wrapperStyle, @"flexGrow");
    CopyFloat(rowStyle, wrapperStyle, @"flexShrink");
    CopyFloat(rowStyle, wrapperStyle, @"spacingBefore");
    CopyFloat(rowStyle, wrapperStyle, @"spacingAfter");
    if (spec == headerRow) return moved;
    SpecReplace(spec, headerRow, moved);
    return spec;
}
