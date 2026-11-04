#import "ApolloSwiftRuntime.h"
#import "ApolloTextureDecls.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloClasses.h"

// The author is an ApolloButtonNode (ASButtonNode), not a UILabel. Let
// Texture remeasure it at the space left after the score, badges and age;
// changing view frames after layout would leave its hit target out of sync.
static BOOL ApolloCommentHeaderContains(id element, id target) {
    if (element == target) return YES;
    if (![element isKindOfClass:ApolloClassASLayoutSpec]) return NO;

    for (id child in [(ASLayoutSpec *)element children]) {
        if (ApolloCommentHeaderContains(child, target)) return YES;
    }
    return NO;
}

static ASStackLayoutSpec *ApolloCommentHeaderStack(id element, id author,
                                                   CGFloat *horizontalInsets) {
    if (![element isKindOfClass:ApolloClassASLayoutSpec]) return nil;

    if ([element isKindOfClass:objc_getClass("ASInsetLayoutSpec")]) {
        UIEdgeInsets insets = [(ASInsetLayoutSpec *)element insets];
        *horizontalInsets += insets.left + insets.right;
    }

    NSArray *children = [(ASLayoutSpec *)element children];
    if ([element isKindOfClass:ApolloClassASStackLayoutSpec] &&
        [(ASStackLayoutSpec *)element direction] == 1 &&
        [children containsObject:author]) {
        return element;
    }

    for (id child in children) {
        if (!ApolloCommentHeaderContains(child, author)) continue;
        ASStackLayoutSpec *stack =
            ApolloCommentHeaderStack(child, author, horizontalInsets);
        if (stack) return stack;
    }

    return nil;
}

static BOOL ApolloCommentHeaderAllowAuthorShrink(id element, id author) {
    if (element == author) return YES;
    if (![element isKindOfClass:ApolloClassASLayoutSpec]) return NO;

    for (id child in [(ASLayoutSpec *)element children]) {
        if (!ApolloCommentHeaderAllowAuthorShrink(child, author)) continue;

        // Texture's horizontal direction is 1. Propagate flexShrink through
        // horizontal groups on the author path so the button can actually
        // surrender width when even a zero-width flair would not be enough.
        if ([element isKindOfClass:ApolloClassASStackLayoutSpec] &&
            [(ASStackLayoutSpec *)element direction] == 1) {
            if ([child isKindOfClass:objc_getClass("ASDisplayNode")]) {
                ((ASDisplayNode *)child).style.flexShrink = 1.0;
            } else if ([child isKindOfClass:ApolloClassASLayoutSpec]) {
                ((ASLayoutSpec *)child).style.flexShrink = 1.0;
            }
        }
        return YES;
    }
    return NO;
}

static CGFloat ApolloCommentHeaderNaturalWidth(id element) {
    SEL selector = NSSelectorFromString(@"calculateLayoutThatFits:");
    if (![element respondsToSelector:selector]) return 0.0;

    struct ApolloTextureSizeRange range = {
        .min = CGSizeZero,
        .max = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX),
    };

    id layout =
        ((id (*)(id, SEL, struct ApolloTextureSizeRange))objc_msgSend)(
            element, selector, range
        );

    SEL sizeSelector = NSSelectorFromString(@"size");
    if (!layout || ![layout respondsToSelector:sizeSelector]) return 0.0;

    return ((CGSize (*)(id, SEL))objc_msgSend)(layout, sizeSelector).width;
}

// Returns the width required to preserve the full author while treating flair
// as disposable. If that minimum still exceeds the header width, allow the
// author to shrink as a final fallback so trailing metadata remains visible.
static CGFloat ApolloCommentHeaderMinimumWidthWithoutFlair(
    ASStackLayoutSpec *header,
    id flair
) {
    NSArray *children = header.children;
    CGFloat width = 0.0;

    for (id child in children) {
        if (child == flair) continue;
        width += ApolloCommentHeaderNaturalWidth(child);
    }

    // Texture keeps the gap on both sides of a zero-width child (the fully
    // shrunk flair and Apollo's flexGrow spacer), so count every gap.
    if (children.count > 1) {
        width += header.spacing * (children.count - 1);
    }

    return width;
}

// PostInfoNode is also used in feeds. Mark the instance owned by the
// comments header before its first layout, when supernode may still be nil.
static char kApolloCommentHeaderPostInfoKey;

static BOOL ApolloPostInfoIsInCommentsHeader(ASDisplayNode *node) {
    if (objc_getAssociatedObject(node, &kApolloCommentHeaderPostInfoKey)) {
        return YES;
    }

    Class headerClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    if (!headerClass) return NO;

    ASDisplayNode *parent = node.supernode;
    for (NSUInteger i = 0; parent && i < 8; i++) {
        if ([parent isKindOfClass:headerClass]) return YES;
        parent = parent.supernode;
    }
    return NO;
}

%hook _TtC6Apollo22CommentsHeaderCellNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)constrainedSize {
    id postInfo = ApolloObjectIvar(self, "postInfoNode");
    if (postInfo) {
        objc_setAssociatedObject(postInfo, &kApolloCommentHeaderPostInfoKey,
                                 @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return %orig;
}

%end

%hook _TtC6Apollo12PostInfoNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)constrainedSize {
    id spec = %orig;

    if (!ApolloPostInfoIsInCommentsHeader((ASDisplayNode *)self)) {
        return spec;
    }

    id author = ApolloObjectIvar(self, "authorButtonNode");
    id flair = ApolloObjectIvar(self, "flairNode");
    if (!author || !flair) return spec;

    CGFloat horizontalInsets = 0.0;
    ASStackLayoutSpec *header =
        ApolloCommentHeaderStack(spec, author, &horizontalInsets);

    if (!header || ![header.children containsObject:flair]) {
        return spec;
    }

    CGFloat availableWidth =
        MAX(0.0, constrainedSize.max.width - horizontalInsets);

    CGFloat minimumWidth =
        ApolloCommentHeaderMinimumWidthWithoutFlair(header, flair);

    BOOL shouldShrinkAuthor = minimumWidth > availableWidth;

    ((ASDisplayNode *)author).style.flexShrink =
        shouldShrinkAuthor ? 1.0 : 0.0;

    ((ASDisplayNode *)flair).style.flexShrink = 1.0;

    SEL titleSelector = @selector(titleNode);
    if ([author respondsToSelector:titleSelector]) {
        ASTextNode *title =
            ((id (*)(id, SEL))objc_msgSend)(author, titleSelector);

        title.maximumNumberOfLines = 1;
        title.style.flexShrink = shouldShrinkAuthor ? 1.0 : 0.0;
        title.truncationMode = NSLineBreakByTruncatingTail;
    }

    return spec;
}

%end

%hook _TtC6Apollo15CommentCellNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)constrainedSize {
    id spec = %orig;
    id author = ApolloObjectIvar(self, "authorNode");
    if (!author) return spec;
    id flair = ApolloObjectIvar(self, "flairNode");
    BOOL shouldShrinkAuthor = NO;

    CGFloat horizontalInsets = 0.0;
    ASStackLayoutSpec *header =
        ApolloCommentHeaderStack(spec, author, &horizontalInsets);

    if (header && flair) {
        CGFloat availableWidth =
            MAX(0.0, constrainedSize.max.width - horizontalInsets);

        CGFloat minimumWidth =
            ApolloCommentHeaderMinimumWidthWithoutFlair(header, flair);

        // Preserve Apollo's native priority while possible: author does not
        // shrink, flair does. Only allow the author to shrink when the full
        // author cannot fit even with the flair contributing no width.
        if (minimumWidth > availableWidth) {
            shouldShrinkAuthor = YES;
            ApolloCommentHeaderAllowAuthorShrink(spec, author);
        }
    } else {
        // Without a flair, or if the header cannot be identified, fall back to
        // allowing the author to shrink so trailing metadata remains visible.
        shouldShrinkAuthor = YES;
        ApolloCommentHeaderAllowAuthorShrink(spec, author);
    }

    SEL titleSelector = @selector(titleNode);
    if ([author respondsToSelector:titleSelector]) {
        ASTextNode *title =
            ((id (*)(id, SEL))objc_msgSend)(author, titleSelector);
        title.maximumNumberOfLines = 1;
        title.style.flexShrink = shouldShrinkAuthor ? 1.0 : 0.0;

        title.truncationMode = NSLineBreakByTruncatingTail;
    }
    return spec;
}

%end
