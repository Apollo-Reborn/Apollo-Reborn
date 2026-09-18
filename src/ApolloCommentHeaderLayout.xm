#import "ApolloTextureDecls.h"
#import <objc/message.h>
#import <objc/runtime.h>

// The author is an ApolloButtonNode (ASButtonNode), not a UILabel. Let
// Texture remeasure it at the space left after the score, badges and age;
// changing view frames after layout would leave its hit target out of sync.
static id ApolloCommentHeaderNode(id cell, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(cell), name);
    return ivar ? object_getIvar(cell, ivar) : nil;
}

static BOOL ApolloCommentHeaderAllowAuthorShrink(id element, id author) {
    if (element == author) return YES;
    if (![element isKindOfClass:objc_getClass("ASLayoutSpec")]) return NO;

    for (id child in [(ASLayoutSpec *)element children]) {
        if (!ApolloCommentHeaderAllowAuthorShrink(child, author)) continue;
        // Texture's horizontal direction is 1. Only change horizontal flex
        // inputs: flexShrink on a vertical stack child would shrink HEIGHT.
        // Propagate through nested header groups, since making only the
        // button flexible cannot shrink an inflexible enclosing group.
        if ([element isKindOfClass:objc_getClass("ASStackLayoutSpec")] &&
            [(ASStackLayoutSpec *)element direction] == 1) {
            [(ASDisplayNode *)child style].flexShrink = 1.0;
        }
        return YES;
    }
    return NO;
}

%hook _TtC6Apollo15CommentCellNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)constrainedSize {
    id spec = %orig;
    id author = ApolloCommentHeaderNode(self, "authorNode");
    if (!author || !ApolloCommentHeaderAllowAuthorShrink(spec, author)) return spec;

    SEL titleSelector = NSSelectorFromString(@"titleNode");
    if ([author respondsToSelector:titleSelector]) {
        ASTextNode *title = ((id (*)(id, SEL))objc_msgSend)(author, titleSelector);
        title.maximumNumberOfLines = 1;
        title.style.flexShrink = 1.0;
        SEL truncate = NSSelectorFromString(@"setTruncationMode:");
        if ([title respondsToSelector:truncate]) {
            ((void (*)(id, SEL, NSLineBreakMode))objc_msgSend)(title, truncate, NSLineBreakByTruncatingTail);
        }
    }
    return spec;
}

%end
